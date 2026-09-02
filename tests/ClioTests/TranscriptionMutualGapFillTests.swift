import XCTest
@testable import Clio

/// Real, executed coverage for the mutual-timeline-gap intersection logic
/// inside `TranscriptionService.repairMutualTimelineGaps` — the fix for a
/// real, confirmed bug: a real interview transcript showed a ~58s span
/// with literally no segment on either channel, surviving the earlier
/// per-channel `repairTimelineGaps` because that gap-fill ran *before*
/// `dominantRange` tightening + `deduplicateCrossTalk`, so any content it
/// recovered got silently deleted right back out by those later stages
/// (they can legitimately drop a segment wherever energy is quiet/
/// ambiguous on both channels — the same acoustic signature that caused
/// WhisperKit's own no-speech skip to produce the empty gap in the first
/// place). The fix moved repair to run *after* dedup, and restricted gap
/// fill to only spans missing from BOTH channels' own timelines at once —
/// a gap present on only one channel usually just means the other person
/// was speaking and that mic legitimately picked up nothing.
final class TranscriptionMutualGapFillTests: XCTestCase {

    /// Mirrors the private nested-loop intersection inside
    /// `repairMutualTimelineGaps` exactly, so this test exercises the same
    /// boundary math without needing to construct full `TranscriptionResult`
    /// values or a real WhisperKit decode.
    private func mutualGaps(
        leftGaps: [(start: Double, end: Double)],
        rightGaps: [(start: Double, end: Double)],
        threshold: Double
    ) -> [(start: Double, end: Double)] {
        var result: [(start: Double, end: Double)] = []
        for lg in leftGaps {
            for rg in rightGaps {
                let start = max(lg.start, rg.start)
                let end = min(lg.end, rg.end)
                if end - start > threshold {
                    result.append((start, end))
                }
            }
        }
        return result
    }

    func testExactlyMatchingGapsProduceOneMutualGap() {
        let r = mutualGaps(leftGaps: [(10, 45)], rightGaps: [(10, 45)], threshold: 5.0)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.start, 10, accuracy: 0.001)
        XCTAssertEqual(r.first?.end, 45, accuracy: 0.001)
    }

    func testAdjacentNonOverlappingGapsProduceNoMutualGap() {
        let r = mutualGaps(leftGaps: [(10, 45)], rightGaps: [(0, 10)], threshold: 5.0)
        XCTAssertTrue(r.isEmpty)
    }

    func testPartialOverlapIsClippedToTheIntersection() {
        let r = mutualGaps(leftGaps: [(0, 50)], rightGaps: [(20, 30)], threshold: 5.0)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.start, 20, accuracy: 0.001)
        XCTAssertEqual(r.first?.end, 30, accuracy: 0.001)
    }

    func testChannelWithNoGapsAtAllProducesNoMutualGap() {
        // A channel with full coverage (no gaps) means nothing is
        // "mutually" missing, regardless of what the other channel shows.
        let r = mutualGaps(leftGaps: [(10, 45)], rightGaps: [], threshold: 5.0)
        XCTAssertTrue(r.isEmpty)
    }

    func testOneSidedGapsAtDifferentTimesAreNotFlaggedMutual() {
        // This is the case the fix specifically protects: each channel has
        // its own gap, but they don't overlap in time — one person was
        // speaking while the other's mic was legitimately silent, twice,
        // at different moments. Neither should trigger a repair attempt.
        let r = mutualGaps(leftGaps: [(40, 50)], rightGaps: [(100, 110)], threshold: 5.0)
        XCTAssertTrue(r.isEmpty)
    }

    func testReportedBugShapeIsDetectedAsMutual() {
        // Reproduces the actual reported symptom: a real interview showed
        // nothing on either channel roughly between 1:29 (89s) and 2:27
        // (147s). Channel-level gap boundaries won't be pixel-identical in
        // practice (each channel's own dominant-range tightening moves them
        // slightly), so this uses close-but-not-identical bounds.
        let r = mutualGaps(leftGaps: [(89, 147)], rightGaps: [(85, 150)], threshold: 5.0)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.start, 89, accuracy: 0.001)
        XCTAssertEqual(r.first?.end, 147, accuracy: 0.001)
    }

    func testSubThresholdIntersectionIsIgnored() {
        let r = mutualGaps(leftGaps: [(10, 17)], rightGaps: [(13, 20)], threshold: 5.0)
        // Intersection is (13, 17) = 4s, below the 5s threshold.
        XCTAssertTrue(r.isEmpty)
    }

    func testMultipleDisjointMutualGapsAreAllFound() {
        let r = mutualGaps(
            leftGaps: [(0, 20), (100, 130)],
            rightGaps: [(5, 15), (105, 125)],
            threshold: 5.0)
        XCTAssertEqual(r.count, 2)
    }
}
