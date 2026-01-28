//
//  DS2DecoderTests.swift
//  AudioRecordingManagerTests
//
//  Tests for DS2 decoder
//

import XCTest
@testable import AudioRecordingManagerLib

final class DS2DecoderTests: XCTestCase {

    var decoder: DS2Decoder!
    var testFileURL: URL!

    override func setUp() {
        super.setUp()
        decoder = DS2Decoder()

        let tempDir = FileManager.default.temporaryDirectory
        testFileURL = tempDir.appendingPathComponent("test.ds2")
    }

    override func tearDown() {
        // Clean up test files
        try? FileManager.default.removeItem(at: testFileURL)
        super.tearDown()
    }

    // MARK: - File Validation Tests

    func testIsValidDS2FileWithWrongExtension() {
        let wrongExtensionURL = testFileURL.deletingPathExtension().appendingPathExtension("mp3")

        XCTAssertFalse(decoder.isValidDS2File(at: wrongExtensionURL))
    }

    func testIsValidDS2FileNonExistent() {
        XCTAssertFalse(decoder.isValidDS2File(at: testFileURL))
    }

    func testIsValidDS2FileWithValidMagicBytes() throws {
        // Create a test DS2 file with correct magic bytes
        let magicBytes: [UInt8] = [0x03, 0x64, 0x73, 0x32]  // \x03ds2
        let testData = Data(magicBytes + [UInt8](repeating: 0, count: 500))
        try testData.write(to: testFileURL)

        XCTAssertTrue(decoder.isValidDS2File(at: testFileURL))
    }

    func testIsValidDS2FileWithInvalidMagicBytes() throws {
        // Create a file with incorrect magic bytes
        let invalidBytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        let testData = Data(invalidBytes)
        try testData.write(to: testFileURL)

        XCTAssertFalse(decoder.isValidDS2File(at: testFileURL))
    }

    // MARK: - Encryption Detection Tests

    func testIsEncryptedThrowsForInvalidFile() {
        XCTAssertThrowsError(try decoder.isEncrypted(at: testFileURL)) { error in
            guard case DS2Error.invalidFileFormat = error else {
                XCTFail("Expected invalidFileFormat error, got \(error)")
                return
            }
        }
    }

    func testIsEncryptedReturnsFalseForStub() throws {
        // Create a valid DS2 file stub
        let magicBytes: [UInt8] = [0x03, 0x64, 0x73, 0x32]
        let testData = Data(magicBytes + [UInt8](repeating: 0, count: 500))
        try testData.write(to: testFileURL)

        // Current stub implementation returns false
        // This will change when SDK is integrated
        let encrypted = try decoder.isEncrypted(at: testFileURL)
        XCTAssertFalse(encrypted, "Stub implementation should return false")
    }

    // MARK: - Metadata Extraction Tests

    func testExtractMetadataFromInvalidFile() {
        XCTAssertThrowsError(try decoder.extractMetadata(from: testFileURL)) { error in
            guard case DS2Error.invalidFileFormat = error else {
                XCTFail("Expected invalidFileFormat error, got \(error)")
                return
            }
        }
    }

    func testExtractMetadataFromValidFile() throws {
        // Create a valid DS2 file with basic header
        let magicBytes: [UInt8] = [0x03, 0x64, 0x73, 0x32]
        var headerData = Data(magicBytes)

        // Add padding to reach minimum size
        headerData.append(Data(repeating: 0, count: 508))

        try headerData.write(to: testFileURL)

        // Should not throw
        let metadata = try decoder.extractMetadata(from: testFileURL)

        // Verify metadata structure
        XCTAssertNotNil(metadata)
        XCTAssertGreaterThanOrEqual(metadata.fileSize, 0)
    }

    // MARK: - Decode Tests

    func testDecodeThrowsSDKNotAvailable() async throws {
        // Create a valid DS2 file
        let magicBytes: [UInt8] = [0x03, 0x64, 0x73, 0x32]
        let testData = Data(magicBytes + [UInt8](repeating: 0, count: 500))
        try testData.write(to: testFileURL)

        // Attempt to decode should throw sdkNotAvailable
        do {
            _ = try await decoder.decode(
                fileAt: testFileURL,
                password: nil,
                outputFormat: .wav
            )
            XCTFail("Expected sdkNotAvailable error")
        } catch DS2Error.sdkNotAvailable {
            // Expected error
            XCTAssert(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDecodeThrowsInvalidFileFormat() async {
        // Invalid file
        do {
            _ = try await decoder.decode(
                fileAt: testFileURL,
                password: nil,
                outputFormat: .wav
            )
            XCTFail("Expected invalidFileFormat error")
        } catch DS2Error.invalidFileFormat {
            // Expected error
            XCTAssert(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
