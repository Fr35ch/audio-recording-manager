import XCTest
@testable import Clio

/// Tests for the Multipeer resource stem-matching used to pair an audio
/// resource with its `<stem>.meta.json` sidecar regardless of arrival order.
final class SidecarStemMatchingTests: XCTestCase {

    func testAudioAndSidecarMapToSameStem() {
        let audioStem = NearbyTransferAdvertiser.audioStem(forResourceName: "intervju_20260611_143022.m4a")
        let sidecarStem = NearbyTransferAdvertiser.audioStem(forResourceName: "intervju_20260611_143022.meta.json")
        XCTAssertEqual(audioStem, sidecarStem)
        XCTAssertEqual(audioStem, "intervju_20260611_143022")
    }

    func testWavAudioMapsToSameStemAsSidecar() {
        let audioStem = NearbyTransferAdvertiser.audioStem(forResourceName: "opptak.wav")
        let sidecarStem = NearbyTransferAdvertiser.audioStem(forResourceName: "opptak.meta.json")
        XCTAssertEqual(audioStem, sidecarStem)
        XCTAssertEqual(audioStem, "opptak")
    }

    func testSidecarSuffixStrippedExactly() {
        // ".meta.json" must be removed as a whole — not just ".json".
        let stem = NearbyTransferAdvertiser.audioStem(forResourceName: "a.b.c.meta.json")
        XCTAssertEqual(stem, "a.b.c")
    }

    func testPlainNameWithoutExtension() {
        let stem = NearbyTransferAdvertiser.audioStem(forResourceName: "noext")
        XCTAssertEqual(stem, "noext")
    }

    func testDottedFilenameStripsOnlyLastExtensionForAudio() {
        // An audio file with dots in the name strips only the final extension.
        let stem = NearbyTransferAdvertiser.audioStem(forResourceName: "2026-06-11_14.30.22.m4a")
        XCTAssertEqual(stem, "2026-06-11_14.30.22")
    }
}
