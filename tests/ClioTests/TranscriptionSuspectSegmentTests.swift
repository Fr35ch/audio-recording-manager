import XCTest
@testable import Clio

/// Real, executed coverage for `TranscriptionService.isSuspectSegment` and
/// `.contentDensityScore` — the consolidated "does this segment need a
/// repair attempt" check that replaced two narrower checks (exact
/// placeholder match, letter-free text) after a real, reported bug: a
/// segment whose entire text was a single stray character (`>`) spanning
/// ~11 seconds of real speech was not an exact placeholder match, so it
/// slipped past the old gate entirely and was shown to the researcher as
/// if it were real transcript content.
final class TranscriptionSuspectSegmentTests: XCTestCase {

    private func segment(_ start: Double, _ end: Double, text: String) -> TranscriptionSegment {
        TranscriptionSegment(
            id: 0, start: start, end: end, text: text, speaker: "SPEAKER_0",
            confidence: 1.0, words: [], lowConfidence: nil)
    }

    // MARK: - contentDensityScore

    func testDensityScoreCountsLettersNotRawCharacters() {
        // Punctuation/spaces shouldn't inflate the score.
        let score = TranscriptionService.contentDensityScore(
            text: "Ja, det stemmer.", durationSeconds: 2.0)
        // "Jadetstemmer" = 12 letters / 2s = 6.0
        XCTAssertEqual(score, 6.0, accuracy: 0.01)
    }

    func testDensityScoreZeroDurationReturnsZero() {
        let score = TranscriptionService.contentDensityScore(text: "Ja", durationSeconds: 0)
        XCTAssertEqual(score, 0, accuracy: 0.001)
    }

    // MARK: - isSuspectSegment

    func testExactPlaceholderIsAlwaysSuspect() {
        let seg = segment(0, 1, text: NativeTranscriptionEngine.unclearAudioPlaceholder)
        XCTAssertTrue(TranscriptionService.isSuspectSegment(seg))
    }

    func testRealLongSegmentWithNormalContentIsNotSuspect() {
        let seg = segment(0, 11, text: "Laptopen som åpner denne, som tar opp 1.25, 1.26, 1.27.")
        XCTAssertFalse(TranscriptionService.isSuspectSegment(seg))
    }

    func testStrayCharacterOverLongSpanIsSuspect() {
        // The actual reported bug shape: a single stray symbol/character
        // spanning a real, multi-second block of speech.
        let seg = segment(0, 11, text: ">")
        XCTAssertTrue(TranscriptionService.isSuspectSegment(seg))
    }

    func testShortRealUtteranceIsExemptFromDensityCheck() {
        // "Ja." over 1 second would fail a naive density check, but real
        // short utterances must never be flagged — the duration floor
        // exists specifically to protect this case.
        let seg = segment(0, 1, text: "Ja.")
        XCTAssertFalse(TranscriptionService.isSuspectSegment(seg))
    }

    func testSparseLongSegmentIsSuspect() {
        let seg = segment(0, 10, text: "eh")
        XCTAssertTrue(TranscriptionService.isSuspectSegment(seg))
    }

    func testNormalDensityRightAtDurationFloorIsNotSuspect() {
        let seg = segment(0, 3, text: "Ja det stemmer det.")
        XCTAssertFalse(TranscriptionService.isSuspectSegment(seg))
    }
}
