import AVFAudio
import AVFoundation
import Accelerate
import CoreMedia
import DiskArbitration
import Foundation
import SwiftUI

// MARK: - Configuration
struct AppConfig {
    /// Set to true for demo/testing, false for production
    static let DEMO_MODE = true  // TODO: Set to false when deploying to production
}

// MARK: - Design System
// Design tokens (AppColors, AppSpacing, AppRadius) have been extracted to
// `Design/DesignTokens.swift`. Glass styles (GlassButtonStyle,
// HoverButtonStyle, glassEffectIfAvailable) are in `Design/GlassStyles.swift`.
// Window chrome is documented in `Design/WindowChrome.swift`.
// See `Design/README.md` for the rules around that folder.

// MARK: - App Entry Point
struct VirginProjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var startupCoordinator = StartupCoordinator()

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !startupCoordinator.isComplete {
                    SplashView(coordinator: startupCoordinator)
                        .zIndex(1000)
                        .transition(.opacity)
                }
            }
            .task {
                await startupCoordinator.runStartupSequence()
            }
            // Add an invisible toolbar to trigger unified window chrome
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    EmptyView()
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        .defaultSize(width: 1200, height: 800)
    }
}

// MARK: - App Delegate for Launch Configuration
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Surfaces the most recent migration outcome to the UI (e.g. a splash
    /// screen or toast). `nil` if migration was skipped because it had
    /// already run on this machine.
    static var migrationOutcome: MigrationOutcome?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App delegate did finish launching")

        // Phase 0: Run the one-shot legacy-Desktop → Application Support migration
        // synchronously, before any other code touches files. Idempotent —
        // subsequent launches no-op via `AppState.migrationCompletedAt`.
        //
        // See ADR-1014 and docs/prd/file-management-teams-sync/PHASE_0_TASKS.md
        // task 0C3.
        runPhase0MigrationIfNeeded()

        // Ensure the app appears in the Dock and App Switcher
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // The unified window chrome from .windowToolbarStyle(.unified(showsTitle: false))
        // already provides the transparent titlebar and proper corner radius.
        // No manual window configuration needed - SwiftUI handles it correctly.

        // Auto-install no-transcribe in the background if not already present
        Task {
            await TranscriptionService.shared.setupIfNeeded()
        }
    }

    /// Runs the legacy-Desktop migration and logs the outcome to the audit log.
    /// Failures are logged but do not block app launch; the migration will be
    /// retried on the next launch.
    ///
    /// This is in two independent passes, each idempotent and gated by its
    /// own marker in `AppState`:
    ///   1. **Primary** (`StorageMigrator`): moves `.m4a` and `.txt` files
    ///      into UUID-named recording folders. Gated by `migrationCompletedAt`.
    ///   2. **Follow-up** (`LegacyMetadataMigrator`): processes legacy
    ///      `.metadata.json` sidecars (extract inline transcripts), moves
    ///      non-`.m4a` Desktop audio (DS2/MP3/WAV), and removes the legacy
    ///      `.audit_log.jsonl` dotfile. Gated by `legacyMetadataCleanedAt`.
    ///
    /// Two passes rather than one schema version so users upgrading from a
    /// build that only had pass 1 still get pass 2 on next launch without a
    /// manual reset.
    private func runPhase0MigrationIfNeeded() {
        // Pass 1 — primary audio/transcript move.
        do {
            let outcome = try StorageMigrator.runIfNeeded()
            AppDelegate.migrationOutcome = outcome
            if outcome.wasSkipped {
                print("ℹ️  Phase 0 primary migration: already completed on a previous launch; skipping.")
            } else {
                print("✅ Phase 0 primary migration: moved \(outcome.filesMoved) files across \(outcome.recordingsCreated) recordings (errors: \(outcome.errorCount)).")
                AuditLogger.shared.log(
                    .migrationCompleted,
                    payload: [
                        "pass": .string("primary"),
                        "recordingsCreated": .int(outcome.recordingsCreated),
                        "filesMoved": .int(outcome.filesMoved),
                        "errorCount": .int(outcome.errorCount),
                    ]
                )
            }
        } catch {
            print("❌ Phase 0 primary migration failed: \(error). Will retry on next launch.")
        }

        // Pass 2 — follow-up for legacy metadata + non-m4a audio + audit log.
        do {
            let outcome = try LegacyMetadataMigrator.runIfNeeded()
            if outcome.wasSkipped {
                print("ℹ️  Phase 0 follow-up migration: already completed on a previous launch; skipping.")
            } else {
                print("""
                    ✅ Phase 0 follow-up migration:
                       transcripts migrated: \(outcome.transcriptsMigrated)
                       anonymized transcripts migrated: \(outcome.anonymizedMigrated)
                       orphan recordings created: \(outcome.orphanRecordingsCreated)
                       non-m4a audio migrated: \(outcome.nonM4AAudioMigrated)
                       legacy metadata files removed: \(outcome.metadataFilesRemoved)
                       legacy audit log removed: \(outcome.legacyAuditLogRemoved)
                       errors: \(outcome.errorCount)
                    """)
                AuditLogger.shared.log(
                    .migrationCompleted,
                    payload: [
                        "pass": .string("legacyMetadata"),
                        "transcriptsMigrated": .int(outcome.transcriptsMigrated),
                        "anonymizedMigrated": .int(outcome.anonymizedMigrated),
                        "orphanRecordingsCreated": .int(outcome.orphanRecordingsCreated),
                        "nonM4AAudioMigrated": .int(outcome.nonM4AAudioMigrated),
                        "metadataFilesRemoved": .int(outcome.metadataFilesRemoved),
                        "legacyAuditLogRemoved": .bool(outcome.legacyAuditLogRemoved),
                        "errorCount": .int(outcome.errorCount),
                    ]
                )
            }
        } catch {
            print("❌ Phase 0 follow-up migration failed: \(error). Will retry on next launch.")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

// MARK: - File Manager
class AudioFileManager: ObservableObject {
    static let shared = AudioFileManager()

    let audioFolderPath: String

    private init() {
        // Create lydfiler folder on Desktop
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)
            .first!
        audioFolderPath = desktopPath.appendingPathComponent("lydfiler").path

        createAudioFolder()
    }

    /// Create the lydfiler folder if it doesn't exist
    func createAudioFolder() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: audioFolderPath) {
            do {
                try fileManager.createDirectory(
                    atPath: audioFolderPath, withIntermediateDirectories: true)
                print("Created lydfiler folder at: \(audioFolderPath)")
            } catch {
                print("Failed to create lydfiler folder: \(error)")
            }
        }
    }

    /// Generate timestamped filename: lydfil_YYYYMMDD_HHMMSS
    func generateFilename(extension ext: String = "m4a") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return "lydfil_\(timestamp).\(ext)"
    }

    /// Get full path for a new audio file
    func getNewFilePath(extension ext: String = "m4a") -> String {
        let filename = generateFilename(extension: ext)
        return (audioFolderPath as NSString).appendingPathComponent(filename)
    }
}

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

// MARK: - Recording Item Model
struct RecordingItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let filename: String
    let path: String
    let date: Date
    let size: Int64
    let duration: TimeInterval

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Player
class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()

    @Published var isPlaying = false
    @Published var currentPlayingFile: String?
    @Published var currentPlayingURL: URL?
    @Published var playbackProgress: Double = 0
    @Published var duration: TimeInterval = 0

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    private override init() {
        super.init()
    }

    func play(url: URL) {
        // Stop current playback if any
        stop()

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            if let player = audioPlayer {
                duration = player.duration
                player.play()
                isPlaying = true
                currentPlayingFile = url.lastPathComponent
                currentPlayingURL = url
                startProgressTimer()
                print("▶️ Playing: \(url.lastPathComponent)")
            }
        } catch {
            print("❌ Error playing audio: \(error)")
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentPlayingFile = nil
        currentPlayingURL = nil
        playbackProgress = 0
        stopProgressTimer()
    }

    func togglePlayPause() {
        guard let player = audioPlayer else { return }

        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopProgressTimer()
        } else {
            player.play()
            isPlaying = true
            startProgressTimer()
        }
    }

    /// Seek to a specific position (0.0 – 1.0 progress fraction).
    func seek(to progress: Double) {
        guard let player = audioPlayer else { return }
        let clamped = max(0, min(1, progress))
        player.currentTime = clamped * player.duration
        playbackProgress = clamped
    }

    /// Restart playback from the beginning.
    func restart() {
        guard let player = audioPlayer else { return }
        player.currentTime = 0
        playbackProgress = 0
        if !player.isPlaying {
            player.play()
            isPlaying = true
            startProgressTimer()
        }
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            guard player.duration > 0 else { return }
            self.playbackProgress = player.currentTime / player.duration
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentPlayingFile = nil
        currentPlayingURL = nil
        playbackProgress = 0
        stopProgressTimer()
    }
}

// MARK: - Recordings Manager
//
// As of Phase 0 (ADR-1014), recordings live in `RecordingStore` under
// `~/Library/Application Support/AudioRecordingManager/recordings/<uuid>/`,
// not on the Desktop. This class is a thin adapter that exposes the store's
// contents as `[RecordingItem]` for the existing UI.
//
// The `RecordingItem` model is unchanged; `path` is the absolute audio file
// path (now under Application Support), and `filename` is the human-readable
// `displayName` from the sidecar — not the opaque UUID on disk.
class RecordingsManager: ObservableObject {
    static let shared = RecordingsManager()

    @Published var recordings: [RecordingItem] = []

    /// Subscription to `RecordingStore.didChangeNotification` so the list
    /// stays in sync with sidecar writes.
    private var changeObserver: NSObjectProtocol?
    private var reloadWorkItem: DispatchWorkItem?

    private init() {
        loadRecordings()
        subscribeToStoreChanges()
    }

    deinit {
        if let token = changeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Subscribe to RecordingStore notifications so the recordings list
    /// updates when sidecars change (create, finalize, updateMeta, delete).
    private func subscribeToStoreChanges() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: RecordingStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Debounce so a burst of writes doesn't trigger many reloads.
            self?.reloadWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.loadRecordings()
            }
            self?.reloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    func loadRecordings() {
        let metas = RecordingStore.shared.loadAll()
        var items: [RecordingItem] = []

        for meta in metas {
            // Skip recordings whose audio is not on disk (e.g. orphan
            // metadata records) — they shouldn't appear in the recordings
            // list. They remain in the store and surface elsewhere later.
            guard meta.audio.status == .done else { continue }

            let audioURL = StorageLayout.recordingFolder(id: meta.id)
                .appendingPathComponent(meta.audio.filename)
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }

            let size = meta.audio.sizeBytes
                ?? (try? FileManager.default
                    .attributesOfItem(atPath: audioURL.path)[.size] as? Int64)
                ?? 0

            let duration: TimeInterval
            if let stored = meta.durationSeconds, stored > 0 {
                duration = stored
            } else if let f = try? AVAudioFile(forReading: audioURL) {
                let d = Double(f.length) / f.processingFormat.sampleRate
                duration = d.isNaN ? 0 : d
            } else {
                duration = 0
            }

            items.append(
                RecordingItem(
                    id: meta.id,
                    filename: meta.displayName,
                    path: audioURL.path,
                    date: meta.createdAt,
                    size: size,
                    duration: duration
                )
            )
        }

        recordings = items.sorted { $0.date > $1.date }
        print("📋 Loaded \(recordings.count) recordings from RecordingStore")
    }

    func deleteRecording(_ item: RecordingItem) {
        do {
            try RecordingStore.shared.delete(id: item.id)
            print("🗑️ Deleted: \(item.filename)")
            // RecordingStore posts didChangeNotification; subscriber will reload.
        } catch {
            print("❌ Error deleting recording: \(error)")
        }
    }
}

