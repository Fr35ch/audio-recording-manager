import XCTest
@testable import Clio

final class TranscriptValidationTests: XCTestCase {

    private func segment(
        id: Int = 0, start: Double, end: Double, text: String, speaker: String = "SPEAKER_0"
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            id: id, start: start, end: end, text: text, speaker: speaker,
            confidence: 1.0, words: [])
    }

    /// `n` space-separated filler words with no risk of tripping
    /// `detectRepetitionLoops` (12 distinct words on a fixed cycle — since
    /// none of the detector's checked n-gram sizes, 2-8, divide evenly
    /// into a 12-word period, no adjacent n-gram can ever repeat) and no
    /// overlap with `TranscriptValidation.hallucinationPhrases`. Used to
    /// give fixtures enough word density that `detectLowDensityRegions`
    /// (60s windows, 30 wpm floor) doesn't fire as an unintended side
    /// effect while isolating a single other issue type under test.
    private func filler(_ n: Int) -> String {
        let words = ["en", "to", "tre", "fire", "fem", "seks", "sju", "åtte", "ni", "ti", "elleve", "tolv"]
        return (0..<n).map { words[$0 % words.count] }.joined(separator: " ")
    }

    // MARK: - detectHallucinationPhrases

    func testDetectsKnownHallucinationPhraseCaseInsensitively() {
        let segments = [
            segment(start: 0, end: 5, text: "Hei, dette er en vanlig setning."),
            segment(id: 1, start: 5, end: 10, text: "TAKK FOR AT DU SÅ PÅ denne videoen"),
        ]
        let issues = TranscriptValidation.detectHallucinationPhrases(segments: segments)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].kind, .hallucinationPhrase)
        XCTAssertEqual(issues[0].start, 5)
        XCTAssertEqual(issues[0].end, 10)
    }

    func testNoHallucinationPhraseNoIssues() {
        let segments = [segment(start: 0, end: 5, text: "En helt vanlig transkripsjon.")]
        XCTAssertTrue(TranscriptValidation.detectHallucinationPhrases(segments: segments).isEmpty)
    }

    func testOnlyFlagsFirstMatchingPhrasePerSegment() {
        // "subscribe" and "like and subscribe" both appear — Python's
        // detector breaks after the first match per chunk; the exact
        // phrase chosen depends on list order, but there must be
        // exactly one issue for this segment either way.
        let segments = [segment(start: 0, end: 5, text: "please like and subscribe now")]
        let issues = TranscriptValidation.detectHallucinationPhrases(segments: segments)
        XCTAssertEqual(issues.count, 1)
    }

    // MARK: - detectGaps

    func testDetectsGapLongerThanThreshold() {
        let segments = [
            segment(start: 0, end: 5, text: "Først."),
            segment(id: 1, start: 20, end: 25, text: "Etter et hull."),
        ]
        let issues = TranscriptValidation.detectGaps(segments: segments, minGapSeconds: 10.0)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].kind, .gap)
        XCTAssertEqual(issues[0].start, 5)
        XCTAssertEqual(issues[0].end, 20)
    }

    func testNoGapIssueWhenBelowThreshold() {
        let segments = [
            segment(start: 0, end: 5, text: "Først."),
            segment(id: 1, start: 8, end: 12, text: "Rett etter."),
        ]
        XCTAssertTrue(
            TranscriptValidation.detectGaps(segments: segments, minGapSeconds: 10.0).isEmpty)
    }

    func testSingleSegmentHasNoGaps() {
        let segments = [segment(start: 0, end: 5, text: "Alene.")]
        XCTAssertTrue(TranscriptValidation.detectGaps(segments: segments).isEmpty)
    }

    // MARK: - detectLowDensityRegions

    func testFlagsWindowWithTooFewWordsPerMinute() {
        // 60s window, only 2 words spoken → 2 wpm, well under the 30 wpm floor.
        let segments = [segment(start: 0, end: 60, text: "Ja nei")]
        let issues = TranscriptValidation.detectLowDensityRegions(
            segments: segments, windowSeconds: 60, minWPM: 30)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(issues.first?.kind, .lowDensity)
    }

    func testDoesNotFlagDenseSpeech() {
        let denseText = Array(repeating: "ord", count: 200).joined(separator: " ")
        let segments = [segment(start: 0, end: 60, text: denseText)]
        let issues = TranscriptValidation.detectLowDensityRegions(
            segments: segments, windowSeconds: 60, minWPM: 30)
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - detectRepetitionLoops

    func testDetectsRepeatedPhrase() {
        let segments = [segment(start: 0, end: 10, text: "ja ja ja ja ja ja")]
        let issues = TranscriptValidation.detectRepetitionLoops(segments: segments, minRepeats: 3)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(issues.first?.kind, .repetition)
        // Repetition issues never carry a timestamp range (matches navt.py).
        XCTAssertNil(issues.first?.start)
        XCTAssertNil(issues.first?.end)
    }

    func testNoRepetitionInNormalSpeech() {
        let segments = [segment(start: 0, end: 10, text: "dette er en helt normal setning uten repetisjon")]
        XCTAssertTrue(TranscriptValidation.detectRepetitionLoops(segments: segments).isEmpty)
    }

    // MARK: - detectEnergyMismatch

    func testFlagsLoudAudioWithNoTranscribedWords() {
        let segments = [segment(start: 0, end: 5, text: "")]
        let energies: [(start: Double, end: Double, rms: Float)] = [(start: 0, end: 5, rms: 0.5)]
        let issues = TranscriptValidation.detectEnergyMismatch(
            segments: segments, audioEnergies: energies, energyThreshold: 0.01)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].kind, .energyMismatchMissed)
    }

    func testFlagsSilentAudioWithLotsOfText() {
        let manyWords = Array(repeating: "ord", count: 15).joined(separator: " ")
        let segments = [segment(start: 0, end: 5, text: manyWords)]
        let energies: [(start: Double, end: Double, rms: Float)] = [(start: 0, end: 5, rms: 0.001)]
        let issues = TranscriptValidation.detectEnergyMismatch(
            segments: segments, audioEnergies: energies, energyThreshold: 0.01)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].kind, .energyMismatchHallucination)
    }

    func testNoMismatchWhenAudioAndTextAgree() {
        let segments = [segment(start: 0, end: 5, text: "noen få ord")]
        let energies: [(start: Double, end: Double, rms: Float)] = [(start: 0, end: 5, rms: 0.05)]
        XCTAssertTrue(
            TranscriptValidation.detectEnergyMismatch(
                segments: segments, audioEnergies: energies, energyThreshold: 0.01
            ).isEmpty)
    }

    // MARK: - validate (orchestration + scoring)

    func testCleanTranscriptScoresPerfect() {
        let segments = [
            segment(start: 0, end: 30, text: filler(30)),
            segment(id: 1, start: 30, end: 65, text: filler(30)),
        ]
        let summary = TranscriptValidation.validate(segments: segments, wavURL: nil)
        XCTAssertEqual(summary.score, 100)
        XCTAssertEqual(summary.issueCount, 0)
        XCTAssertEqual(summary.summary, "ingen problemer funnet")
    }

    func testGapPenalizesScoreByCappedSeconds() {
        // 25s gap (30 -> 55), penalty capped at 20 per navt.py's
        // `min(20, gap_seconds)`. 30 filler words either side keeps every
        // 60s window at or above the 30 wpm floor, so gap is the only
        // issue triggered — isolating its score contribution.
        let segments = [
            segment(start: 0, end: 30, text: filler(30)),
            segment(id: 1, start: 55, end: 85, text: filler(30)),
        ]
        let summary = TranscriptValidation.validate(segments: segments, wavURL: nil)
        XCTAssertEqual(summary.issueCount, 1)
        XCTAssertEqual(summary.score, 80)
    }

    func testHallucinationPhrasePenalizesScoreByTen() {
        // Enough filler words around the phrase to clear the low-density
        // floor within the one ~40s window this fixture spans, isolating
        // the hallucination-phrase penalty on its own.
        let segments = [
            segment(start: 0, end: 40, text: "\(filler(15)) husk å abonnere \(filler(15))"),
        ]
        let summary = TranscriptValidation.validate(segments: segments, wavURL: nil)
        XCTAssertEqual(summary.issueCount, 1)
        XCTAssertEqual(summary.score, 90)
    }

    func testScoreNeverGoesBelowZero() {
        // Stack multiple large-penalty issues to try to drive score negative.
        let segments = [
            segment(start: 0, end: 5, text: "husk å abonnere"),
            segment(id: 1, start: 100, end: 105, text: "husk å like og takk for i dag"),
            segment(id: 2, start: 200, end: 205, text: "teksting av subtitles by"),
        ]
        let summary = TranscriptValidation.validate(segments: segments, wavURL: nil)
        XCTAssertGreaterThanOrEqual(summary.score, 0)
    }

    // MARK: - flagLowConfidenceSegments

    func testGapFlagsOnlyOverlappingSegmentsNotDistantOnes() {
        // Enough density either side that the *only* issue is the gap
        // itself, spanning [30, 55) — neither segment's own span [0,30)
        // or [55,85) overlaps that range, so neither should be flagged
        // even though a gap was detected between them.
        let segments = [
            segment(start: 0, end: 30, text: filler(30)),
            segment(id: 1, start: 55, end: 85, text: filler(30)),
        ]
        let summary = TranscriptValidation.validate(segments: segments, wavURL: nil)
        let flagged = TranscriptValidation.flagLowConfidenceSegments(
            segments: segments, summary: summary)
        XCTAssertEqual(flagged.map { $0.lowConfidence ?? false }, [false, false])
    }

    func testRepetitionIssueNeverFlagsASegment() {
        // Repetition has no timestamp range, so even though it contributes
        // to score/issueCount, it must never set lowConfidence on any
        // segment. Padded with filler words so low-density doesn't also
        // fire and confound the result.
        let segments = [
            segment(start: 0, end: 70, text: "\(filler(30)) ja ja ja ja ja ja \(filler(30))"),
        ]
        let summary = TranscriptValidation.validate(segments: segments, wavURL: nil)
        XCTAssertTrue(summary.issues.contains { $0.kind == .repetition })
        let flagged = TranscriptValidation.flagLowConfidenceSegments(
            segments: segments, summary: summary)
        XCTAssertEqual(flagged.map { $0.lowConfidence ?? false }, [false])
    }

    func testEnergyMismatchIssueFlagsOverlappingSegment() {
        let segments = [segment(start: 0, end: 5, text: "")]
        let energies: [(start: Double, end: Double, rms: Float)] = [(start: 0, end: 5, rms: 0.5)]
        let issues = TranscriptValidation.detectEnergyMismatch(
            segments: segments, audioEnergies: energies, energyThreshold: 0.01)
        let summary = TranscriptValidationSummary(
            issues: issues, summary: "test", score: 92, issueCount: issues.count)
        let flagged = TranscriptValidation.flagLowConfidenceSegments(
            segments: segments, summary: summary)
        XCTAssertEqual(flagged.first?.lowConfidence, true)
    }
}
