import Accelerate
import AVFoundation
import Foundation

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
    /// Temp mono downmix backing the current playback, if the source was
    /// stereo. Deleted when playback stops or a new file is played.
    private var monoTempURL: URL?

    private override init() {
        super.init()
    }

    func play(url: URL) {
        // Stop current playback if any
        stop()

        // Dual-channel RØDE recordings have the interviewer on the left mic and
        // the informant on the right, so on headphones each speaker is panned
        // hard to one ear. Downmix to mono for playback so both speakers are
        // centered. The original stereo file on disk is left untouched (the
        // channel separation is still needed for transcription).
        let playbackURL: URL
        if let mono = try? Self.monoDownmix(of: url) {
            monoTempURL = mono
            playbackURL = mono
        } else {
            playbackURL = url
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: playbackURL)
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
        clearMonoTemp()
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
        clearMonoTemp()
    }

    // MARK: - Mono downmix

    private func clearMonoTemp() {
        if let url = monoTempURL {
            try? FileManager.default.removeItem(at: url)
            monoTempURL = nil
        }
    }

    /// Produces a temporary mono `.m4a` by averaging the channels of `source`.
    /// Returns `nil` for already-mono sources (play the original directly).
    ///
    /// Averaging (rather than summing) keeps the level consistent and avoids
    /// clipping. The temp file lives in the system temp directory and is
    /// removed by `clearMonoTemp()` when playback ends.
    static func monoDownmix(of source: URL) throws -> URL? {
        let inputFile = try AVAudioFile(forReading: source)
        let format = inputFile.processingFormat
        guard format.channelCount > 1 else { return nil }

        let sampleRate = format.sampleRate
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio_mono_\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey:   256_000,
        ]
        guard let monoPCMFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        var outFile: AVAudioFile? = try AVAudioFile(forWriting: outURL, settings: settings)
        let frameCapacity: AVAudioFrameCount = 16_384

        while inputFile.framePosition < inputFile.length {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { break }
            try inputFile.read(into: inBuf)
            let frames = inBuf.frameLength
            if frames == 0 { break }
            guard let chans = inBuf.floatChannelData,
                  let outBuf = AVAudioPCMBuffer(pcmFormat: monoPCMFormat, frameCapacity: frames) else { break }
            outBuf.frameLength = frames
            let dst = outBuf.floatChannelData![0]
            let n = vDSP_Length(frames)
            // dst = mean of all source channels (avoids clipping vs. summing).
            let channelCount = Int(format.channelCount)
            memcpy(dst, chans[0], Int(frames) * MemoryLayout<Float>.size)
            for c in 1..<channelCount {
                vDSP_vadd(dst, 1, chans[c], 1, dst, 1, n)
            }
            var scale = 1.0 / Float(channelCount)
            vDSP_vsmul(dst, 1, &scale, dst, 1, n)
            try outFile?.write(from: outBuf)
        }

        // Release writer so AVAudioFile finalizes the container (moov atom).
        outFile = nil
        return outURL
    }
}
