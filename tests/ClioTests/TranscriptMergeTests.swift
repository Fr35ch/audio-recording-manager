import XCTest
@testable import Clio

final class TranscriptMergeTests: XCTestCase {

    private let left = "INTERVJUER"
    private let right = "INFORMANT"

    func testInterleavesByTimestampAndInjectsLabels() {
        let leftText = """
        [00:00:05] Hei, kan du fortelle litt om deg selv?
        [00:00:20] Takk for det.
        """
        let rightText = """
        [00:00:12] Ja, jeg heter Kari.
        """
        let merged = TranscriptionService.mergeTranscripts(
            left: leftText, right: rightText, leftLabel: left, rightLabel: right)

        let expected = """
        [00:00:05] INTERVJUER: Hei, kan du fortelle litt om deg selv?
        [00:00:12] INFORMANT: Ja, jeg heter Kari.
        [00:00:20] INTERVJUER: Takk for det.
        """
        XCTAssertEqual(merged, expected)
    }

    func testLeftWinsOnTimestampTie() {
        let leftText = "[00:01:00] Venstre"
        let rightText = "[00:01:00] Høyre"
        let merged = TranscriptionService.mergeTranscripts(
            left: leftText, right: rightText, leftLabel: left, rightLabel: right)

        let expected = """
        [00:01:00] INTERVJUER: Venstre
        [00:01:00] INFORMANT: Høyre
        """
        XCTAssertEqual(merged, expected)
    }

    func testHandlesHoursInTimestamp() {
        let leftText = "[01:02:03] Lang opptak"
        let merged = TranscriptionService.mergeTranscripts(
            left: leftText, right: "", leftLabel: left, rightLabel: right)
        XCTAssertEqual(merged, "[01:02:03] INTERVJUER: Lang opptak")
    }

    func testSkipsLinesWithoutValidTimestamp() {
        let leftText = """
        Dette er en linje uten tidsstempel
        [00:00:09] Gyldig linje
        [bad] Ugyldig
        """
        let merged = TranscriptionService.mergeTranscripts(
            left: leftText, right: "", leftLabel: left, rightLabel: right)
        XCTAssertEqual(merged, "[00:00:09] INTERVJUER: Gyldig linje")
    }

    func testEmptyInputsProduceEmptyString() {
        let merged = TranscriptionService.mergeTranscripts(
            left: "", right: "", leftLabel: left, rightLabel: right)
        XCTAssertEqual(merged, "")
    }

    func testCustomLabelsAreRespected() {
        let merged = TranscriptionService.mergeTranscripts(
            left: "[00:00:01] A",
            right: "[00:00:02] B",
            leftLabel: "FORSKER",
            rightLabel: "DELTAKER")
        let expected = """
        [00:00:01] FORSKER: A
        [00:00:02] DELTAKER: B
        """
        XCTAssertEqual(merged, expected)
    }
}