// MARK: - Glass Effect Helpers
// `glassEffectIfAvailable`, `GlassButtonStyle`, and `HoverButtonStyle` have
// been extracted to `Design/GlassStyles.swift`. See `Design/README.md`.

// MARK: - Cursor Modifier
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.background(
            GeometryReader { geometry in
                CursorHostingView(cursor: cursor, frame: geometry.frame(in: .local))
            }
        )
    }

    func introspectSplitView(customize: @escaping (NSSplitView) -> Void) -> some View {
        self.background(
            SplitViewIntrospector(customize: customize)
        )
    }
}

// MARK: - SplitView Introspector
struct SplitViewIntrospector: NSViewRepresentable {
    let customize: (NSSplitView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let splitView = self.findSplitView(in: view) {
                self.customize(splitView)
                // Set delegate to prevent resizing
                splitView.delegate = context.coordinator
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func findSplitView(in view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let parent = current?.superview {
            if let splitView = parent as? NSSplitView {
                return splitView
            }
            current = parent
        }
        return nil
    }

    class Coordinator: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            return false
        }

        func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
            return true
        }

        func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            // Return zero rect to make divider non-interactive
            return .zero
        }
    }
}

struct CursorHostingView: NSViewRepresentable {
    let cursor: NSCursor
    let frame: CGRect

    func makeNSView(context: Context) -> CursorTrackingView {
        let view = CursorTrackingView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorTrackingView, context: Context) {
        nsView.cursor = cursor
    }
}

class CursorTrackingView: NSView {
    var cursor: NSCursor = .arrow
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate,
        ]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }
}

// MARK: - Audio File Info Model
struct AudioFileInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let modificationDate: Date
    let fileExtension: String

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }
}

// MARK: - SD Card Manager
class SDCardManager: ObservableObject {
    static let shared = SDCardManager()

    @Published var isSDCardInserted = false
    @Published var sdCardPath: String?
    @Published var sdCardVolumeName: String?
    @Published var audioFiles: [AudioFileInfo] = []
    @Published var isScanning = false

    private var session: DASession?

    private init() {
        setupDiskArbitration()
    }

    deinit {
        if let session = session {
            DASessionUnscheduleFromRunLoop(
                session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    // MARK: - Polling Mechanism (Fallback)
    // MARK: - Disk Arbitration Setup
    private func setupDiskArbitration() {
        print("🔧 Setting up DiskArbitration...")

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            print("❌ Failed to create DiskArbitration session")
            return
        }

        self.session = session
        print("✅ DiskArbitration session created")

        // Schedule on MAIN run loop (not current, which might be different in SwiftUI)
        DASessionScheduleWithRunLoop(
            session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        print("✅ Session scheduled on main run loop")

        let appearedCallback: DADiskAppearedCallback = { disk, context in
            print("🚨 DISK APPEARED CALLBACK FIRED!")
            guard let context = context else {
                print("❌ No context in callback")
                return
            }
            let manager = Unmanaged<SDCardManager>.fromOpaque(context).takeUnretainedValue()
            manager.diskAppeared(disk: disk)
        }

        let disappearedCallback: DADiskDisappearedCallback = { disk, context in
            print("🚨 DISK DISAPPEARED CALLBACK FIRED!")
            guard let context = context else { return }
            let manager = Unmanaged<SDCardManager>.fromOpaque(context).takeUnretainedValue()
            manager.diskDisappeared(disk: disk)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, appearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, disappearedCallback, context)
        print("✅ Callbacks registered")

        print("✅ SD Card monitoring started - waiting for disk events...")
    }

    // MARK: - Disk Events
    private func diskAppeared(disk: DADisk) {
        guard let diskDescription = DADiskCopyDescription(disk) as? [String: Any] else { return }

        // Get volume path - can be either a URL or a String
        var volumePath: String? = nil
        if let pathURL = diskDescription[kDADiskDescriptionVolumePathKey as String] as? URL {
            volumePath = pathURL.path
        } else if let pathString = diskDescription[kDADiskDescriptionVolumePathKey as String]
            as? String
        {
            volumePath = pathString
        }

        print("\n🔍 ======== DISK APPEARED ========")
        print(
            "📀 Volume Name: \(diskDescription[kDADiskDescriptionVolumeNameKey as String] as? String ?? "Unknown")"
        )
        print("📂 Volume Path: \(volumePath ?? "None")")
        print(
            "🔌 Removable: \(diskDescription[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false)"
        )
        print("================================\n")

        if isValidSDCard(description: diskDescription) {
            // Wait for volume to be mounted, then process
            self.waitForVolumeMount(disk: disk, attempts: 0)
        }
    }

    private func waitForVolumeMount(disk: DADisk, attempts: Int) {
        guard attempts < 10 else {
            print("⚠️ Failed to get volume path after 10 attempts")
            return
        }

        // IMPORTANT: Re-query the disk description on each attempt!
        // The disk description changes as the volume gets mounted
        guard let diskDescription = DADiskCopyDescription(disk) as? [String: Any] else {
            print("⚠️ Could not get disk description")
            return
        }

        // Get volume path - can be either a URL or a String
        var volumePath: String? = nil
        if let pathURL = diskDescription[kDADiskDescriptionVolumePathKey as String] as? URL {
            volumePath = pathURL.path
        } else if let pathString = diskDescription[kDADiskDescriptionVolumePathKey as String]
            as? String
        {
            volumePath = pathString
        }

        if let path = volumePath {
            // Verify this is an Olympus voice recorder SD card
            guard isOlympusRecorderMedia(at: path) else {
                let volumeName = diskDescription[kDADiskDescriptionVolumeNameKey as String] as? String ?? "Unknown"
                print("🔍 ======== NOT OLYMPUS MEDIA ========")
                print("📍 Path: \(path)")
                print("📛 Name: \(volumeName)")
                print("🔍 No Olympus folders or DSS/DS2 files found")
                print("====================================\n")
                return
            }

            // Success! We have an Olympus recorder SD card
            DispatchQueue.main.async {
                self.sdCardVolumeName =
                    diskDescription[kDADiskDescriptionVolumeNameKey as String] as? String
                self.sdCardPath = path
                self.isSDCardInserted = true

                print("✅ ======== OLYMPUS SD CARD DETECTED ========")
                print("📍 Path: \(path)")
                print("📛 Name: \(self.sdCardVolumeName ?? "Unknown")")
                print("🔍 Scanning for audio files...")
                print("=============================================\n")

                self.scanForAudioFiles()
                self.launchDSSPlayer()
            }
        } else {
            // No path yet, retry after a delay
            print("⏳ Waiting for volume to mount (attempt \(attempts + 1)/10)...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.waitForVolumeMount(disk: disk, attempts: attempts + 1)
            }
        }
    }

    private func diskDisappeared(disk: DADisk) {
        guard let diskDescription = DADiskCopyDescription(disk) as? [String: Any] else { return }

        let volumeName =
            diskDescription[kDADiskDescriptionVolumeNameKey as String] as? String ?? "Unknown"

        if isValidSDCard(description: diskDescription) {
            DispatchQueue.main.async {
                print("\n⏏️ ======== SD CARD REMOVED ========")
                print("📛 Name: \(volumeName)")
                print("====================================\n")

                self.isSDCardInserted = false
                self.sdCardPath = nil
                self.sdCardVolumeName = nil
                self.audioFiles = []
            }
        }
    }

    // MARK: - SD Card Validation
    /// Validates if the disk is an Olympus voice recorder SD card
    /// Only accepts SD cards with Olympus recorder folder structure or audio files
    private func isValidSDCard(description: [String: Any]) -> Bool {
        // Check if media is removable
        guard let removable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool,
            removable
        else {
            print("🔍 Disk is not removable, skipping")
            return false
        }

        // Exclude disk images by checking the device protocol
        if let deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String]
            as? String
        {
            if deviceProtocol == "Disk Image" || deviceProtocol == "Virtual Interface" {
                print("🔍 Disk is a disk image or virtual device, skipping")
                return false
            }
            // Exclude Apple File Conduit (AFC) - used by iPods/iPhones
            if deviceProtocol == "Apple File Conduit" || deviceProtocol == "AFC" {
                print("🔍 Disk is an Apple device (AFC protocol), skipping")
                return false
            }
        }

        // Check if volume is read-only (many PKG/DMG installers are read-only)
        if let volumeWritable = description[kDADiskDescriptionMediaWritableKey as String] as? Bool {
            if !volumeWritable {
                print("🔍 Volume is read-only (likely installer/disk image), skipping")
                return false
            }
        }

        // Note: Final validation for Olympus content happens in waitForVolumeMount
        // after the volume path is available
        print("🔍 Removable media detected, will verify Olympus content after mount...")
        return true
    }

    /// Check if the mounted volume contains Olympus voice recorder content
    private func isOlympusRecorderMedia(at path: String) -> Bool {
        let fileManager = FileManager.default

        // Check for Olympus-specific folder structures
        let olympusFolders = [
            "RECORDER",      // Common Olympus folder
            "DSS_FLDR",      // DSS files folder
            "DICT",          // Dictation folder
            "MUSIC",         // Some Olympus recorders use this
            "OLYMPUS",       // Olympus brand folder
        ]

        for folder in olympusFolders {
            let folderPath = (path as NSString).appendingPathComponent(folder)
            if fileManager.fileExists(atPath: folderPath) {
                print("✅ Found Olympus folder: \(folder)")
                return true
            }
        }

        // Check for DSS/DS2 audio files (Olympus proprietary formats)
        if let enumerator = fileManager.enumerator(atPath: path) {
            for case let file as String in enumerator {
                let ext = (file as NSString).pathExtension.lowercased()
                if ext == "dss" || ext == "ds2" {
                    print("✅ Found Olympus audio file: \(file)")
                    return true
                }
            }
        }

        print("🔍 No Olympus content found at: \(path)")
        return false
    }

    // MARK: - Audio File Scanning
    func scanForAudioFiles() {
        guard let sdPath = sdCardPath else {
            audioFiles = []
            return
        }

        isScanning = true
        var foundFiles: [AudioFileInfo] = []
        let fileManager = FileManager.default
        let supportedExtensions = ["m4a", "mp3", "wav", "aiff", "aif", "dss", "ds2", "mp4"]

        if let enumerator = fileManager.enumerator(atPath: sdPath) {
            for case let file as String in enumerator {
                let filePath = (sdPath as NSString).appendingPathComponent(file)
                let fileURL = URL(fileURLWithPath: filePath)
                let ext = fileURL.pathExtension.lowercased()

                if supportedExtensions.contains(ext) {
                    do {
                        let attributes = try fileManager.attributesOfItem(atPath: filePath)
                        if let fileSize = attributes[.size] as? Int64,
                            let modificationDate = attributes[.modificationDate] as? Date
                        {

                            let fileInfo = AudioFileInfo(
                                name: fileURL.lastPathComponent,
                                path: filePath,
                                size: fileSize,
                                modificationDate: modificationDate,
                                fileExtension: ext
                            )
                            foundFiles.append(fileInfo)
                        }
                    } catch {
                        print("⚠️ Error getting file attributes: \(error)")
                    }
                }
            }
        }

        foundFiles.sort { $0.modificationDate > $1.modificationDate }

        DispatchQueue.main.async {
            self.audioFiles = foundFiles
            self.isScanning = false
            print("✅ Found \(foundFiles.count) audio files")
        }
    }

    // MARK: - DSS Player Launch
    func launchDSSPlayer() {
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.olympus.dssplayer")
        {
            openDSSPlayerApp(at: appURL)
            return
        }

        let appPaths = [
            "/Applications/DSS Player.app",
            "/Applications/Olympus DSS Player.app",
            "/Applications/DSSPlayer.app",
            "/Applications/DSS Player Plus.app",
        ]

        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                let appURL = URL(fileURLWithPath: path)
                openDSSPlayerApp(at: appURL)
                return
            }
        }

        print("⚠️ DSS Player app not found")
    }

