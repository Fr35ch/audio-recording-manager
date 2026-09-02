import XCTest
@testable import Clio

/// Real, executed coverage for `StereoSplitter.isLikelyMergedChannels` —
/// detects a real, field-discovered hardware misconfiguration (RØDE
/// capture app set to "merge" instead of "split" channel mode) rather than
/// a Clio-side bug. Getting this threshold wrong in either direction is
/// costly: too sensitive and genuine quiet-mic recordings get wrongly
/// treated as merged (silently disabling diarization that would have
/// worked); too lax and merged recordings keep going through the full,
/// pointless double-transcription + dedup pipeline this was built to skip.
final class StereoSplitterMergedChannelsTests: XCTestCase {

    private func energy(left: [Float], right: [Float], floorRMS: Float = 0.00316) -> StereoSplitter.ChannelEnergy {
        StereoSplitter.ChannelEnergy(
            windowSeconds: 0.05, left: left, right: right, floorRMS: floorRMS)
    }

    func testIdenticalChannelsAreDetectedAsMerged() {
        // The exact signature of a RØDE "merge" capture: both channels
        // carry the literal same summed signal.
        let signal: [Float] = (0..<100).map { Float($0 % 10) * 0.05 + 0.01 }
        let e = energy(left: signal, right: signal)
        XCTAssertTrue(StereoSplitter.isLikelyMergedChannels(e))
    }

    func testNearIdenticalChannelsWithEncodingNoiseAreDetectedAsMerged() {
        // Real merged captures aren't bit-exact after AAC re-encoding —
        // allow for small (~2%) per-window jitter and still detect it.
        var left: [Float] = []
        var right: [Float] = []
        for i in 0..<100 {
            let base = Float(0.05 + Double(i % 10) * 0.01)
            left.append(base)
            right.append(base * 1.02)
        }
        let e = energy(left: left, right: right)
        XCTAssertTrue(StereoSplitter.isLikelyMergedChannels(e))
    }

    func testGenuineDualMicSeparationIsNotFlaggedAsMerged() {
        // Reproduces the ~18 dB separation the original cross-talk gating
        // design measured on a real recording when one person speaks
        // (quieter channel at roughly 1/8th the louder channel's RMS).
        // Alternates which channel is "speaking" like a real conversation.
        var left: [Float] = []
        var right: [Float] = []
        for i in 0..<100 {
            if i % 20 < 10 {
                left.append(0.2); right.append(0.2 / 8)
            } else {
                left.append(0.2 / 8); right.append(0.2)
            }
        }
        let e = energy(left: left, right: right)
        XCTAssertFalse(StereoSplitter.isLikelyMergedChannels(e))
    }

    func testMostlySilentRecordingIsNotJudgedEitherWay() {
        // Only a couple of windows have real signal — not enough evidence
        // to conclude anything, must not default to "merged" just because
        // the few active windows happen to look similar by chance.
        var left = Array(repeating: Float(0.0001), count: 100)
        var right = Array(repeating: Float(0.0001), count: 100)
        left[0] = 0.05; right[0] = 0.05
        left[1] = 0.05; right[1] = 0.05
        let e = energy(left: left, right: right)
        XCTAssertFalse(StereoSplitter.isLikelyMergedChannels(e))
    }

    func testCompletelySilentRecordingIsNotFlaggedAsMerged() {
        let e = energy(
            left: Array(repeating: Float(0.0001), count: 100),
            right: Array(repeating: Float(0.0001), count: 100))
        XCTAssertFalse(StereoSplitter.isLikelyMergedChannels(e))
    }

    func testMixedRecordingWithMostlyGenuineSeparationButFewCoincidentalMatchesIsNotFlagged() {
        // Guards against a single coincidental near-equal window (e.g. a
        // brief moment both mics happen to pick up at similar volume)
        // flipping the verdict — the median across all active windows
        // should still reflect genuine separation.
        var left: [Float] = []
        var right: [Float] = []
        for i in 0..<100 {
            if i == 50 {
                left.append(0.1); right.append(0.1)  // one coincidental match
            } else if i % 20 < 10 {
                left.append(0.2); right.append(0.2 / 8)
            } else {
                left.append(0.2 / 8); right.append(0.2)
            }
        }
        let e = energy(left: left, right: right)
        XCTAssertFalse(StereoSplitter.isLikelyMergedChannels(e))
    }
}
