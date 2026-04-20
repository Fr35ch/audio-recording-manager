// AudioLevelVisualization.swift
// AudioRecordingManager
//
// Waveform timeline view shown during recording.
//
// Architecture note
// -----------------
// All visualization data flows from a single source: the `AVAudioRecorder`
// metering timer in `AudioRecorder.startLevelMonitoring()`, which fires at 20 Hz
// during both the pre-recording monitoring phase and active recording. This keeps
// the display reliable regardless of whether `AVAudioEngine` is running alongside
// the recorder. See `AudioRecorder` for the data model.

import SwiftUI

// MARK: - WaveformEntry

/// A single amplitude sample in the waveform timeline.
///
/// Each sample carries a stable monotonically-increasing `id` that lets SwiftUI's
/// `ForEach` match bars correctly as the ring buffer scrolls. Without stable
/// identifiers, evicting the oldest entry shifts all array offsets by one and
/// causes every visible bar to flash on each update.
struct WaveformEntry: Identifiable {
    /// Monotonically-increasing counter assigned at sample time by `AudioRecorder`.
    let id: UInt64
    /// Normalized amplitude in the range 0–1, smoothed with an exponential moving average.
    let level: Float
}

// MARK: - ScrollingWaveformView

/// A horizontally-scrolling bar chart displaying recent audio amplitude history.
///
/// ## Layout
/// Bars are drawn right-anchored using `Canvas`, so the newest sample is always
/// flush with the trailing edge. As new samples arrive, old ones scroll off to the
/// left. When the history is shorter than the view width the bars simply grow
/// inward from the right — no placeholder elements needed.
///
/// Bars are centered vertically so even silent samples (level ≈ 0) are visible
/// as a thin line, making the timeline readable at all amplitude levels.
///
/// Using `Canvas` instead of a `HStack`+`GeometryReader` approach avoids the
/// zero-size first-render quirk of `GeometryReader` and gives sub-pixel-accurate
/// bar placement at all view widths.
///
/// ## Usage
/// ```swift
/// ScrollingWaveformView(
///     waveformHistory: recorder.waveformHistory,
///     isRecording: recorder.isRecording
/// )
/// .frame(height: 80)
/// ```
struct ScrollingWaveformView: View {

    /// Amplitude history to display, ordered oldest-first.
    /// Populated by `AudioRecorder` at 20 Hz; capped at 1000 entries (~50 s)
    /// so even wide windows (up to ~4000 pt) can be filled with bars.
    let waveformHistory: [WaveformEntry]

    /// Whether recording is currently active. Reserved for future tint/style changes.
    let isRecording: Bool

    var body: some View {
        Canvas { ctx, size in
            let barWidth:   CGFloat = 3
            let barSpacing: CGFloat = 1
            let stride      = barWidth + barSpacing
            let visibleBars = Int(size.width / stride)

            let visible = waveformHistory.suffix(visibleBars)
            let count   = visible.count

            // Right-anchor: position bar[0] (oldest) so bar[count-1] (newest)
            // is flush with the trailing edge. When count < visibleBars the
            // leading space is naturally empty — no Spacer or placeholder needed.
            let startX = size.width - CGFloat(count) * stride

            for (i, entry) in visible.enumerated() {
                let barHeight = max(6, CGFloat(entry.level) * size.height * 0.85)
                let x = startX + CGFloat(i) * stride
                let y = (size.height - barHeight) / 2   // center-aligned vertically

                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: 1.5)

                // Recent bars (last 10) rendered at full opacity for a "live" look.
                let isRecent = i > count - 10
                let opacity  = Double(max(0.35, min(0.9, entry.level + 0.35)))
                ctx.fill(path, with: .color(.gray.opacity(isRecent ? opacity : opacity * 0.75)))
            }
        }
    }
}
