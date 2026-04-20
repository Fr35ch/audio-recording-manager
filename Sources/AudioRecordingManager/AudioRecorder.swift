import AVFAudio
import AVFoundation
import Accelerate
import Foundation

// MARK: - Speech Activity Detector (VAD)
// Must inherit NSObject to support block-based notification observation via stored token.
private final class SpeechActivityDetector: NSObject {
    private let fftSize = 1024
    // Speech bins calculated from actual hardware sample rate in start()
    private var speechBinLow = 7
    private var speechBinHigh = 79

    // Adaptive noise floor
    private let noiseWindowCount = 30
    private var energyHistory: [Float] = []
    private var noiseFloor: Float = 1e-6

    // Temporal debounce
    private let speechOnsetDuration: TimeInterval = 1.5
    private let speechOffsetGrace: TimeInterval = 0.5
    private var speechOnsetAccumulator: TimeInterval = 0
    private var speechOffsetAccumulator: TimeInterval = 0
    private(set) var isSpeechActive = false

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var configChangeToken: NSObjectProtocol?
    private var actualSampleRate: Double = 44100

    // PCM accumulation ring — pre-allocated to avoid heap allocs on audio thread
    private var sampleAccumulator: [Float] = []

    // Pre-allocated FFT work buffers (reused every window — no heap alloc on audio thread)
    private let halfN: Int
    private var hannWindow: [Float]
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var mags: [Float]
    private var fftSetup: FFTSetup?

    var onSpeechStateChanged: ((Bool) -> Void)?

    // isPaused: written on main thread, read on Core Audio real-time thread.
    // Using a plain Bool — a single aligned store/load is effectively atomic on ARM64/x86_64.
    // The worst case is processing one extra audio window after pause, which is harmless.
    var isPaused: Bool = false

    override init() {
        halfN = fftSize / 2
        hannWindow = [Float](repeating: 0, count: fftSize)
        windowed   = [Float](repeating: 0, count: fftSize)
        realPart   = [Float](repeating: 0, count: fftSize / 2)
        imagPart   = [Float](repeating: 0, count: fftSize / 2)
        mags       = [Float](repeating: 0, count: fftSize / 2)
        let log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        super.init()
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        sampleAccumulator.reserveCapacity(fftSize * 4)
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
        stopEngine()
    }

    func start() {
        guard fftSetup != nil else { return }
        stopEngine()
        let inputNode = engine.inputNode
        // Use the hardware's native format — avoids sample-rate conversion overhead
        // and ensures speech bin indices are correct for this device.
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let sr = Float(nativeFormat.sampleRate > 0 ? nativeFormat.sampleRate : 44100)
        actualSampleRate = Double(sr)
        speechBinLow  = max(0,          Int((300.0  * Float(fftSize)) / sr))
        speechBinHigh = min(halfN - 1,  Int((3400.0 * Float(fftSize)) / sr))

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize),
                             format: nativeFormat) { [weak self] buf, _ in
            self?.processTap(buf)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("SAD: engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            return
        }
        // Block-based observer — no @objc / #selector needed
        configChangeToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard self?.tapInstalled == true else { return }
            self?.stopEngine()
            self?.start()
        }
    }

    func stop()   { stopEngine(); fullReset() }  // stopEngine() removes tap before reset — no race
    func pause()  { isPaused = true }            // audio thread exits on next callback via isPaused guard
    func resume() { isPaused = false }

    private func stopEngine() {
        if let token = configChangeToken {
            NotificationCenter.default.removeObserver(token)
            configChangeToken = nil
        }
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapInstalled = false
    }

    private func fullReset() {
        sampleAccumulator.removeAll(keepingCapacity: true)
        energyHistory.removeAll(keepingCapacity: true)
        noiseFloor = 1e-6
        speechOnsetAccumulator = 0
        speechOffsetAccumulator = 0
        isSpeechActive = false
    }

    // MARK: - Core Audio real-time thread (no locks, no heap allocation)

    private func processTap(_ buffer: AVAudioPCMBuffer) {
        guard !isPaused, let ch = buffer.floatChannelData?[0] else { return }
        sampleAccumulator.append(
            contentsOf: UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        // Safety cap against stalls
        if sampleAccumulator.count > fftSize * 8 {
            sampleAccumulator.removeFirst(sampleAccumulator.count - fftSize * 4)
        }
        while sampleAccumulator.count >= fftSize {
            processWindow()
            sampleAccumulator.removeFirst(fftSize)
        }
    }

    private func processWindow() {
        guard let fftSetup = fftSetup else { return }
        // Apply Hann window (pre-computed, no alloc)
        vDSP_vmul(sampleAccumulator, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack real signal as split complex: even→real, odd→imag
        windowed.withUnsafeBytes { rawPtr in
            let ptr = rawPtr.bindMemory(to: DSPComplex.self).baseAddress!
            var split = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
            vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfN))
        }

        // Forward FFT
        var split = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
        let log2n = vDSP_Length(log2(Double(fftSize)))
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // Squared magnitudes
        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))

        // Speech band energy (no Array slice alloc — index into pre-allocated mags)
        var speechEnergy: Float = 0
        let binCount = vDSP_Length(speechBinHigh - speechBinLow)
        withUnsafePointer(to: mags[speechBinLow]) { ptr in
            vDSP_sve(ptr, 1, &speechEnergy, binCount)
        }

        // Adaptive noise floor
        energyHistory.append(speechEnergy)
        if energyHistory.count > noiseWindowCount { energyHistory.removeFirst() }
        if energyHistory.count >= 5, let minE = energyHistory.min(), minE > 0 {
            noiseFloor = 0.85 * noiseFloor + 0.15 * minE
        }

        // Classify + temporal debounce
        let isSpeech = speechEnergy > noiseFloor * 8.0
        let windowDur = Double(fftSize) / actualSampleRate  // ≈ 0.023 s @ 44100 Hz

        if isSpeech {
            speechOnsetAccumulator  += windowDur
            speechOffsetAccumulator  = 0
            if speechOnsetAccumulator >= speechOnsetDuration, !isSpeechActive {
                isSpeechActive = true
                DispatchQueue.main.async { [weak self] in self?.onSpeechStateChanged?(true) }
            }
        } else {
            speechOffsetAccumulator += windowDur
            speechOnsetAccumulator   = 0
            if speechOffsetAccumulator >= speechOffsetGrace, isSpeechActive {
                isSpeechActive = false
                DispatchQueue.main.async { [weak self] in self?.onSpeechStateChanged?(false) }
            }
        }

    }
}

