import XCTest
@testable import Clio

final class StereoSplitterDedupTests: XCTestCase {

    private func segment(
        id: Int, start: Double, end: Double, text: String, speaker: String = "SPEAKER"
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            id: id, start: start, end: end, text: text, speaker: speaker,
            confidence: 1.0, words: [])
    }

    /// Builds a `ChannelEnergy` with a uniform RMS value per channel
    /// across `windowCount` windows of `windowSeconds` each — enough
    /// control to make one channel unambiguously "louder" than the other
    /// over a given time range.
    private func energy(
        windowSeconds: Double = 0.5, windowCount: Int, leftRMS: Float, rightRMS: Float
    ) -> StereoSplitter.ChannelEnergy {
        StereoSplitter.ChannelEnergy(
            windowSeconds: windowSeconds,
            left: Array(repeating: leftRMS, count: windowCount),
            right: Array(repeating: rightRMS, count: windowCount))
    }

    // MARK: - No overlap

    func testNonOverlappingSegmentsAreBothKept() {
        let left = [segment(id: 0, start: 0, end: 5, text: "Venstre linje")]
        let right = [segment(id: 0, start: 10, end: 15, text: "Høyre linje")]
        let e = energy(windowCount: 40, leftRMS: 0.1, rightRMS: 0.1)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertEqual(result.left.count, 1)
        XCTAssertEqual(result.right.count, 1)
    }

    func testEmptyChannelsReturnUnchanged() {
        let left = [segment(id: 0, start: 0, end: 5, text: "Noe")]
        let e = energy(windowCount: 10, leftRMS: 0.1, rightRMS: 0.1)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: [], energy: e)

        XCTAssertEqual(result.left.count, 1)
        XCTAssertTrue(result.right.isEmpty)
    }

    // MARK: - Energy-based duplicate resolution

    func testOverlappingDuplicateKeepsLouderRightChannel() {
        // Same utterance duplicated on both channels — right mic was closer
        // (much higher RMS) so it should win; left should be dropped.
        let left = [segment(id: 0, start: 10.0, end: 12.0, text: "Bare sånn før du får forsvinne")]
        let right = [segment(id: 0, start: 10.0, end: 12.0, text: "Men bare sånn før du får forsvinne")]
        // windowSeconds=0.5 → windows 20-24 cover [10.0, 12.0).
        var windows = Array(repeating: Float(0.01), count: 30)
        for w in 20..<24 { windows[w] = 0.01 }
        var rightWindows = windows
        for w in 20..<24 { rightWindows[w] = 0.5 }  // right much louder in the overlap
        let e = StereoSplitter.ChannelEnergy(windowSeconds: 0.5, left: windows, right: rightWindows)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertTrue(result.left.isEmpty, "louder right channel should win; left duplicate dropped")
        XCTAssertEqual(result.right.count, 1)
    }

    func testOverlappingDuplicateKeepsLouderLeftChannel() {
        let left = [segment(id: 0, start: 10.0, end: 12.0, text: "Interviewer line")]
        let right = [segment(id: 0, start: 10.0, end: 12.0, text: "Interviewer line (bleed)")]
        var leftWindows = Array(repeating: Float(0.01), count: 30)
        for w in 20..<24 { leftWindows[w] = 0.5 }  // left much louder
        let rightWindows = Array(repeating: Float(0.01), count: 30)
        let e = StereoSplitter.ChannelEnergy(windowSeconds: 0.5, left: leftWindows, right: rightWindows)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertEqual(result.left.count, 1)
        XCTAssertTrue(result.right.isEmpty)
    }

    func testTiedEnergyKeepsLeftSegment() {
        let left = [segment(id: 0, start: 10.0, end: 12.0, text: "Left version")]
        let right = [segment(id: 0, start: 10.0, end: 12.0, text: "Right version")]
        let e = energy(windowSeconds: 0.5, windowCount: 30, leftRMS: 0.2, rightRMS: 0.2)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertEqual(result.left.count, 1, "ties should keep left, matching the merge step's convention")
        XCTAssertTrue(result.right.isEmpty)
    }

    // MARK: - Placeholder preference

    func testRealTextAlwaysBeatsUnclearPlaceholderRegardlessOfEnergy() {
        let left = [segment(id: 0, start: 10.0, end: 12.0, text: NativeTranscriptionEngine.unclearAudioPlaceholder)]
        let right = [segment(id: 0, start: 10.0, end: 12.0, text: "Faktisk hørbar tekst her")]
        // Left is louder in raw energy, but should still lose because its
        // text is a hallucinated placeholder and the other channel has
        // real content for the same moment.
        var leftWindows = Array(repeating: Float(0.01), count: 30)
        for w in 20..<24 { leftWindows[w] = 0.9 }
        let rightWindows = Array(repeating: Float(0.01), count: 30)
        let e = StereoSplitter.ChannelEnergy(windowSeconds: 0.5, left: leftWindows, right: rightWindows)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertTrue(result.left.isEmpty)
        XCTAssertEqual(result.right.first?.text, "Faktisk hørbar tekst her")
    }

    func testUnclearPlaceholderOnRightLosesToRealLeftText() {
        let left = [segment(id: 0, start: 10.0, end: 12.0, text: "Ekte tekst")]
        let right = [segment(id: 0, start: 10.0, end: 12.0, text: NativeTranscriptionEngine.unclearAudioPlaceholder)]
        let e = energy(windowSeconds: 0.5, windowCount: 30, leftRMS: 0.01, rightRMS: 0.9)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertEqual(result.left.first?.text, "Ekte tekst")
        XCTAssertTrue(result.right.isEmpty)
    }

    func testBothPlaceholdersAreLeftInPlaceRatherThanGuessed() {
        // Neither side has real content to compare — time overlap alone is
        // too weak a signal to pick a "winner" here, so both stay as-is
        // rather than the (removed) energy-based guess this used to make.
        let left = [segment(id: 0, start: 10.0, end: 12.0, text: NativeTranscriptionEngine.unclearAudioPlaceholder)]
        let right = [segment(id: 0, start: 10.0, end: 12.0, text: NativeTranscriptionEngine.unclearAudioPlaceholder)]
        var rightWindows = Array(repeating: Float(0.01), count: 30)
        for w in 20..<24 { rightWindows[w] = 0.5 }
        let leftWindows = Array(repeating: Float(0.01), count: 30)
        let e = StereoSplitter.ChannelEnergy(windowSeconds: 0.5, left: leftWindows, right: rightWindows)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertEqual(result.left.count, 1)
        XCTAssertEqual(result.right.count, 1)
    }

    // MARK: - Overlap fraction threshold

    func testPartialOverlapBelowThresholdKeepsBoth() {
        // Only a sliver of overlap relative to segment duration — not a
        // real duplicate, just adjacent turns bleeding slightly at the
        // boundary. Both should survive.
        let left = [segment(id: 0, start: 10.0, end: 12.0, text: "Turn A")]
        let right = [segment(id: 0, start: 11.9, end: 14.0, text: "Turn B")]
        let e = energy(windowSeconds: 0.5, windowCount: 40, leftRMS: 0.2, rightRMS: 0.2)

        let result = StereoSplitter.deduplicateCrossTalk(
            left: left, right: right, energy: e, minOverlapFraction: 0.5)

        XCTAssertEqual(result.left.count, 1)
        XCTAssertEqual(result.right.count, 1)
    }

    func testSubstantialOverlapAboveThresholdTriggersDedup() {
        let left = [segment(id: 0, start: 10.0, end: 12.0, text: "Turn A")]
        let right = [segment(id: 0, start: 10.5, end: 12.5, text: "Turn A duplicate")]
        // 1.5s overlap / 2.0s shorter duration = 0.75, above the 0.5 default.
        let e = energy(windowSeconds: 0.5, windowCount: 40, leftRMS: 0.2, rightRMS: 0.2)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertEqual(result.left.count + result.right.count, 1, "one of the two should be dropped")
    }

    // MARK: - Word-similarity gate (regression coverage for a real bug)
    //
    // Found and fixed the same day `deduplicateCrossTalk` shipped: comparing
    // overlap against the *shorter* segment's own duration means a short,
    // real, textually unrelated segment (a brief interjection, or simply a
    // shorter segment elsewhere) nested anywhere inside a much longer
    // segment's span on the other channel always measured as ~100%
    // "overlap" — regardless of what either segment actually said. Reported
    // symptom: "the ENTIRE beginning of the clip is missing" and "MASSIVE
    // gaps... throughout" after this function shipped, on a real interview
    // where diarization had previously worked correctly. These tests pin
    // down the fix: overlap alone is no longer sufficient for the
    // real-text-vs-real-text branch — the words must also be similar
    // enough to plausibly be the same utterance.

    func testLongSegmentSurvivesDespiteNestedShortUnrelatedSegment() {
        // A ~90s interviewer monologue must not be discarded just because
        // a short, textually unrelated informant segment ("mhm") happens
        // to fall inside its time range — this is the exact shape of the
        // real regression (a long segment on one channel, a short
        // different-content segment nested inside it on the other).
        let left = [segment(
            id: 0, start: 0.0, end: 90.0,
            text: "Og da ser vi spesielt på brukermøter og dokumentasjon som tema, egentlig")]
        let right = [segment(id: 0, start: 10.0, end: 11.0, text: "mhm")]
        let e = energy(windowCount: 200, leftRMS: 0.2, rightRMS: 0.05)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertEqual(result.left.count, 1, "the long monologue must not be dropped")
        XCTAssertEqual(result.right.count, 1, "the short, distinct interjection must not be dropped either")
    }

    func testOverlappingButTextuallyUnrelatedSegmentsBothSurvive() {
        // Ordinary conversational overlap (someone starting to respond
        // before the other finishes) must not be treated as a duplicate
        // just because the time ranges overlap substantially.
        let left = [segment(id: 0, start: 0.0, end: 5.0, text: "Ja det er riktig")]
        let right = [segment(id: 0, start: 1.0, end: 4.0, text: "Nei det stemmer ikke helt")]
        let e = energy(windowCount: 40, leftRMS: 0.2, rightRMS: 0.2)

        let result = StereoSplitter.deduplicateCrossTalk(left: left, right: right, energy: e)

        XCTAssertEqual(result.left.count, 1)
        XCTAssertEqual(result.right.count, 1)
    }
}
