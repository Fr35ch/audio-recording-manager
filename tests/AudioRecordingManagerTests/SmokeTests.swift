import XCTest
@testable import AudioRecordingManagerLib

/// Smoke tests to verify the project structure and test infrastructure
final class SmokeTests: XCTestCase {

    // MARK: - Infrastructure Tests

    func testProjectCompiles() {
        // Verify basic project setup
        XCTAssertTrue(true, "Project compiles and tests run")
    }

    func testSwiftVersion() {
        // Verify Swift version is 5+
        #if swift(>=5.0)
        XCTAssertTrue(true, "Swift 5+ detected")
        #else
        XCTFail("Swift 5+ required")
        #endif
    }

    func testMacOSEnvironment() {
        // Basic environment check
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertGreaterThanOrEqual(version.majorVersion, 14, "macOS 14+ required")
    }

    func testLibraryInitialization() {
        // Verify library module is accessible
        XCTAssertTrue(AudioRecordingManagerLib.isInitialized())
        XCTAssertEqual(AudioRecordingManagerLib.name, "Audio Recording Manager")
    }

    // MARK: - AudioFileUtils Tests

    func testValidAudioExtensions() {
        // Test supported extensions
        XCTAssertTrue(AudioFileUtils.isValidAudioExtension("recording.wav"))
        XCTAssertTrue(AudioFileUtils.isValidAudioExtension("recording.mp3"))
        XCTAssertTrue(AudioFileUtils.isValidAudioExtension("recording.m4a"))
        XCTAssertTrue(AudioFileUtils.isValidAudioExtension("recording.WAV"))  // Case insensitive
    }

    func testInvalidAudioExtensions() {
        // Test unsupported extensions
        XCTAssertFalse(AudioFileUtils.isValidAudioExtension("document.pdf"))
        XCTAssertFalse(AudioFileUtils.isValidAudioExtension("image.png"))
        XCTAssertFalse(AudioFileUtils.isValidAudioExtension("video.mov"))
    }

    func testFormatDuration() {
        // Test duration formatting
        XCTAssertEqual(AudioFileUtils.formatDuration(0), "0:00")
        XCTAssertEqual(AudioFileUtils.formatDuration(65), "1:05")
        XCTAssertEqual(AudioFileUtils.formatDuration(3665), "1:01:05")
    }

    func testFormatFileSize() {
        // Test file size formatting
        let size1KB = AudioFileUtils.formatFileSize(1024)
        XCTAssertTrue(size1KB.contains("KB") || size1KB.contains("kB"))

        let size1MB = AudioFileUtils.formatFileSize(1024 * 1024)
        XCTAssertTrue(size1MB.contains("MB"))
    }
}
