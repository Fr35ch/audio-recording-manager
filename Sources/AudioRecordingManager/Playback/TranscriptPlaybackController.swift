// TranscriptPlaybackController.swift
// AudioRecordingManager
//
// AVAudioPlayer wrapper for transcript editor playback. Publishes
// `currentTime` at 20 Hz for karaoke-style word highlighting.
//
// Supports two playback modes:
//   - `.continuous` — normal play-through (toolbar play button, scrubber)
//   - `.segment(end:)` — play until a boundary then auto-pause (word/timestamp clicks)

import AVFoundation
import Foundation

enum PlaybackMode: Equatable {
    case continuous
    case segment(end: Double)
}

final class TranscriptPlaybackController: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var isPlaying: Bool = false
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var playbackMode: PlaybackMode = .continuous

    static let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(audioURL: URL) {
        do {
            let p = try AVAudioPlayer(contentsOf: audioURL)
            p.enableRate = true
            p.prepareToPlay()
            player = p
            duration = p.duration
        } catch {
            print("⚠️ TranscriptPlaybackController: could not load \(audioURL.lastPathComponent): \(error)")
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Controls

    /// Continuous playback from the current position. Resets playback mode
    /// to `.continuous` so a previous segment boundary doesn't re-trigger.
    func play() {
        guard let player else { return }
        playbackMode = .continuous
        player.rate = playbackRate
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        syncTime()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    /// Move the playhead without changing playback mode. Used by the scrubber.
    func seek(to time: Double) {
        let clamped = max(0, min(time, duration))
        player?.currentTime = clamped
        currentTime = clamped
        if isPlaying {
            player?.play()
        }
    }

    /// Play from `start` to `end`, then auto-pause. Used by word and
    /// timestamp clicks. If called while already playing a segment,
    /// replaces the window rather than stacking.
    func playSegment(from start: Double, to end: Double) {
        guard let player else { return }
        let clampedStart = max(0, min(start, duration))
        let clampedEnd = max(clampedStart, min(end, duration))
        player.currentTime = clampedStart
        currentTime = clampedStart
        playbackMode = .segment(end: clampedEnd)
        player.rate = playbackRate
        player.play()
        isPlaying = true
        startTimer()
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.syncTime()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func syncTime() {
        guard let player else { return }
        currentTime = player.currentTime

        // Auto-pause at segment boundary
        if case .segment(let end) = playbackMode, currentTime >= end {
            player.pause()
            isPlaying = false
            playbackMode = .continuous
            stopTimer()
            return
        }

        // Detect natural end of audio
        if !player.isPlaying && isPlaying {
            isPlaying = false
            playbackMode = .continuous
            stopTimer()
        }
    }
}