    private func openDSSPlayerApp(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let sdPath = sdCardPath {
            configuration.arguments = [sdPath]
        }

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error = error {
                print("❌ Error opening DSS Player: \(error.localizedDescription)")
            } else {
                print("✅ DSS Player opened successfully")
            }
        }
    }

    // MARK: - Eject SD Card
    func ejectSDCard() {
        guard let path = sdCardPath else {
            print("⚠️ No SD card path to eject")
            return
        }

        print("⏏️ Attempting to eject SD card at: \(path)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["eject", path]

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                print("✅ SD card ejected successfully")
                // State will be updated by diskDisappeared callback or polling
            } else {
                print("❌ Failed to eject SD card (status: \(task.terminationStatus))")
            }
        } catch {
            print("❌ Error ejecting SD card: \(error.localizedDescription)")
        }
    }
}

// MARK: - Record Button with NAV Styling
struct RecordButton: View {
    let isRecording: Bool
    let isVerified: Bool
    let action: () -> Void
    @State private var isHovering = false
    @State private var showAudioSourceMenu = false

    var body: some View {
        HStack(spacing: 12) {
            // Main Record/Stop Button
            Button(action: action) {
                if isRecording {
                    // Stop button with Liquid Glass styling
                    VStack(spacing: AppSpacing.sm) {
                        Rectangle()
                            .fill(AppColors.destructive)
                            .frame(width: 56, height: 56)
                            .cornerRadius(AppRadius.small)
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColors.destructive)
                            .textCase(.uppercase)
                            .tracking(1)
                    }
                } else if isVerified {
                    // Start Recording button with glass effect
                    Text("Start Recording")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .tracking(0.5)
                        .padding(.horizontal, AppSpacing.xxl + AppSpacing.sm)
                        .padding(.vertical, AppSpacing.lg + 2)
                        .background(isHovering ? AppColors.destructive.opacity(0.85) : AppColors.destructive)
                        .cornerRadius(AppRadius.large)
                        .animation(.easeInOut(duration: 0.15), value: isHovering)
                } else {
                    // Verifying state - grey/disabled
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .colorScheme(.dark)
                        Text("Verifying Microphone")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .tracking(0.5)
                    }
                    .padding(.horizontal, AppSpacing.xxl + AppSpacing.sm)
                    .padding(.vertical, AppSpacing.lg + 2)
                    .background(Color.gray.opacity(0.5))
                    .cornerRadius(AppRadius.large)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isVerified && !isRecording)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if isVerified || isRecording {
                        isHovering = true
                        DispatchQueue.main.async { NSCursor.pointingHand.set() }
                    }
                case .ended:
                    isHovering = false
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
            }

            // Audio Source Settings Button (only show when not recording)
            if !isRecording {
                Button(action: {
                    showAudioSourceMenu.toggle()
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(AppRadius.medium)
                }
                .buttonStyle(.plain)
                .help("Audio Input Settings")
                .popover(isPresented: $showAudioSourceMenu, arrowEdge: .bottom) {
                    AudioSourceSelector()
                }
            }
        }
    }
}

// MARK: - Audio Source Selector
struct AudioSourceSelector: View {
    @State private var audioDevices: [String] = []
    @State private var selectedDevice: String = "Default"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio Input Source")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Divider()

            // List available audio devices
            VStack(alignment: .leading, spacing: 0) {
                ForEach(
                    audioDevices.isEmpty ? ["Default", "Built-in Microphone"] : audioDevices,
                    id: \.self
                ) { device in
                    Button(action: {
                        selectedDevice = device
                        // TODO: Set audio input device
                    }) {
                        HStack {
                            Text(device)
                                .font(.system(size: 13))
                            Spacer()
                            if selectedDevice == device {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(selectedDevice == device ? Color.blue.opacity(0.1) : Color.clear)
                }
            }

            Divider()

            Text("Change audio input device")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(width: 250)
        .onAppear {
            loadAudioDevices()
        }
    }

    func loadAudioDevices() {
        // TODO: Get actual audio devices from AVAudioSession/CoreAudio
        audioDevices = ["Default", "Built-in Microphone", "External Microphone"]
    }
}

// MARK: - Folder Item Model
struct FolderItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var isExpanded: Bool = true
    var subfolders: [FolderItem] = []
    var recordings: [RecordingItem] = []
}

// MARK: - Folder Manager
class FolderManager: ObservableObject {
    @Published var folderStructure: [FolderItem] = []
    @Published var rootRecordings: [RecordingItem] = []
    private let baseURL: URL

    // File system monitoring
    private var fileDescriptors: [Int32] = []
    private var dispatchSources: [DispatchSourceFileSystemObject] = []
    private var reloadWorkItem: DispatchWorkItem?

    init(basePath: String) {
        self.baseURL = URL(fileURLWithPath: basePath)
        loadFolderStructure()
        startWatchingFolders()
    }

    deinit {
        stopWatchingFolders()
    }

    /// Start monitoring the base folder and all subfolders for changes
    private func startWatchingFolders() {
        // Watch the base folder
        watchFolder(at: baseURL.path)

        // Watch all subfolders
        let fileManager = FileManager.default
        if let items = try? fileManager.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        {
            for item in items {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    watchFolder(at: item.path)
                }
            }
        }
        print("👁️ Watching \(dispatchSources.count) folders for changes")
    }

    /// Watch a single folder for changes
    private func watchFolder(at path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("⚠️ Could not open folder for monitoring: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }

        source.setCancelHandler {
            close(fd)
        }

        fileDescriptors.append(fd)
        dispatchSources.append(source)
        source.resume()
    }

    /// Debounced reload to handle rapid file system changes
    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            print("📁 Folder structure changed, reloading...")
            self?.loadFolderStructure()
            // Also reload the shared RecordingsManager
            RecordingsManager.shared.loadRecordings()
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    /// Stop monitoring all folders
    private func stopWatchingFolders() {
        for source in dispatchSources {
            source.cancel()
        }
        dispatchSources.removeAll()
        fileDescriptors.removeAll()
        reloadWorkItem?.cancel()
    }

    /// Refresh watchers when folder structure changes (e.g., new folder created)
    private func refreshWatchers() {
        stopWatchingFolders()
        startWatchingFolders()
    }

    func loadFolderStructure() {
        let fileManager = FileManager.default
        let previousFolderCount = folderStructure.count

        // Get all items in lydfiler folder
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: baseURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else {
            return
        }

        var folders: [FolderItem] = []
        var newRootRecordings: [RecordingItem] = []

        for item in items {
            let isDirectory =
                (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDirectory {
                let recordings = loadRecordingsInFolder(item)
                let folder = FolderItem(
                    name: item.lastPathComponent,
                    path: item.path,
                    recordings: recordings
                )
                folders.append(folder)
            } else if item.pathExtension == "m4a" || item.pathExtension == "mp3"
                || item.pathExtension == "wav"
            {
                if let recording = createRecordingItem(from: item) {
                    newRootRecordings.append(recording)
                }
            }
        }

        // Sort folders alphabetically
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Sort root recordings by date, newest first
        newRootRecordings.sort { $0.date > $1.date }

        // Update published properties
        folderStructure = folders
        rootRecordings = newRootRecordings

        print("📁 Loaded \(folders.count) folders, \(newRootRecordings.count) root recordings")

        // If folder count changed, refresh watchers to include new folders
        if folders.count != previousFolderCount {
            refreshWatchers()
        }
    }

    func loadRecordingsInFolder(_ folderURL: URL) -> [RecordingItem] {
        let fileManager = FileManager.default
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            return []
        }

        return items.compactMap { item in
            if item.pathExtension == "m4a" || item.pathExtension == "mp3"
                || item.pathExtension == "wav"
            {
                return createRecordingItem(from: item)
            }
            return nil
        }
    }

    func createRecordingItem(from url: URL) -> RecordingItem? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = attrs[.size] as? Int64 ?? 0
        let date = attrs[.modificationDate] as? Date ?? Date()

        let audioFile = try? AVAudioFile(forReading: url)
        let audioDuration = audioFile.map {
            Double($0.length) / $0.processingFormat.sampleRate
        } ?? 0

        // Derive stable ID from the parent folder UUID (Phase 0 layout)
        // or generate a deterministic one from the path for legacy items.
        let stableId = StorageLayout.recordingId(from: url.deletingLastPathComponent())
            ?? UUID(uuidString: url.path.hash.description)
            ?? UUID()

        return RecordingItem(
            id: stableId,
            filename: url.lastPathComponent,
            path: url.path,
            date: date,
            size: size,
            duration: audioDuration.isNaN ? 0 : audioDuration
        )
    }

    func createFolder(name: String) {
        let folderURL = baseURL.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadFolderStructure()
    }

    func getTotalStorageUsed() -> String {
        let fileManager = FileManager.default
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: baseURL, includingPropertiesForKeys: [.fileSizeKey], options: [])
        else {
            return "0 MB"
        }

