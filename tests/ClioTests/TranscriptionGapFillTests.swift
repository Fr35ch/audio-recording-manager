import XCTest
@testable import Clio

/// Real, executed coverage for `TranscriptionService.detectTimelineGaps` and
/// `.remapRecoveredSegment` — the pure logic behind `repairTimelineGaps`
/// (the timeline gap-fill safety net for WhisperKit's own no-speech skip,
/// mirroring `no-transcribe`'s `_fill_gap` mechanism). These are the two
/// places an off-by-one or wrong-clamp would either miss a real gap or
/// misplace recovered speech, so they're tested directly rather than only
/// through the full (WhisperKit-dependent, untestable-here) async pipeline.
final class TranscriptionGapFillTests: XCTestCase {

    private func segment(_ start: Double, _ end: Double, text: String = "x") -> TranscriptionSegment {
        TranscriptionSegment(
            id: 0, start: start, end: end, text: text, speaker: "SPEAKER_0",
            confidence: 1.0, words: [], lowConfidence: nil)
    }

    // MARK: - detectTimelineGaps

    func testNoGapsWhenSegmentsCoverWholeDuration() {
        let segments = [segment(0, 10), segment(10, 20), segment(20, 30)]
        let gaps = TranscriptionService.detectTimelineGaps(
            segments: segments, durationSeconds: 30, gapThresholdSeconds: 5.0)
        XCTAssertTrue(gaps.isEmpty)
    }

    func testDetectsMidStreamGap() {
        // Reproduces the reported symptom: a real ~30s window silently
        // dropped by WhisperKit's noSpeechThreshold skip, surfacing as a
        // stretch with literally no segment at all.
        let segments = [segment(0, 10), segment(45, 50)]
        let gaps = TranscriptionService.detectTimelineGaps(
            segments: segments, durationSeconds: 50, gapThresholdSeconds: 5.0)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(gaps[0].end, 45, accuracy: 0.001)
    }

    func testDetectsGapBeforeFirstSegment() {
        // "The ENTIRE beginning is missing" — a gap before the first segment.
        let segments = [segment(40, 50)]
        let gaps = TranscriptionService.detectTimelineGaps(
            segments: segments, durationSeconds: 50, gapThresholdSeconds: 5.0)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(gaps[0].end, 40, accuracy: 0.001)
    }

    func testDetectsGapAfterLastSegment() {
        let segments = [segment(0, 10)]
        let gaps = TranscriptionService.detectTimelineGaps(
            segments: segments, durationSeconds: 50, gapThresholdSeconds: 5.0)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(gaps[0].end, 50, accuracy: 0.001)
    }

    func testDetectsNoGapWhenNoSegmentsAtAll() {
        // Whole file silently skipped: no crash, and the entire duration is
        // reported as a single gap so it still gets a repair attempt.
        let gaps = TranscriptionService.detectTimelineGaps(
            segments: [], durationSeconds: 50, gapThresholdSeconds: 5.0)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(gaps[0].end, 50, accuracy: 0.001)
    }

    func testGapSmallerThanThresholdIsIgnored() {
        let segments = [segment(0, 10), segment(13, 20)]  // 3s gap, below 5s threshold
        let gaps = TranscriptionService.detectTimelineGaps(
            segments: segments, durationSeconds: 20, gapThresholdSeconds: 5.0)
        XCTAssertTrue(gaps.isEmpty)
    }

    func testOverlappingSegmentsDoNotProduceNegativeGap() {
        // Segments sorted by start but with end times that overlap the next
        // segment's start shouldn't cause the cursor to move backward.
        let segments = [segment(0, 20), segment(10, 15)]
        let gaps = TranscriptionService.detectTimelineGaps(
            segments: segments, durationSeconds: 20, gapThresholdSeconds: 5.0)
        XCTAssertTrue(gaps.isEmpty)
    }

    func testUnsortedInputIsHandledCorrectly() {
        let segments = [segment(45, 50), segment(0, 10)]  // out of order
        let gaps = TranscriptionService.detectTimelineGaps(
            segments: segments, durationSeconds: 50, gapThresholdSeconds: 5.0)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(gaps[0].end, 45, accuracy: 0.001)
    }

    // MARK: - remapRecoveredSegment

