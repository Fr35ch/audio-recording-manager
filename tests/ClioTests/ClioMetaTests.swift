import XCTest
@testable import Clio

final class ClioMetaTests: XCTestCase {

    // MARK: - Decoding

    func testDecodesRodeStereoSidecar() throws {
        let json = """
        {
            "arm_version": "1.4.0",
            "recording_source": "ios_rode_wireless_micro",
            "recorded_at": "2026-06-11T12:00:00Z",
            "channels": 2,
            "channel_assignment": { "left": "INTERVJUER", "right": "INFORMANT" },
            "diarization_required": false
        }
        """
        let meta = try XCTUnwrap(ClioMeta.decode(from: Data(json.utf8)))
        XCTAssertFalse(meta.diarizationRequired)
        XCTAssertEqual(meta.recordingSource, "ios_rode_wireless_micro")
        XCTAssertEqual(meta.armVersion, "1.4.0")
        XCTAssertEqual(meta.resolvedLeft, "INTERVJUER")
        XCTAssertEqual(meta.resolvedRight, "INFORMANT")
    }

    func testDecodesBuiltinMicSidecarWithNullChannelAssignment() throws {
        let json = """
        {
            "arm_version": "1.4.0",
            "recording_source": "ios_builtin_mic",
            "recorded_at": "2026-06-11T12:00:00Z",
            "channels": 1,
            "channel_assignment": null,
            "diarization_required": true
        }
        """
        let meta = try XCTUnwrap(ClioMeta.decode(from: Data(json.utf8)))
        XCTAssertTrue(meta.diarizationRequired)
        XCTAssertNil(meta.channelAssignment)
        // Defaults apply when channel_assignment is absent/null.
        XCTAssertEqual(meta.resolvedLeft, "INTERVJUER")
        XCTAssertEqual(meta.resolvedRight, "INFORMANT")
    }

    func testDecodeReturnsNilOnGarbage() {
        XCTAssertNil(ClioMeta.decode(from: Data("not json".utf8)))
    }

    func testToleratesUnknownAndMissingOptionalKeys() throws {
        // Only the required diarization flag is present; everything else absent.
        let json = """
        { "diarization_required": false, "some_future_key": 42 }
        """
        let meta = try XCTUnwrap(ClioMeta.decode(from: Data(json.utf8)))
        XCTAssertFalse(meta.diarizationRequired)
        XCTAssertNil(meta.recordingSource)
        XCTAssertNil(meta.armVersion)
    }

    // MARK: - Defaults

    func testRodeDualChannelDefault() {
        let meta = ClioMeta.rodeDualChannelDefault()
        XCTAssertFalse(meta.diarizationRequired)
        XCTAssertEqual(meta.recordingSource, "ios_rode_wireless_micro")
        XCTAssertEqual(meta.channelAssignment?.left, "INTERVJUER")
        XCTAssertEqual(meta.channelAssignment?.right, "INFORMANT")
    }

    // MARK: - Round-trip via disk

    func testWriteThenLoadRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-meta-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let audioURL = tmp.appendingPathComponent("audio.m4a")
        // Touch a placeholder audio file so the sidecar sits beside a real path.
        FileManager.default.createFile(atPath: audioURL.path, contents: Data("fake".utf8))

        try ClioMeta.rodeDualChannelDefault().write(for: audioURL)

        // Sidecar must be co-located as audio.meta.json.
        let sidecarURL = tmp.appendingPathComponent("audio.meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let loaded = try XCTUnwrap(ClioMeta.load(for: audioURL))
        XCTAssertFalse(loaded.diarizationRequired)
        XCTAssertEqual(loaded.resolvedLeft, "INTERVJUER")
        XCTAssertEqual(loaded.resolvedRight, "INFORMANT")
    }

    func testLoadReturnsNilWhenSidecarAbsent() {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-sidecar-\(UUID().uuidString).m4a")
        XCTAssertNil(ClioMeta.load(for: audioURL))
    }

    func testWrittenSidecarUsesSnakeCaseKeys() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-meta-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let audioURL = tmp.appendingPathComponent("audio.m4a")
        try ClioMeta.rodeDualChannelDefault().write(for: audioURL)

        let raw = try String(contentsOf: tmp.appendingPathComponent("audio.meta.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("diarization_required"))
        XCTAssertTrue(raw.contains("channel_assignment"))
        XCTAssertTrue(raw.contains("recording_source"))
    }
}