// MARK: - Audio Recorder

/// Manages microphone access, recording lifecycle, and real-time audio level visualization.
///
/// ## Visualization pipeline
/// A 20 Hz `Timer` (`startLevelMonitoring`) reads `AVAudioRecorder.updateMeters()` during
/// both the pre-recording monitoring phase and active recording. This is the single source
/// of truth for all visualization data — `frequencyBands`, `audioLevel`, and `waveformHistory`
/// are all populated exclusively by this timer.
///
/// `SpeechActivityDetector` runs an `AVAudioEngine` FFT tap in parallel for voice-activity
/// detection only; it does **not** drive any visualization properties.
class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = AudioRecorder()

    // MARK: - Published state

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0

    /// Current audio level, normalized 0–1. Updated at 20 Hz by the metering timer.
    @Published var audioLevel: Float = 0

    @Published var lastSavedFile: String?
    @Published var showSaveConfirmation = false

    /// Smoothed per-band energy for 32 frequency bands, each normalized 0–1.
    /// Updated at 20 Hz. Lower bands carry more weight to reflect natural speech distribution.
    @Published var frequencyBands: [Float] = Array(repeating: 0, count: 32)

    @Published var isMonitoring = false

    /// Ring buffer of amplitude samples for the waveform timeline, ordered oldest-first.
    /// Capped at `maxHistoryLength` entries (~50 s at 20 Hz). Each entry has a stable `id`
    /// so `ScrollingWaveformView` can match bars correctly as the buffer scrolls.
    @Published var waveformHistory: [WaveformEntry] = []

    @Published var showNamingDialog = false
    @Published var pendingRecordingURL: URL?
    @Published var showSilenceWarning = false

    // MARK: - Private state

    /// Monotonically-increasing counter stamped onto each `WaveformEntry` at append time.
    private var waveformCounter: UInt64 = 0

    // MARK: - Silence Detection (VAD-driven)
    private let vad = SpeechActivityDetector()
    private var isSpeechActive = false
    private var silenceDuration: TimeInterval = 0
    private var lastSilenceCheckTime: Date?
    private let silenceAlertInterval: TimeInterval = 120  // 2 minutes
    private var silenceCooldownActive = false
    private let silenceCooldownDuration: TimeInterval = 300  // 5-min cooldown after dismiss

    /// Maximum number of waveform samples to retain (~15 s at 20 Hz).
    // 1000 samples at 20 Hz = 50 seconds of history, enough to fill the waveform
    // even on wide windows (stride is 4 pt/bar, so 1000 bars cover ~4000 pt).
    private let maxHistoryLength = 1000
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var levelTimer: Timer?
    private var currentRecordingURL: URL?
    /// UUID of the in-progress recording in `RecordingStore`. Set in
    /// `startRecording()`, used in `saveRecordingWithName()` to finalize
    /// the sidecar's `displayName` and `durationSeconds`.
    private var currentRecordingId: UUID?
    private var monitorRecorder: AVAudioRecorder?

    private override init() {
        super.init()
        vad.onSpeechStateChanged = { [weak self] active in
            self?.isSpeechActive = active
        }
        print("✅ Audio recorder initialized")
    }

    // MARK: - Audio Monitoring (for visualization before recording)

    func startMonitoring() {
        guard !isMonitoring else { return }

        // Always start with a clean slate so a previous recording's waveform
        // doesn't carry into the next session's monitoring phase.
        waveformHistory.removeAll()
        frequencyBands = Array(repeating: 0, count: 32)
        audioLevel = 0

        // Create a temporary URL for monitoring (won't save)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "monitor.m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            monitorRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
            monitorRecorder?.isMeteringEnabled = true
            monitorRecorder?.prepareToRecord()
            monitorRecorder?.record()

            isMonitoring = true
            startLevelMonitoring()
            print("🎤 Started audio monitoring")
        } catch {
            print("❌ Error starting monitoring: \(error)")
        }
    }

    func stopMonitoring(clearHistory: Bool = true) {
        guard isMonitoring else { return }

        monitorRecorder?.stop()
        monitorRecorder = nil
        isMonitoring = false
        stopLevelMonitoring()

        // Clear visualization
        frequencyBands = Array(repeating: 0, count: 32)
        audioLevel = 0
        if clearHistory {
            waveformHistory.removeAll()
        }

        print("🛑 Stopped audio monitoring")
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Single source of truth for visualization: AVAudioRecorder metering.
            // Works reliably for both monitoring and recording phases.
            let avRecorder = self.isRecording ? self.audioRecorder : self.monitorRecorder
            guard let avRecorder else { return }

            avRecorder.updateMeters()
            let averagePower = avRecorder.averagePower(forChannel: 0)
            let peakPower    = avRecorder.peakPower(forChannel: 0)

            // -44 dB floor: ambient room noise typically sits at -55 to -45 dBFS.
            // Anything quieter than -44 dB maps to zero so the display is silent
            // unless actual speech or deliberate sound is present.
            let minDB: Float = -44.0
            let maxDB: Float = -5.0
            let normalizedLevel = max(0, (max(minDB, min(maxDB, averagePower)) - minDB) / (maxDB - minDB))
            self.audioLevel = normalizedLevel

            // Silence detection (VAD speech state + amplitude fallback)
            if self.isRecording, !self.isPaused, !self.silenceCooldownActive {
                let now = Date()
                let elapsed = self.lastSilenceCheckTime.map { now.timeIntervalSince($0) } ?? 0.05
                self.lastSilenceCheckTime = now
                if !(self.isSpeechActive || self.audioLevel > 0.1) {
                    self.silenceDuration += elapsed
                    if self.silenceDuration >= self.silenceAlertInterval, !self.showSilenceWarning {
                        self.showSilenceWarning = true
                    }
                } else {
                    self.silenceDuration = 0
                }
            } else if !self.isRecording || self.isPaused {
                self.silenceDuration = 0
                self.lastSilenceCheckTime = nil
            }

            // Frequency band visualization — deterministic per-band weighting, no random noise.
            // Lower bands are weighted louder to reflect natural speech energy distribution.
            let powerVariance = max(0, (max(minDB, min(maxDB, peakPower)) - minDB) / (maxDB - minDB))
            let smoothing: Float = 0.75
            for i in 0..<32 {
                let frequencyWeight = 1.0 - (Float(i) / 32.0 * 0.6)
                let bandLevel = normalizedLevel * frequencyWeight * powerVariance * 1.4
                self.frequencyBands[i] = self.frequencyBands[i] * smoothing + bandLevel * (1 - smoothing)
            }

            // Waveform timeline history
            self.waveformCounter &+= 1
            self.waveformHistory.append(WaveformEntry(id: self.waveformCounter, level: normalizedLevel))
            if self.waveformHistory.count > self.maxHistoryLength {
                self.waveformHistory.removeFirst()
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func resetSilenceTracking() {
        silenceDuration = 0
        lastSilenceCheckTime = nil
    }

    func dismissSilenceWarning() {
        showSilenceWarning = false
        resetSilenceTracking()
        silenceCooldownActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceCooldownDuration) { [weak self] in
            self?.silenceCooldownActive = false
        }
    }

    // MARK: - Recording Control

    func startRecording() {
        // Stop monitoring when actual recording starts with a clean waveform slate.
        if isMonitoring {
            stopMonitoring(clearHistory: true)
        }

        // Create a new recording in RecordingStore and record to its audio path.
        do {
            let handle = try RecordingStore.shared.create()
            currentRecordingId = handle.id
            currentRecordingURL = handle.audioURL
        } catch {
            print("❌ Failed to create recording in store: \(error)")
            return
        }

        guard let url = currentRecordingURL else {
            print("❌ Failed to create recording URL")
            return
        }

        // Configure recording settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()

            if audioRecorder?.record() == true {
                isRecording = true
                isPaused = false
                recordingDuration = 0

                // Start timers (level monitoring continues)
                startRecordingTimer()
                if !isMonitoring {
                    startLevelMonitoring()
                }
                vad.start()

                print("✅ Started recording to: \(url.lastPathComponent)")
            } else {
                print("❌ Failed to start recording")
            }
        } catch {
            print("❌ Error creating audio recorder: \(error)")
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        audioRecorder?.pause()
        isPaused = true
        stopRecordingTimer()
        resetSilenceTracking()
        showSilenceWarning = false
        silenceCooldownActive = false
        vad.pause()

        print("⏸️ Recording paused")
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        audioRecorder?.record()
        isPaused = false
        startRecordingTimer()
        resetSilenceTracking()
        silenceCooldownActive = false
        vad.resume()

        print("▶️ Recording resumed")
    }

    func stopRecording() {
        guard isRecording else { return }

        audioRecorder?.stop()
        isRecording = false
        isPaused = false
        stopRecordingTimer()
        stopLevelMonitoring()
        resetSilenceTracking()
        showSilenceWarning = false
        silenceCooldownActive = false
        vad.stop()
        isSpeechActive = false

        // Store the recording URL for naming
        if let url = currentRecordingURL {
            pendingRecordingURL = url
            showNamingDialog = true
            print("⏸️ Recording stopped, waiting for filename...")
        }

        audioRecorder = nil
        currentRecordingURL = nil
    }

    /// Save the pending recording with a custom name + timestamp.
    /// The audio file already lives in `RecordingStore` at
    /// `recordings/<uuid>/audio.m4a` — this method just updates the
    /// sidecar's `displayName` and finalizes the recording.
    func saveRecordingWithName(_ customName: String) {
        guard let id = currentRecordingId else {
            print("❌ No pending recording to save")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())

        let cleanName = customName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let displayName: String
        if cleanName.isEmpty {
            displayName = "lydfil_\(timestamp)"
        } else {
            displayName = "\(cleanName)_\(timestamp)"
        }

        // Finalize the sidecar: set displayName, duration, audio size + status.
        let audioURL = StorageLayout.audioURL(id: id)
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0

        do {
            try RecordingStore.shared.finalize(
                id: id,
                durationSeconds: recordingDuration,
                sizeBytes: size
            )
            try RecordingStore.shared.updateMeta(id: id) { meta in
                meta.displayName = displayName
            }
        } catch {
            print("❌ Error finalizing recording: \(error)")
        }

        lastSavedFile = displayName
        showNamingDialog = false
        showSaveConfirmation = true
        print("✅ Recording saved: \(displayName)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.showSaveConfirmation = false
            self.recordingDuration = 0
        }

        pendingRecordingURL = nil
        currentRecordingId = nil
        startMonitoring()
    }

    /// Cancel/discard the pending recording
    func cancelPendingRecording() {
        if let id = currentRecordingId {
            try? RecordingStore.shared.delete(id: id)
            print("🗑️ Pending recording discarded")
        }
        pendingRecordingURL = nil
        currentRecordingId = nil
        showNamingDialog = false
        recordingDuration = 0

        startMonitoring()
    }

    func deleteCurrentRecording() {
        if isRecording {
            stopRecording()
        }

        if let id = currentRecordingId {
            try? RecordingStore.shared.delete(id: id)
            print("🗑️ Recording deleted")
        }

        recordingDuration = 0
        audioLevel = 0
        currentRecordingURL = nil
        currentRecordingId = nil
    }

    // MARK: - Recording Timer (duration only)

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder else { return }
            self.recordingDuration = recorder.currentTime
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag {
            print("✅ Recording finished successfully")
        } else {
            print("❌ Recording failed")
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("❌ Recording error: \(error)")
        }
    }
}