    func testRemapShiftsSubclipRelativeTimestampsToAbsolute() {
        // Gap is 10..45, subclip padding 2.0 -> subclip covers [8, 47].
        // A word at [3, 5] relative to the subclip is [11, 13] absolute.
        let range = TranscriptionService.remapRecoveredSegment(
            relativeStart: 3, relativeEnd: 5,
            gap: (start: 10, end: 45), subclipPadding: 2.0)
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.start, 11, accuracy: 0.001)
        XCTAssertEqual(range!.end, 13, accuracy: 0.001)
    }

    func testRemapClampsToGapBounds() {
        // Recovered speech starting in the leading context padding (before
        // the gap actually starts) should be clamped to the gap's own start,
        // not bleed into territory the neighboring segment already covers.
        let range = TranscriptionService.remapRecoveredSegment(
            relativeStart: 0, relativeEnd: 4,  // absolute [8, 12]
            gap: (start: 10, end: 45), subclipPadding: 2.0)
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.start, 10, accuracy: 0.001)  // clamped up to gap.start
        XCTAssertEqual(range!.end, 12, accuracy: 0.001)
    }

    func testRemapRejectsSpanEntirelyOutsideGap() {
        // Recovered speech that's entirely within the leading context
        // padding (never reaches the actual gap) must be discarded, not
        // clamped into a zero/negative-length segment at the gap boundary.
        let range = TranscriptionService.remapRecoveredSegment(
            relativeStart: 0, relativeEnd: 1,  // absolute [8, 9], gap starts at 10
            gap: (start: 10, end: 45), subclipPadding: 2.0)
        XCTAssertNil(range)
    }

    func testRemapClampsAtGapStartWhenPaddingWouldGoNegative() {
        // Gap starting at 0.5 with 2.0s padding would clamp to 0, not -1.5.
        let range = TranscriptionService.remapRecoveredSegment(
            relativeStart: 0, relativeEnd: 1,
            gap: (start: 0.5, end: 10), subclipPadding: 2.0)
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.start, 0.5, accuracy: 0.001)  // clamped to gap.start
        XCTAssertEqual(range!.end, 1, accuracy: 0.001)
    }

    // MARK: - detectTrailingGap
    //
    // Confirmed by reading `TranscribeTask.run`'s own seek loop directly:
    // `while seek < seekClipEnd - windowPadding`, where `windowPadding`
    // defaults to `options.windowClipTime` (1.0s) worth of samples —
    // WhisperKit deliberately never attempts to decode the last ~1 second
    // of ANY clip, on every single transcription. This is real and
    // guaranteed, but far too small to ever trigger `detectTimelineGaps`'s
    // 5-second default threshold, so it needs its own dedicated check.

    func testDetectsRealWhisperKitTailSkip() {
        // The actual failure shape: a 101s file whose last real segment
        // ends at 100s, leaving WhisperKit's own deterministic ~1s tail
        // never even attempted.
        let gap = TranscriptionService.detectTrailingGap(
            segments: [segment(0, 100.0)], durationSeconds: 101.0)
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap?.start, 100.0, accuracy: 0.001)
        XCTAssertEqual(gap?.end, 101.0, accuracy: 0.001)
    }

    func testNoTrailingGapWhenSegmentsCoverExactlyToDuration() {
        let gap = TranscriptionService.detectTrailingGap(
            segments: [segment(0, 101.0)], durationSeconds: 101.0)
        XCTAssertNil(gap)
    }

    func testSubThresholdTrailingGapIsIgnored() {
        // 0.1s remaining — below the 0.3s default minimum, not worth a
        // repair attempt (subclip extraction/decode overhead isn't free).
        let gap = TranscriptionService.detectTrailingGap(
            segments: [segment(0, 100.9)], durationSeconds: 101.0)
        XCTAssertNil(gap)
    }

    func testDetectsTrailingGapWhenNoSegmentsAtAll() {
        let gap = TranscriptionService.detectTrailingGap(
            segments: [], durationSeconds: 101.0)
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap?.start, 0, accuracy: 0.001)
        XCTAssertEqual(gap?.end, 101.0, accuracy: 0.001)
    }

    func testTrailingGapUsesTrueLastEndRegardlessOfSegmentOrder() {
        let gap = TranscriptionService.detectTrailingGap(
            segments: [segment(50, 60), segment(0, 100.0)], durationSeconds: 101.0)
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap?.start, 100.0, accuracy: 0.001)
    }
}