        var totalSize: Int64 = 0
        for item in items {
            if let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        let mb = Double(totalSize) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Folder Tree View
struct FolderTreeView: View {
    let folderPath: String
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var folderManager: FolderManager
    @State private var isHovering = false
    @State private var isExpanded = false

    // Get the current folder data from folderManager (always up-to-date)
    private var folder: FolderItem? {
        folderManager.folderStructure.first { $0.path == folderPath }
    }

    var body: some View {
        if let folder = folder {
            VStack(spacing: 0) {
                // Folder row
                HStack(spacing: 8) {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)

                    Text(folder.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovering ? .white : .primary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isHovering ? Color.blue.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovering = hovering
                }

                // Expanded recordings
                if isExpanded {
                    ForEach(folder.recordings) { recording in
                        HStack(spacing: 8) {
                            Spacer()
                                .frame(width: 28)  // Indent for nested items

                            RecordingRowView(
                                recording: recording,
                                isPlaying: audioPlayer.currentPlayingURL == URL(fileURLWithPath: recording.path) && audioPlayer.isPlaying,
                                audioPlayer: audioPlayer,
                                recordingsManager: recordingsManager
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - New Folder Dialog
struct NewFolderDialog: View {
    @Binding var folderName: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Folder")
                .font(.system(size: 15, weight: .semibold))

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onCreate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

// MARK: - Anonymization Reminder Dialog
struct AnonymizationReminderDialog: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.warning)

                Text("Before uploading")
                    .font(.system(size: 18, weight: .semibold))

                Text("Check that the text is anonymized")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // Checklist
            VStack(alignment: .leading, spacing: 10) {
                ChecklistItem(text: "Remove names, contact info, and ID numbers")
                ChecklistItem(text: "Remove names of family, friends, and NAV employees")
                ChecklistItem(text: "Remove health information that could identify the participant")
                ChecklistItem(text: "Use codes like P1, P2, etc. instead of names")
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button(action: onContinue) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.doc.fill")
                        Text("Continue to Teams")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}

// Helper view for checklist items
struct ChecklistItem: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(AppColors.success)
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Recordings Sidebar
// MARK: - Audio Waveform Icon (Custom SVG)
struct AudioWaveformIcon: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Canvas { context, size in
            let fillColor = colorScheme == .dark ? Color.white : Color(red: 32/255, green: 39/255, blue: 51/255)

            // Scale factor to fit 431.77x233.48 viewBox into the given size
            let scale = min(size.width / 431.77, size.height / 233.48)
            let xOffset = (size.width - 431.77 * scale) / 2
            let yOffset = (size.height - 233.48 * scale) / 2

            context.translateBy(x: xOffset, y: yOffset)
            context.scaleBy(x: scale, y: scale)

            // Bar 1: Medium height (left)
            context.fill(
                Path(roundedRect: CGRect(x: 0, y: 50.61, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 2: Short height
            context.fill(
                Path(roundedRect: CGRect(x: 50.11, y: 0, width: 31.11, height: 152.59), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 3: Medium height
            context.fill(
                Path(roundedRect: CGRect(x: 100.22, y: 50.61, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 4: Full height (tallest)
            context.fill(
                Path(roundedRect: CGRect(x: 150.72, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 5: Short height (center)
            context.fill(
                Path(roundedRect: CGRect(x: 200.83, y: 0, width: 31.11, height: 152.59), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 6: Medium height
            context.fill(
                Path(roundedRect: CGRect(x: 250.94, y: 50.6, width: 31.11, height: 182.88), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 7: Full height (tallest)
            context.fill(
                Path(roundedRect: CGRect(x: 300.44, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 8: Very short height
            context.fill(
                Path(roundedRect: CGRect(x: 350.55, y: 50.6, width: 31.11, height: 101.99), cornerRadius: 15),
                with: .color(fillColor)
            )

            // Bar 9: Full height (tallest, right)
            context.fill(
                Path(roundedRect: CGRect(x: 400.66, y: 0, width: 31.11, height: 233.48), cornerRadius: 15),
                with: .color(fillColor)
            )
        }
        .aspectRatio(431.77/233.48, contentMode: .fit)
    }
}

// MARK: - Navigation Panel (left-most narrow column)
struct NavPanel: View {
    @Binding var selectedTab: AppTab
    @Binding var showAbout: Bool
    @State private var isDarkMode: Bool = NSApp.effectiveAppearance.name == .darkAqua

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo area at the top - toolbar will handle traffic light spacing
            VStack(spacing: 8) {
                // Audio waveform icon from SVG
                AudioWaveformIcon()
                    .frame(width: 44, height: 44)

                Text("ARM")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Audio Recording Manager")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 12)

            VStack(spacing: 4) {
                navItem(tab: .record, label: "Ta opp lyd", icon: "mic.fill")
                navItem(tab: .recordings, label: "Lydopptak", icon: "waveform")
                navItem(tab: .transcripts, label: "Transkripsjoner", icon: "doc.text.fill")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Spacer()

            Divider()
                .padding(.horizontal, 12)

            VStack(spacing: 0) {
                Button(action: toggleAppearance) {
                    HStack(spacing: 10) {
                        Image(systemName: isDarkMode ? "sun.max" : "moon")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(isDarkMode ? "Light Mode" : "Dark Mode")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)

                Button(action: { showAbout = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text("About")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func toggleAppearance() {
        isDarkMode.toggle()
        NSApp.appearance = isDarkMode
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }

    @ViewBuilder
    private func navItem(tab: AppTab, label: String, icon: String) -> some View {
        Button(action: { selectedTab = tab }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: selectedTab == tab ? .medium : .regular))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                if selectedTab == tab {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.15))
                }
            }
            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recordings Native View (macOS Glass Design)

// MARK: - Recordings List Column (content column for 3-column split)

struct RecordingsListColumn: View {
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var folderManager: FolderManager
    @ObservedObject var audioPlayer: AudioPlayer
    @Binding var selectedRecording: RecordingItem?

    var body: some View {
        List(selection: $selectedRecording) {
            ForEach(folderManager.folderStructure) { folder in
                Section(folder.name) {
                    ForEach(folder.recordings) { recording in
                        RecordingListRow(
                            recording: recording,
                            isPlaying: audioPlayer.currentPlayingURL == URL(fileURLWithPath: recording.path) && audioPlayer.isPlaying,
                            audioPlayer: audioPlayer,
                            recordingsManager: recordingsManager
                        )
                        .tag(recording)
                        .listRowSeparator(.visible)
                    }
                }
            }

            let rootRecordings = recordingsManager.recordings.filter { recording in
                !folderManager.folderStructure.contains { folder in
                    folder.recordings.contains { $0.path == recording.path }
                }
            }

            if !rootRecordings.isEmpty {
                ForEach(rootRecordings) { recording in
                    RecordingListRow(
                        recording: recording,
                        isPlaying: audioPlayer.currentPlayingURL == URL(fileURLWithPath: recording.path) && audioPlayer.isPlaying,
                        audioPlayer: audioPlayer,
                        recordingsManager: recordingsManager
                    )
                    .tag(recording)
                    .listRowSeparator(.visible)
                }
            }
        }
    }
}

// MARK: - Recording List Row

struct RecordingListRow: View {
    let recording: RecordingItem
    let isPlaying: Bool
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @State private var showDeleteConfirm = false
    @State private var isHovering = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.filename)
                    .font(.body)
                HStack(spacing: 4) {
                    Text(recording.formattedDate)
                    Text("·")
                    Text(recording.formattedDuration)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: isPlaying ? "waveform" : "waveform.circle")
                .font(.title3)
                .foregroundStyle(isPlaying ? .blue : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        }
        .listRowBackground(
            isHovering ? Color(nsColor: .controlAccentColor).opacity(0.1) : Color.clear
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button {
                let url = URL(fileURLWithPath: recording.path)
                if isPlaying {
                    audioPlayer.togglePlayPause()
                } else {
                    audioPlayer.play(url: url)
                }
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }

            Divider()

            Button {
                NSWorkspace.shared.selectFile(recording.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Vis i Finder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Slett", systemImage: "trash")
            }
        }
        .alert("Slett opptak?", isPresented: $showDeleteConfirm) {
            Button("Avbryt", role: .cancel) {}
            Button("Slett", role: .destructive) {
                if isPlaying { audioPlayer.stop() }
                recordingsManager.deleteRecording(recording)
            }
        } message: {
            Text("Er du sikker på at du vil slette \(recording.filename)?")
        }
    }
}

// MARK: - Recording Player (Native)

struct RecordingPlayerNative: View {
    let recording: RecordingItem
    @ObservedObject var audioPlayer: AudioPlayer
    var onNavigateToTranscript: ((UUID) -> Void)?

    // Scrubber state
    @State private var isDraggingScrubber: Bool = false
    @State private var scrubberDragValue: Double = 0

    // Transcription
    @ObservedObject private var transcriptionService = TranscriptionService.shared
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var transcriptionResult: TranscriptionResult?
    @State private var transcriptionError: TranscriptionError?
    @State private var isTranscribing = false
    @AppStorage("transcription.defaultModel")    private var defaultModelRaw = TranscriptionModel.large.rawValue
    @AppStorage("transcription.defaultSpeakers") private var defaultSpeakers = 2
    @AppStorage("transcription.verbatim")        private var verbatim = false
    @AppStorage("transcription.language")        private var language = "no"

    // Diarization (step 2)
    @State private var diarizationTask: Task<Void, Never>?
    @State private var isDiarizing = false
    @State private var diarizationError: String? = nil
    @AppStorage("diarization.hfToken") private var hfToken = ""

    // Analysis (step 3)
    @State private var analysisTask: Task<Void, Never>?
    @State private var isAnalyzing = false
    @State private var analysisError: String? = nil
    @State private var analysisResult: AnalysisResult? = nil
    @State private var showAnalysisResult = false
    @AppStorage("analysis.llmModel") private var llmModel = "qwen3:8b"

    @State private var showSettings = false

    // Ollama status (checked off main thread)
    @State private var ollamaIsRunning = false
    @State private var ollamaIsInstalled = false

    private var isCurrentFile: Bool {
        audioPlayer.currentPlayingURL == URL(fileURLWithPath: recording.path)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero section
                VStack(spacing: 32) {
                    Spacer().frame(height: 60)

                    ZStack {
                        Circle()
                            .fill(.blue.opacity(0.1))
                            .frame(width: 160, height: 160)
                        Image(systemName: "waveform")
                            .font(.system(size: 64, weight: .light))
                            .symbolEffect(.variableColor.iterative.reversing, isActive: isCurrentFile && audioPlayer.isPlaying)
                            .foregroundStyle(isCurrentFile && audioPlayer.isPlaying ? .blue : .secondary)
                    }

                    // Play/pause button
                    Button {
                        let url = URL(fileURLWithPath: recording.path)
                        if isCurrentFile {
                            audioPlayer.togglePlayPause()
                        } else {
                            audioPlayer.play(url: url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                            Text(isCurrentFile && audioPlayer.isPlaying ? "Pause" : "Spill av")
                                .font(.title3.weight(.semibold))
                        }
                        .frame(minWidth: 200)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.blue)

                    if isCurrentFile {
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                Button {
                                    audioPlayer.restart()
                                } label: {
                                    Image(systemName: "backward.end.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Restart")

                                Slider(
                                    value: isDraggingScrubber
                                        ? $scrubberDragValue
                                        : Binding(
                                            get: { audioPlayer.playbackProgress },
                                            set: { _ in }
                                        ),
                                    in: 0...1,
                                    onEditingChanged: { dragging in
                                        if dragging {
                                            isDraggingScrubber = true
                                            scrubberDragValue = audioPlayer.playbackProgress
                                        } else {
                                            audioPlayer.seek(to: scrubberDragValue)
                                            isDraggingScrubber = false
                                        }
                                    }
                                )
                                .accentColor(Color(red: 200/255, green: 16/255, blue: 46/255))
                            }
                            .padding(.horizontal, 40)

                            HStack {
                                Text(formattedTime(
                                    (isDraggingScrubber ? scrubberDragValue : audioPlayer.playbackProgress)
                                    * audioPlayer.duration
                                ))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                Spacer()
                                Text(formattedTime(audioPlayer.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 40)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer().frame(height: 40)
                }
                .frame(maxWidth: .infinity)
                .padding()

                Divider().padding(.horizontal)

                Form {
                    transcriptionSection
                    diarizationSection
                    analysisSection

                    Section("Handlinger") {
                        Button {
                            NSWorkspace.shared.selectFile(recording.path, inFileViewerRootedAtPath: "")
                        } label: {
                            Label("Vis i Finder", systemImage: "folder")
                        }
                    }

                    Section("Fil informasjon") {
                        LabeledContent("Filnavn") {
                            Text(recording.filename)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        LabeledContent("Dato") { Text(recording.formattedDate) }
                        LabeledContent("Varighet") {
                            Text(recording.formattedDuration).font(.body.monospacedDigit())
                        }
                        LabeledContent("Størrelse") { Text(recording.formattedSize) }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(recording.filename)
        .navigationSubtitle("\(recording.formattedDate) · \(recording.formattedDuration)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        NSWorkspace.shared.selectFile(recording.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Label("Vis i Finder", systemImage: "folder")
                    }
                    Divider()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recording.path, forType: .string)
                    } label: {
                        Label("Kopier filbane", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Innstillinger")
            }
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Innstillinger")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Lukk") { showSettings = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
                TranscriptionSettingsView()
            }
            .frame(minWidth: 480, minHeight: 400)
        }
        // Transcript modal and analysis modal removed — both now live
        // in TranscriptEditorView (Transkripsjoner tab).
        .onAppear {
            restoreTranscriptionStateIfNeeded()
            // Restore analysis result
            if analysisResult == nil {
                analysisResult = ProcessingStateCache.shared.analysisResult(for: recording.path)
            }
            // Check Ollama status off main thread
            ollamaIsInstalled = OllamaManager.shared.isInstalled
            if ollamaIsInstalled {
                Task.detached {
                    let running = OllamaManager.shared.isRunning()
                    await MainActor.run { ollamaIsRunning = running }
                }
            }
        }
        .onDisappear {
            transcriptionTask?.cancel()
            diarizationTask?.cancel()
            analysisTask?.cancel()
            TranscriptionService.shared.cancel()
        }
    }

    // MARK: - Transcription state restoration

    /// Restores a cached TranscriptionResult for this file (in-memory cache first,
    /// then JSON on disk, then transcript.txt in the recording's UUID folder).
    private func restoreTranscriptionStateIfNeeded() {
        guard transcriptionResult == nil, !isTranscribing else { return }

        // 1. In-memory cache hit (same app session)
        if let cached = TranscriptionCache.shared.result(for: recording.path) {
            transcriptionResult = cached
            return
        }

        // 2. JSON transcript fallback: check Application Support/AudioRecordingManager/transcripts/<uuid>.json
        //    This preserves speaker diarization labels across app restarts.
        //    Uses recording.id (stable UUID) instead of the audio filename stem
        //    (which is always "audio" in the Phase 0 layout and would collide).
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jsonURL = support.appendingPathComponent("AudioRecordingManager/transcripts/\(recording.id.uuidString).json")
        if FileManager.default.fileExists(atPath: jsonURL.path),
           let jsonData = try? Data(contentsOf: jsonURL) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let result = try? decoder.decode(TranscriptionResult.self, from: jsonData) {
                transcriptionResult = result
                TranscriptionCache.shared.store(result, for: recording.path)
                return
            }
        }

        // 3. Disk fallback: check transcript.txt in the recording's UUID folder
        let txtURL = StorageLayout.transcriptURL(id: recording.id)

        if FileManager.default.fileExists(atPath: txtURL.path),
           let text = try? String(contentsOf: txtURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Build a minimal TranscriptionResult from the plain-text so the UI
            // can show the "Ferdig" state and "Vis transkripsjon" button.
            let segment = TranscriptionSegment(
                id: 0,
                start: 0,
                end: 0,
                text: text,
                speaker: "SPEAKER_00",
                confidence: 1.0,
                words: []
            )
            let meta = TranscriptionResultMetadata(
                inputFile: recording.path,
                processingTimeSeconds: 0,
                modelVariant: "ukjent",
                computeType: "ukjent",
                device: "ukjent",
                diarizationRun: nil
            )
            let result = TranscriptionResult(
                version: "1.0",
                model: "ukjent",
                language: "no",
                durationSeconds: 0,
                numSpeakers: 1,
                segments: [segment],
                metadata: meta
            )
            transcriptionResult = result
            // Also populate the cache so future navigations skip disk I/O
            TranscriptionCache.shared.store(result, for: recording.path)
        }
    }

    // MARK: - Transcription section

    @ViewBuilder
    private var transcriptionSection: some View {
        Section("Transkripsjon") {
            if isTranscribing {
                // In progress
                HStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.75)
                    Text(transcriptionService.stage.displayName.isEmpty
                         ? "Forbereder..."
                         : transcriptionService.stage.displayName)
                        .font(.body)
                        .animation(.default, value: transcriptionService.stage.displayName)
                }
                if transcriptionService.progress > 0 {
                    ProgressView(value: transcriptionService.progress)
                        .animation(.easeInOut(duration: 0.4), value: transcriptionService.progress)
                }
                Button("Avbryt", role: .destructive, action: cancelTranscription)
            } else if let result = transcriptionResult {
                // Completed
                Label {
                    Text("Ferdig — \(result.segments.count) segmenter, \(result.numSpeakers) taler\(result.numSpeakers == 1 ? "" : "e")")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    onNavigateToTranscript?(recording.id)
                } label: {
                    Label("Åpne i transkripsjonseditoren", systemImage: "doc.text")
                }
                Button {
                    startTranscription()
                } label: {
                    Label("Transkriber på nytt", systemImage: "arrow.counterclockwise")
                }
            } else if let error = transcriptionError {
                // Failed
                Label {
                    Text("Feil: \(error.errorDescription ?? "Ukjent feil")")
                        .foregroundStyle(.red)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Button("Prøv igjen", action: startTranscription)
            } else {
                // Not started
                if transcriptionService.isInstalled {
                    Button {
                        startTranscription()
                    } label: {
                        Label("Transkriber med NB-Whisper", systemImage: "waveform.and.mic")
                    }
                    let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .medium
                    Text("Modell: \(model.displayName) · \(defaultSpeakers) taler\(defaultSpeakers == 1 ? "" : "e")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if transcriptionService.isSettingUp {
                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                        Text("Setter opp transkripsjon…")
                    }
                    let stageDesc = transcriptionService.setupStageDescription
                    Text(stageDesc.isEmpty
                         ? "Første gangs installasjon tar 5–15 min (torch ~2 GB)."
                         : stageDesc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let err = transcriptionService.setupError {
                    Label("Oppsett feilet", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Prøv igjen") {
                        Task { await TranscriptionService.shared.setupIfNeeded() }
                    }
                } else {
                    // setupIfNeeded() har ikke kjørt ennå (f.eks. første gang etter cold start)
                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                        Text("Setter opp transkripsjon…")
                    }
                    Text("Starter oppsett. Vennligst vent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onAppear {
                            Task { await TranscriptionService.shared.setupIfNeeded() }
                        }
                }
            }
        }
    }

    // MARK: - Diarization section

    @ViewBuilder
    private var diarizationSection: some View {
        Section("Talerutskilling") {
            if isDiarizing {
                HStack(spacing: 10) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                    Text(transcriptionService.stage == .diarizing
                         ? "Identifiserer talere..."
                         : "Forbereder...")
                }
                if transcriptionService.diarizationProgress > 0 {
                    ProgressView(value: transcriptionService.diarizationProgress)
                        .animation(.easeInOut(duration: 0.4), value: transcriptionService.diarizationProgress)
                }
                Button("Avbryt", role: .destructive) {
                    diarizationTask?.cancel()
                    TranscriptionService.shared.cancel()
                    isDiarizing = false
                }
            } else if let result = transcriptionResult, result.metadata.diarizationRun == true {
                // Completed
                Label {
                    Text("Talere identifisert")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    startDiarization()
                } label: {
                    Label("Kjør på nytt", systemImage: "arrow.counterclockwise")
                }
            } else if let error = diarizationError {
                Label {
                    Text(error).foregroundStyle(.red)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Button("Prøv igjen", action: startDiarization)
            } else {
                // Not started
                if transcriptionResult != nil {
                    if hfToken.isEmpty {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Legg til HuggingFace-token i innstillinger", systemImage: "key")
                        }
                    } else {
                        Button {
                            startDiarization()
                        } label: {
                            Label("Identifiser talere", systemImage: "person.2.fill")
                        }
                        .disabled(isTranscribing || isAnalyzing)
                        Text("Bruker pyannote · \(defaultSpeakers) talere")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Transkriber lydfilen først")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Analysis section

    @ViewBuilder
    private var analysisSection: some View {
        Section("Analyse") {
            if isAnalyzing {
                HStack(spacing: 10) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.75)
                    Text("Analyserer med \(llmModel)...")
                }
                if transcriptionService.analysisProgress > 0 {
                    ProgressView(value: transcriptionService.analysisProgress)
                        .animation(.easeInOut(duration: 0.4), value: transcriptionService.analysisProgress)
                }
                Button("Avbryt", role: .destructive) {
                    analysisTask?.cancel()
                    TranscriptionService.shared.cancel()
                    isAnalyzing = false
                }
            } else if analysisResult != nil {
                // Completed
                Label {
                    Text("Analyse fullført")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    showAnalysisResult = true
                } label: {
                    Label("Vis analyse", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    startAnalysis()
                } label: {
                    Label("Analyser på nytt", systemImage: "arrow.counterclockwise")
                }
            } else if let error = analysisError {
                Label {
                    Text(error).foregroundStyle(.red)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Button("Prøv igjen", action: startAnalysis)
            } else {
                if transcriptionResult != nil {
                    Button {
                        startAnalysis()
                    } label: {
                        Label("Analyser med \(llmModel)", systemImage: "brain.head.profile")
                    }
                    .disabled(isTranscribing || isDiarizing || !ollamaIsInstalled)
                    HStack(spacing: 4) {
                        Image(systemName: ollamaIsInstalled
                              ? (ollamaIsRunning ? "circle.fill" : "circle.dotted")
                              : "xmark.circle")
                            .foregroundStyle(ollamaIsInstalled
                                             ? (ollamaIsRunning ? Color.green : Color.orange)
                                             : Color.red)
                            .font(.caption2)
                        Text(ollamaIsInstalled
                             ? (ollamaIsRunning ? "Ollama kjører" : "Ollama starter automatisk ved klikk")
                             : "Ollama er ikke installert — last ned fra ollama.com")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Transkriber lydfilen først")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Actions

    private func startTranscription() {
        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .medium
        let audioURL = URL(fileURLWithPath: recording.path)

        transcriptionTask?.cancel()
        transcriptionError = nil
        isTranscribing = true

        transcriptionTask = Task { @MainActor in
            do {
                let result = try await TranscriptionService.shared.transcribe(
                    audioFile: audioURL,
                    speakers: defaultSpeakers,
                    model: model,
                    verbatim: verbatim,
                    language: language
                )
                guard !Task.isCancelled else { return }
                transcriptionResult = result
                isTranscribing = false

                // Store in the in-memory cache so the result survives file navigation
                TranscriptionCache.shared.store(result, for: recording.path)
                // Save full TranscriptionResult JSON to disk (preserves speaker labels across restarts)
                TranscriptionService.shared.saveTranscriptJSONPublic(result, recordingId: recording.id)
                ProcessingStateCache.shared.setStep(.transcription, status: .completed, for: recording.path)

                // Persist plain-text transcript into the recording's UUID folder
                let plainText = result.segments
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n\n")

                let transcriptURL = StorageLayout.transcriptURL(id: recording.id)
                try? plainText.write(to: transcriptURL, atomically: true, encoding: .utf8)
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .done
                    meta.transcript.completedAt = Date()
                }
            } catch let error as TranscriptionError {
                guard !Task.isCancelled else { return }
                transcriptionError = error
                isTranscribing = false
            } catch {
                guard !Task.isCancelled else { return }
                transcriptionError = .processFailed(error.localizedDescription)
                isTranscribing = false
            }
        }
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        TranscriptionService.shared.cancel()
        isTranscribing = false
    }

    private func startDiarization() {
        guard let result = transcriptionResult else { return }
        isDiarizing = true
        diarizationError = nil
        diarizationTask = Task {
            do {
                let updated = try await TranscriptionService.shared.diarize(
                    audioFile: URL(fileURLWithPath: recording.path),
                    existingResult: result,
                    hfToken: hfToken,
                    speakers: defaultSpeakers
                )
                await MainActor.run {
                    transcriptionResult = updated
                    isDiarizing = false
                }
            } catch {
                await MainActor.run {
                    diarizationError = error.localizedDescription
                    isDiarizing = false
                }
            }
        }
    }

    private func startAnalysis() {
        guard let result = transcriptionResult else { return }
        isAnalyzing = true
        analysisError = nil
        analysisTask = Task {
            do {
                let analysis = try await TranscriptionService.shared.analyze(
                    audioFile: URL(fileURLWithPath: recording.path),
                    existingResult: result,
                    llmModel: llmModel
                )
                await MainActor.run {
                    analysisResult = analysis
                    isAnalyzing = false
                }
            } catch {
                await MainActor.run {
                    analysisError = error.localizedDescription
                    isAnalyzing = false
                }
            }
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Recordings list panel (second column when Lydopptak is active)
struct RecordingsSidebar: View {
    let recordings: [RecordingItem]
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    @ObservedObject var folderManager: FolderManager
    @ObservedObject var sdCardManager: SDCardManager
    @Binding var showImportSheet: Bool
    @Binding var selectedRecording: RecordingItem?

    var body: some View {
        VStack(spacing: 0) {
            // Folder Tree & Recordings List
            if recordings.isEmpty && folderManager.folderStructure.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("No recordings yet")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        // Show folders first
                        ForEach(folderManager.folderStructure) { folder in
                            FolderTreeView(
                                folderPath: folder.path,
                                audioPlayer: audioPlayer,
                                recordingsManager: recordingsManager,
                                folderManager: folderManager
                            )
                        }

                        // Show root-level recordings (not in folders)
                        let rootRecordings = recordings.filter { recording in
                            !folderManager.folderStructure.contains { folder in
                                folder.recordings.contains { $0.path == recording.path }
                            }
                        }

                        ForEach(rootRecordings) { recording in
                            RecordingRowView(
                                recording: recording,
                                isPlaying: audioPlayer.currentPlayingURL == URL(fileURLWithPath: recording.path) && audioPlayer.isPlaying,
                                audioPlayer: audioPlayer,
                                recordingsManager: recordingsManager,
                                isSelected: selectedRecording?.id == recording.id,
                                onSelect: { selectedRecording = recording }
                            )
                        }
                    }
                }
            }

            Divider()

            // Footer
            VStack(spacing: 0) {
                Text("Storage: \(folderManager.getTotalStorageUsed())")
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                SidebarMenuItem(
                    icon: "sdcard.fill",
                    title: "Import from SD Card",
                    action: { showImportSheet = true }
                )
            }
        }
        .onAppear {
            folderManager.loadFolderStructure()
        }
    }
}

// MARK: - Icon Button with Stable Hover
struct IconButton: View {
    let action: () -> Void
    let icon: String
    let color: Color

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: NSColor.controlColor))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(nsColor: NSColor.labelColor))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                DispatchQueue.main.async { NSCursor.pointingHand.set() }
            case .ended:
                DispatchQueue.main.async { NSCursor.arrow.set() }
            }
        }
    }
}

// MARK: - Recording Row View
struct RecordingRowView: View {
    let recording: RecordingItem
    let isPlaying: Bool
    @ObservedObject var audioPlayer: AudioPlayer
    @ObservedObject var recordingsManager: RecordingsManager
    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil
    @State private var showDeleteConfirm = false
    @State private var isHovering = false

    /// True when this recording has a transcription result — either in the session cache
    /// or as a saved transcript.txt in the recording's UUID folder.
    private var hasTranscription: Bool {
        if TranscriptionCache.shared.hasResult(for: recording.path) { return true }
        let txtURL = StorageLayout.transcriptURL(id: recording.id)
        return FileManager.default.fileExists(atPath: txtURL.path)
    }

    private var hasDiarization: Bool {
        ProcessingStateCache.shared.state(for: recording.path).diarization.status == .completed
    }

    private var hasAnalysis: Bool {
        ProcessingStateCache.shared.state(for: recording.path).analysis.status == .completed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "waveform" : "waveform.circle")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.filename)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(contentColor)

                    HStack(spacing: 4) {
                        Text(recording.formattedDate)
                        Text("·")
                        Text(recording.formattedDuration)
                    }
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(subtleColor)
                }

                Spacer()

                HStack(spacing: 4) {
                    if hasTranscription {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(Color(red: 200/255, green: 16/255, blue: 46/255).opacity(0.8))
                            .help("Transkribert")
                    }
                    if hasDiarization {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue.opacity(0.7))
                            .help("Talere identifisert")
                    }
                    if hasAnalysis {
                        Image(systemName: "brain.head.profile")
                            .font(.caption2)
                            .foregroundStyle(.purple.opacity(0.7))
                            .help("Analysert")
                    }
                }

                Text(recording.formattedSize)
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(subtleColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }

            Divider().background(Color.gray.opacity(0.25))
        }
        .onHover { isHovering = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active: DispatchQueue.main.async { NSCursor.pointingHand.set() }
            case .ended: DispatchQueue.main.async { NSCursor.arrow.set() }
            }
        }
        .alert("Slett opptak?", isPresented: $showDeleteConfirm) {
            Button("Avbryt", role: .cancel) {}
            Button("Slett", role: .destructive) {
                if isPlaying { audioPlayer.stop() }
                recordingsManager.deleteRecording(recording)
            }
        } message: {
            Text("Er du sikker på at du vil slette \(recording.filename)?")
        }
        .contextMenu {
            Button(action: {
                let url = URL(fileURLWithPath: recording.path)
                if isPlaying {
                    audioPlayer.togglePlayPause()
                } else {
                    audioPlayer.play(url: url)
                }
            }) {
                Label(isPlaying ? "Pause" : "Spill av", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }

            Divider()

            Button(action: {
                NSWorkspace.shared.selectFile(recording.path, inFileViewerRootedAtPath: "")
            }) {
                Label("Vis i Finder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive, action: { showDeleteConfirm = true }) {
                Label("Slett", systemImage: "trash")
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return AppColors.accent }
        if isHovering { return Color.gray.opacity(0.08) }
        return Color.clear
    }

    private var contentColor: Color { isSelected ? .white : .primary }
    private var subtleColor: Color { isSelected ? .white.opacity(0.75) : .secondary }
    private var iconColor: Color {
        if isSelected { return .white }
        return isPlaying ? AppColors.accent : AppColors.accent.opacity(0.7)
    }
}

// MARK: - Recording Name Dialog
struct RecordingNameDialog: View {
    @Binding var recordingName: String
    let duration: TimeInterval
    let onSave: () -> Void
    let onDiscard: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.accent)

                Text("Name Your Recording")
                    .font(.system(size: 18, weight: .semibold))

                Text("Duration: \(formatDuration(duration))")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // Filename input
            VStack(alignment: .leading, spacing: 6) {
                Text("Recording name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("e.g., Interview with participant", text: $recordingName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        onSave()
                    }

                Text("Timestamp will be added automatically")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.tertiary)
            }

            // Preview
            if !recordingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 6) {
                    Text("Preview:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(recordingName.trimmingCharacters(in: .whitespacesAndNewlines))_\(previewTimestamp()).m4a")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onDiscard) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                        Text("Discard")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: onSave) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                        Text("Save")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 400)
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func previewTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Silence Warning Dialog
struct SilenceWarningDialog: View {
    let onContinue: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppColors.warning)
                Text("Ingen lyd registrert")
                    .font(.system(size: 18, weight: .semibold))
                Text("Vi har ikke registrert stemmer eller lyd på en stund. Vil du pause eller stoppe opptaket?")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                Button(action: onContinue) {
                    Text("Fortsett opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(action: onPause) {
                    Text("Pause opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button(action: onStop) {
                    Text("Stopp opptak")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(28)
        .frame(width: 400)
    }
}

// MARK: - Recording View
struct RecordingView: View {
    @ObservedObject var recorder: AudioRecorder
    @StateObject private var recordingsManager = RecordingsManager.shared
    @StateObject private var audioPlayer = AudioPlayer.shared
    @Binding var isShowing: Bool
    @State private var microphoneVerified = false
    @State private var verificationTimer: Timer?
    @State private var recordingName = ""  // User-entered filename
    @State private var glowRadius: CGFloat = 10
    @State private var glowOpacity: Double = 0.2

    var body: some View {
        // Main recording area (sidebar is now global in MainView)
        mainRecordingView
            .sheet(isPresented: $recorder.showNamingDialog) {
                RecordingNameDialog(
                    recordingName: $recordingName,
                    duration: recorder.recordingDuration,
                    onSave: {
                        recorder.saveRecordingWithName(recordingName)
                        recordingName = ""  // Reset for next recording
                    },
                    onDiscard: {
                        recorder.cancelPendingRecording()
                        recordingName = ""
                    }
                )
            }
            .sheet(isPresented: $recorder.showSilenceWarning) {
                SilenceWarningDialog(
                    onContinue: {
                        recorder.dismissSilenceWarning()
                    },
                    onPause: {
                        recorder.showSilenceWarning = false
                        recorder.pauseRecording()
                    },
                    onStop: {
                        recorder.showSilenceWarning = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            recorder.stopRecording()
                        }
                    }
                )
            }
            .onAppear {
                recordingsManager.loadRecordings()
                // Start audio monitoring to show waveform visualization
                recorder.startMonitoring()
                // Reset verification status
                microphoneVerified = false

                // Auto-verify after timeout (fallback if no audio detected)
                verificationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) {
                    _ in
                    if !microphoneVerified {
                        microphoneVerified = true
                    }
                }
            }
            .onDisappear {
                // Stop monitoring when leaving the recording view
                recorder.stopMonitoring()
                // Stop playback if active
                audioPlayer.stop()
                // Cancel verification timer
                verificationTimer?.invalidate()
            }
            .onChange(of: recorder.showSaveConfirmation) { _, showing in
                if !showing {
                    // Reload recordings when save confirmation disappears
                    recordingsManager.loadRecordings()
                }
            }
            .onChange(of: recorder.frequencyBands) { _, bands in
                // Update glow state with a smooth animation so it plays through between frames
                // rather than restarting every 23 ms (which caused jitter with inline animation).
                let avg = bands.isEmpty ? 0 : bands.reduce(0, +) / Float(bands.count)
                let amplified = min(Double(avg) * 3.0, 1.0)
                withAnimation(.easeInOut(duration: 0.2)) {
                    glowRadius = CGFloat(amplified) * 30 + 10   // 10–40 pt
                    glowOpacity = amplified * 0.8 + 0.2          // 0.2–1.0
                }
                // Auto-verify when audio is detected
                if !microphoneVerified, avg > 0.15 {
                    microphoneVerified = true
                    verificationTimer?.invalidate()
                }
            }
    }

    var mainRecordingView: some View {
        VStack(spacing: 0) {
            // Recording Interface
            ZStack {
                // Main Content
                VStack(spacing: 40) {
                    Spacer()

                    // Save Confirmation
                    if recorder.showSaveConfirmation {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 64, weight: .ultraLight))
                                .foregroundStyle(.green)
                            Text("Recording Saved")
                                .font(.system(size: 24, weight: .light))
                            if let filename = recorder.lastSavedFile {
                                Text(filename)
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(48)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(2)
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        // Microphone Icon with pulsing glow
                        VStack(spacing: 24) {
                            Image(
                                systemName: recorder.isRecording && !recorder.isPaused
                                    ? "mic.fill" : "mic"
                            )
                            .font(.system(size: 72, weight: .ultraLight))
                            .foregroundStyle(
                                recorder.isRecording && !recorder.isPaused ? .red : .primary
                            )
                            .shadow(
                                color: (recorder.isRecording && !recorder.isPaused
                                    ? Color.red : Color.blue)
                                    .opacity(glowOpacity),
                                radius: glowRadius,
                                x: 0,
                                y: 0
                            )
                            .shadow(
                                color: (recorder.isRecording && !recorder.isPaused
                                    ? Color.red : Color.blue)
                                    .opacity(0.3),
                                radius: 15,
                                x: 0,
                                y: 0
                            )

                            // Recording Duration
                            if recorder.isRecording || recorder.recordingDuration > 0 {
                                Text(formatDuration(recorder.recordingDuration))
                                    .font(.system(size: 64, weight: .thin, design: .default))
                                    .foregroundStyle(recorder.isPaused ? .orange : .primary)
                                    .tracking(2)
                                    .monospacedDigit()
                            }

                            // Status Text - minimal
                            if recorder.isPaused {
                                Text("Paused")
                                    .font(.system(size: 14, weight: .light))
                                    .foregroundStyle(.orange)
                                    .textCase(.uppercase)
                                    .tracking(2)
                            } else if recorder.isRecording {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 6, height: 6)
                                    Text("Recording")
                                        .font(.system(size: 14, weight: .light))
                                        .foregroundStyle(.red)
                                        .textCase(.uppercase)
                                        .tracking(2)
                                }
                            }
                        }
                    }

                    Spacer()

                    // Scrolling Waveform Timeline - Only visible when recording
                    if recorder.isRecording {
                        ScrollingWaveformView(
                            waveformHistory: recorder.waveformHistory,
                            isRecording: recorder.isRecording
                        )
                        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }

                    // Control Buttons - Minimalist
                    if !recorder.showSaveConfirmation {
                        HStack(spacing: 32) {
                            // Delete Button (always show during recording)
                            if recorder.isRecording {
                                Button(action: {
                                    recorder.deleteCurrentRecording()
                                    isShowing = false
                                }) {
                                    VStack(spacing: 10) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 24, weight: .ultraLight))
                                            .foregroundStyle(.red.opacity(0.8))
                                            .frame(width: 56, height: 56)
                                            .background(Color.red.opacity(0.08))
                                            .cornerRadius(2)
                                        Text("Delete")
                                            .font(.system(size: 11, weight: .light))
                                            .foregroundStyle(.red.opacity(0.8))
                                            .textCase(.uppercase)
                                            .tracking(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            // Main Record/Stop Button
                            RecordButton(
                                isRecording: recorder.isRecording,
                                isVerified: microphoneVerified,
                                action: {
                                    if recorder.isRecording {
                                        recorder.stopRecording()
                                    } else {
                                        recorder.startRecording()
                                    }
                                }
                            )

                            // Pause/Resume Button (always show during recording)
                            if recorder.isRecording {
                                Button(action: {
                                    if recorder.isPaused {
                                        recorder.resumeRecording()
                                    } else {
                                        recorder.pauseRecording()
                                    }
                                }) {
                                    VStack(spacing: 10) {
                                        Image(systemName: recorder.isPaused ? "play" : "pause")
                                            .font(.system(size: 24, weight: .ultraLight))
                                            .foregroundStyle(.orange.opacity(0.8))
                                            .frame(width: 56, height: 56)
                                            .background(Color.orange.opacity(0.08))
                                            .cornerRadius(2)
                                        Text(recorder.isPaused ? "Resume" : "Pause")
                                            .font(.system(size: 11, weight: .light))
                                            .foregroundStyle(.orange.opacity(0.8))
                                            .textCase(.uppercase)
                                            .tracking(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 60)
                    }
                }
            }
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let milliseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }

}

// MARK: - Recording Player Panel (right panel for Lydopptak tab)

struct RecordingPlayerPanel: View {
    let recording: RecordingItem
    @ObservedObject var audioPlayer: AudioPlayer

    private var isCurrentFile: Bool {
        audioPlayer.currentPlayingURL == URL(fileURLWithPath: recording.path)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Spacer().frame(height: 20)

                // Icon
                Image(systemName: "waveform")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(isCurrentFile && audioPlayer.isPlaying ? AppColors.accent : .secondary.opacity(0.5))
                    .animation(.easeInOut(duration: 0.2), value: audioPlayer.isPlaying)

                // Play/pause button
                Button(action: {
                    let url = URL(fileURLWithPath: recording.path)
                    if isCurrentFile {
                        audioPlayer.togglePlayPause()
                    } else {
                        audioPlayer.play(url: url)
                    }
                }) {
                    Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72, weight: .thin))
                        .foregroundStyle(AppColors.accent)
                }
                .buttonStyle(.plain)

                // Progress bar (only when this recording is active)
                if isCurrentFile {
                    VStack(spacing: 6) {
                        ProgressView(value: audioPlayer.playbackProgress)
                            .tint(AppColors.accent)
                            .padding(.horizontal, 60)

                        HStack {
                            Text(formattedTime(audioPlayer.playbackProgress * audioPlayer.duration))
                            Spacer()
                            Text(recording.formattedDuration)
                        }
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 60)
                    }
                    .transition(.opacity)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(recording.filename)
        .navigationSubtitle("\(recording.formattedDate) · \(recording.formattedDuration) · \(recording.formattedSize)")
        .animation(.easeInOut(duration: 0.2), value: isCurrentFile)
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - About View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("About Audio Recording Manager")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Version
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Button(action: {
                            if let url = URL(string: "https://github.com/Fr35ch/audio-recording-manager/releases") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12))
                                Text("View Release Notes")
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(AppColors.accent)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }

                    Divider()

                    // Purpose
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Purpose")
                            .font(.headline)
                        Text(
                            "Secure audio recording management for researchers conducting audio recordings on dedicated zero-trust Mac computers."
                        )
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Key Features
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Key Features")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            FeatureRow(
                                icon: "shield.checkered",
                                text: "Automatic network isolation on launch")
                            FeatureRow(
                                icon: "mic.fill",
                                text: "Built-in voice recorder with waveform visualization")
                            FeatureRow(
                                icon: "sdcard.fill", text: "SD card auto-detection and import")
                            FeatureRow(
                                icon: "lock.shield", text: "Support for encrypted DS2 audio files")
                            FeatureRow(icon: "arrow.up.doc", text: "Secure file upload to Teams")
                        }
                    }

                    Divider()

                    // Security Information
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Security")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("• WiFi, Bluetooth, and AirDrop disabled on launch")
                            Text("• Network isolation maintained during recording")
                            Text("• Zero-trust environment design")
                            Text("• Dedicated machine requirement")
                            Text("• All file operations work offline")
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Usage Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick Start")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Record Audio")
                                .fontWeight(.semibold)
                            Text("   Click 'Record with Voice Recorder' to start")
                                .foregroundStyle(.secondary)

                            Text("2. Import from SD Card")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Insert SD card with DS2 files from Olympus DS-9500")
                                .foregroundStyle(.secondary)

                            Text("3. Transkriber")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Velg opptaket og klikk «Transkriber med NB-Whisper»")
                                .foregroundStyle(.secondary)

                            Text("4. Upload to Teams")
                                .fontWeight(.semibold)
                                .padding(.top, 4)
                            Text("   Enable network temporarily for secure upload")
                                .foregroundStyle(.secondary)
                        }
                        .font(.body)
                    }

                    Divider()

                    // Technologies
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Technologies")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Swift 6.1+ & SwiftUI")
                            Text("• DiskArbitration for SD card detection")
                            Text("• AVFoundation for audio recording")
                            Text("• DSS Player for encrypted DS2 files")
                            Text("• no-transcribe / NB-Whisper (Nasjonalbiblioteket)")
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Contact & Support
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Contact & Support")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("For issues, questions, or feature requests:")
                            Text("• Refer to SPEC.md for complete specifications")
                            Text("• Check BACKLOG.md for planned features")
                            Text("• Review CHANGELOG.md for recent updates")
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Credits
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Credits")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Developed for NAV (Norwegian Labour and Welfare Administration)")
                                .fontWeight(.semibold)
                            Text("• NAV Design System (Aksel)")
                            Text("• OM System / Olympus (DSS Player)")
                            Text("• Nasjonalbiblioteket (NB-Whisper via no-transcribe)")
                            Text("• National Library of Norway (NB-Whisper)")
                            Text("• OpenAI (Whisper ASR)")
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    // Footer
                    Text("Copyright © 2025. All rights reserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)
                }
                .padding()
            }
        }
        .frame(width: 600, height: 700)
    }
}

// Helper view for feature rows
struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(AppColors.accent)
                .frame(width: 20)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sidebar Panel
struct SidebarPanelContent: View {
    @Binding var showAbout: Bool
    @Binding var showSidebar: Bool
    let openURL: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Menu")
                .font(.title2)
                .fontWeight(.semibold)
                .padding()

            Divider()

            // Menu items
            VStack(alignment: .leading, spacing: 0) {
                SidebarMenuItem(
                    icon: "link",
                    title: "Brukerinnsikt på Navet",
                    action: {
                        openURL(
                            "https://navno.sharepoint.com/sites/intranett-utvikling/SitePages/Brukerinnsikt.aspx"
                        )
                    }
                )

                SidebarMenuItem(
                    icon: "link",
                    title: "Brukerinnsikt på Aksel",
                    action: {
                        openURL("https://aksel.nav.no/god-praksis/brukerinnsikt")
                    }
                )

                Divider()
                    .padding(.vertical, AppSpacing.sm)

                SidebarMenuItem(
                    icon: "info.circle",
                    title: "About Audio Recording Manager",
                    action: {
                        showSidebar = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showAbout = true
                        }
                    }
                )
            }

            Spacer()

            // Footer
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("Audio Recording Manager (ARM)")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(width: 315, alignment: .leading)
    }
}

// Helper view for sidebar menu items
struct SidebarMenuItem: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.accent)
                    .frame(width: 20)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill(.ultraThinMaterial)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}


// MARK: - Main View
struct MainView: View {
    @StateObject private var fileManager = AudioFileManager.shared
    @StateObject private var sdCardManager = SDCardManager.shared
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var recordingsManager = RecordingsManager.shared
    @StateObject private var audioPlayer = AudioPlayer.shared
    @StateObject private var folderManager: FolderManager = {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let lydfilerPath = homeDir.appendingPathComponent("Desktop/lydfiler").path
        return FolderManager(basePath: lydfilerPath)
    }()
    @State private var showSuccessMessage = false
    @State private var successMessage = ""
    @State private var showImportSheet = false
    @State private var showAbout = false
    @State private var showSidebar: Bool = true
    @State private var showNewFolderDialog = false
    @State private var newFolderName = ""
    @StateObject private var transcriptManager = TranscriptManager.shared
    @State private var selectedTab: AppTab = .record
    @State private var selectedRecording: RecordingItem? = nil
    @State private var selectedTranscript: TranscriptItem? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showAnonymizationDialog = false

    var body: some View {
        // Single 3-column NavigationSplitView (Mail.app pattern):
        //   Column 1 (sidebar): NavPanel — always visible
        //   Column 2 (content): tab-dependent list (recordings / transcripts / empty)
        //   Column 3 (detail):  tab-dependent detail (player / transcript / RecordingView)
        //
        // Selection works natively because columns 2 and 3 are real
        // NavigationSplitView columns. No nesting, no sidebar toggle
        // conflicts, correct rounded-corner chrome on all tabs.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Column 1: sidebar
            NavPanel(selectedTab: $selectedTab, showAbout: $showAbout)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } content: {
            // Column 2: tab-dependent list
            Group {
                switch selectedTab {
                case .record:
                    Color.clear
                case .recordings:
                    RecordingsListColumn(
                        recordingsManager: recordingsManager,
                        folderManager: folderManager,
                        audioPlayer: audioPlayer,
                        selectedRecording: $selectedRecording
                    )
                case .transcripts:
                    TranscriptsListColumn(
                        transcriptManager: transcriptManager,
                        selectedTranscript: $selectedTranscript
                    )
                }
            }
            .navigationSplitViewColumnWidth(
                min: selectedTab == .record ? 0 : 240,
                ideal: selectedTab == .record ? 0 : 280,
                max: selectedTab == .record ? 0 : 360
            )
        } detail: {
            // Column 3: tab-dependent detail
            switch selectedTab {
            case .record:
                RecordingView(recorder: audioRecorder, isShowing: .constant(true))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .recordings:
                if let recording = selectedRecording {
                    RecordingPlayerNative(
                        recording: recording,
                        audioPlayer: audioPlayer,
                        onNavigateToTranscript: { recordingId in
                            // Find the matching transcript and switch to editor
                            selectedTranscript = transcriptManager.transcripts.first {
                                $0.recordingId == recordingId
                            }
                            selectedTab = .transcripts
                        }
                    )
                    .id(recording.path)
                } else {
                    ContentUnavailableView(
                        "Velg et opptak",
                        systemImage: "waveform",
                        description: Text("Klikk på et lydopptak til venstre for å spille av.")
                    )
                }
            case .transcripts:
                if let transcript = selectedTranscript {
                    transcriptDetailOrEditor(for: transcript)
                        .id(transcript.id)
                } else {
                    ContentUnavailableView(
                        "Velg en transkripsjon",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Klikk på en fil til venstre for å vise innhold og kjøre anonymisering.")
                    )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: selectedTab) { _, newTab in
            if newTab != .recordings { selectedRecording = nil }
            if newTab != .transcripts { selectedTranscript = nil }
            withAnimation { columnVisibility = (newTab == .record) ? .doubleColumn : .all }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $showImportSheet) {
            SDCardImportView(sdCardManager: sdCardManager)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showNewFolderDialog) {
            NewFolderDialog(
                folderName: $newFolderName,
                onCreate: {
                    if !newFolderName.isEmpty {
                        folderManager.createFolder(name: newFolderName)
                        newFolderName = ""
                        showNewFolderDialog = false
                    }
                },
                onCancel: {
                    newFolderName = ""
                    showNewFolderDialog = false
                }
            )
            .presentationDetents([.height(250)])
        }
        .sheet(isPresented: $showAnonymizationDialog) {
            AnonymizationReminderDialog(
                onContinue: {
                    showAnonymizationDialog = false
                    uploadToTeams()
                },
                onCancel: {
                    showAnonymizationDialog = false
                }
            )
            .presentationDetents([.height(400)])
        }
        .onAppear {
            recordingsManager.loadRecordings()
            folderManager.loadFolderStructure()
        }
    }

    /// Shows the transcript editor if a TranscriptionResult JSON exists for
    /// this recording, otherwise falls back to the plain TranscriptDetailPanel.
    @ViewBuilder
    private func transcriptDetailOrEditor(for transcript: TranscriptItem) -> some View {
        let matching = matchingRecording(for: transcript)
        if let recId = transcript.recordingId,
           let result = loadTranscriptionResult(recordingId: recId) {
            let audioURL = StorageLayout.audioURL(id: recId)
            TranscriptEditorView(
                recordingId: recId,
                audioURL: audioURL,
                transcriptionResult: result,
                onShowLinkedRecording: {
                    selectedRecording = matching
                    selectedTab = .recordings
                }
            )
        } else {
            TranscriptDetailPanel(
                transcript: transcript,
                matchingRecording: matching,
                onSwitchToRecordings: {
                    selectedRecording = matching
                    selectedTab = .recordings
                }
            )
        }
    }

    private func loadTranscriptionResult(recordingId: UUID) -> TranscriptionResult? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jsonURL = support.appendingPathComponent("AudioRecordingManager/transcripts/\(recordingId.uuidString).json")
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(TranscriptionResult.self, from: data)
    }

    private func matchingRecording(for transcript: TranscriptItem) -> RecordingItem? {
        if let id = transcript.recordingId {
            return recordingsManager.recordings.first { $0.id == id }
        }
        return nil
    }

    var mainContentView: some View {
        VStack(spacing: 20) {
            // Header
            Text("Audio Recording Manager")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 10)

            // SD Card Detection Banner
            if sdCardManager.isSDCardInserted {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: "sdcard.fill")
                        .font(.title2)
                        .foregroundStyle(AppColors.success)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("SD CARD DETECTED")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppColors.success)
                        if let volumeName = sdCardManager.sdCardVolumeName {
                            Text("Volume: \(volumeName)")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                        if let path = sdCardManager.sdCardPath {
                            Text("Path: \(path)")
                                .font(.system(size: 10, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: AppSpacing.xs) {
                        Text("\(sdCardManager.audioFiles.count) audio files")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppColors.success)

                        Button(action: {
                            sdCardManager.ejectSDCard()
                        }) {
                            HStack(spacing: AppSpacing.xs) {
                                Image(systemName: "eject")
                                    .font(.system(size: 10))
                                Text("Eject")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.xs + 1)
                            .background(AppColors.success)
                            .foregroundStyle(.white)
                            .cornerRadius(AppRadius.medium)
                        }
                        .buttonStyle(.plain)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                DispatchQueue.main.async { NSCursor.pointingHand.set() }
                            case .ended:
                                DispatchQueue.main.async { NSCursor.arrow.set() }
                            }
                        }
                    }
                }
                .padding(AppSpacing.lg)
                .background {
                    RoundedRectangle(cornerRadius: AppRadius.large)
                        .fill(AppColors.success.opacity(0.1))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.large)
                        .stroke(AppColors.success, lineWidth: 2)
                )
            }

            Divider()
                .padding(.vertical, 10)

            // Success Message
            if showSuccessMessage {
                Text(successMessage)
                    .font(.title2)
                    .foregroundStyle(.green)
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
            }

            // Main Action Buttons
            VStack(spacing: AppSpacing.lg) {
                Button(action: {
                    launchVoiceRecorder()
                }) {
                    HStack(spacing: AppSpacing.md) {
                        Image(systemName: "mic.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                        Text("Record with Voice Recorder")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())

                Button(action: {
                    importFromSDCard()
                }) {
                    HStack(spacing: AppSpacing.md) {
                        Image(systemName: "sdcard.fill")
                            .font(.title)
                        Text("Import Audio from SD Card")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(.vertical, AppSpacing.xl)

            Divider()

            // Network Controls
            VStack(spacing: 15) {
                Button(action: {
                    uploadToTeams()
                }) {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "arrow.up.doc.fill")
                            .foregroundStyle(.white)
                        Text("Upload to Teams")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        DispatchQueue.main.async {
                            NSCursor.pointingHand.set()
                        }
                    case .ended:
                        DispatchQueue.main.async {
                            NSCursor.arrow.set()
                        }
                    }
                }

            }

            Spacer()

            // NAV Logo - Bottom Center
            if let resourcePath = Bundle.main.resourcePath {
                let logoName =
                    NSApp.effectiveAppearance.name == .darkAqua ? "nav-white.png" : "nav-grey.png"
                if let nsImage = NSImage(
                    contentsOfFile: (resourcePath as NSString).appendingPathComponent(logoName))
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 70, height: 21)
                        .opacity(0.7)
                        .padding(.bottom, 15)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 30)
        .padding(.bottom, 20)
    }

    // MARK: - Actions

    func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func launchVoiceRecorder() {
        // Recording view is now the default - this function kept for compatibility
        // Could be used to reset/focus the recording view if needed
    }

    func importFromSDCard() {
        // Launch DSS Player and show import sheet
        sdCardManager.launchDSSPlayer()
        showImportSheet = true
    }

    func uploadToTeams() {
        let workspace = NSWorkspace.shared

        // Launch Microsoft Teams
        if let teamsURL = workspace.urlForApplication(withBundleIdentifier: "com.microsoft.teams2")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.microsoft.teams")
        {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: teamsURL, configuration: configuration) { app, error in
                if let error = error {
                    print("Failed to launch Teams: \(error)")
                }
            }
        } else {
            print("Microsoft Teams not found")
        }

        // Open Finder to lydfiler folder
        let folderURL = URL(fileURLWithPath: fileManager.audioFolderPath)
        workspace.selectFile(nil, inFileViewerRootedAtPath: folderURL.path)

        // Also open OneDrive folder in a separate window
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let oneDrivePaths = [
            homeDir.appendingPathComponent("OneDrive").path,
            homeDir.appendingPathComponent("Library/CloudStorage/OneDrive-Personal").path,
            homeDir.appendingPathComponent("OneDrive - Personal").path,
        ]

        for path in oneDrivePaths {
            if FileManager.default.fileExists(atPath: path) {
                // Open OneDrive in new Finder window
                workspace.open(URL(fileURLWithPath: path))
                break
            }
        }

        // Show message
        showSuccess(
            message:
                "Network enabled. Teams launched. Upload your files, then click 'Disable Network' when done."
        )
    }

    func showSuccess(message: String) {
        successMessage = message
        showSuccessMessage = true

        // Hide message after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            showSuccessMessage = false
        }
    }
}

// MARK: - SD Card Import View
struct SDCardImportView: View {
    @ObservedObject var sdCardManager: SDCardManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFiles: Set<AudioFileInfo> = []
    @State private var isImporting = false
    @State private var importProgress = 0.0
    @State private var importedCount = 0
    @State private var importedFiles: [AudioFileInfo] = []
    @State private var showDeletePrompt = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Import Audio from SD Card")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            // SD Card Status
            if sdCardManager.isSDCardInserted {
                HStack {
                    Image(systemName: "sdcard.fill")
                        .foregroundStyle(.green)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("SD Card: \(sdCardManager.sdCardVolumeName ?? "Unknown")")
                            .font(.headline)
                        Text("\(sdCardManager.audioFiles.count) audio files found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if sdCardManager.isScanning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button(action: {
                            sdCardManager.ejectSDCard()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "eject")
                                Text("Eject")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                DispatchQueue.main.async { NSCursor.pointingHand.set() }
                            case .ended:
                                DispatchQueue.main.async { NSCursor.arrow.set() }
                            }
                        }
                    }
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                HStack {
                    Image(systemName: "sdcard")
                        .foregroundStyle(.orange)
                        .font(.title2)
                    Text("No SD Card detected. Please insert an Olympus SD card.")
                        .font(.headline)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if !sdCardManager.audioFiles.isEmpty {
                // Selection Controls
                HStack {
                    Button(
                        selectedFiles.count == sdCardManager.audioFiles.count
                            ? "Deselect All" : "Select All"
                    ) {
                        if selectedFiles.count == sdCardManager.audioFiles.count {
                            selectedFiles.removeAll()
                        } else {
                            selectedFiles = Set(sdCardManager.audioFiles)
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("\(selectedFiles.count) of \(sdCardManager.audioFiles.count) selected")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // File List
                List(sdCardManager.audioFiles, id: \.self, selection: $selectedFiles) { file in
                    FileRowView(file: file, isSelected: selectedFiles.contains(file))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedFiles.contains(file) {
                                selectedFiles.remove(file)
                            } else {
                                selectedFiles.insert(file)
                            }
                        }
                }
                .frame(maxHeight: 400)

                // Import Progress
                if isImporting {
                    VStack {
                        ProgressView(value: importProgress, total: Double(selectedFiles.count))
                        Text("Importing \(importedCount) of \(selectedFiles.count) files...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }

                // Import Button
                Button(action: {
                    importSelectedFiles()
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text(
                            "Import \(selectedFiles.count) File\(selectedFiles.count == 1 ? "" : "s")"
                        )
                        .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFiles.isEmpty || isImporting)
                .padding(.horizontal)
            }

            Spacer()
        }
        .frame(width: 700, height: 600)
    }

    func importSelectedFiles() {
        isImporting = true
        importedCount = 0
        importProgress = 0

        let filesToImport = Array(selectedFiles)
        let fileManager = FileManager.default
        let audioFolder = AudioFileManager.shared.audioFolderPath

        for file in filesToImport {
            // Use ORIGINAL filename, not a generated timestamp
            var destinationPath = (audioFolder as NSString).appendingPathComponent(file.name)

            // If file already exists, add a number suffix
            var counter = 1
            while fileManager.fileExists(atPath: destinationPath) {
                let nameWithoutExt = (file.name as NSString).deletingPathExtension
                let ext = (file.name as NSString).pathExtension
                let newName = "\(nameWithoutExt)_\(counter).\(ext)"
                destinationPath = (audioFolder as NSString).appendingPathComponent(newName)
                counter += 1
            }

            do {
                // Copy file with original name
                try fileManager.copyItem(atPath: file.path, toPath: destinationPath)
                let finalName = (destinationPath as NSString).lastPathComponent
                print("✅ Imported: \(file.name) → \(finalName)")

                importedCount += 1
                importProgress = Double(importedCount)
            } catch {
                print("❌ Failed to import \(file.name): \(error)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isImporting = false
            if importedCount > 0 {
                // Success! Show completion
                print("🎉 Imported \(importedCount) files successfully")
                dismiss()
            }
        }
    }
}

// MARK: - File Row View
struct FileRowView: View {
    let file: AudioFileInfo
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .gray)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.headline)
                HStack {
                    Text(file.formattedSize)
                    Text("•")
                    Text(file.formattedDate)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Entry Point
VirginProjectApp.main()
