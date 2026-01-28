//
//  DS2MetadataTests.swift
//  AudioRecordingManagerTests
//
//  Tests for DS2 metadata models
//

import XCTest
@testable import AudioRecordingManagerLib

final class DS2MetadataTests: XCTestCase {

    // MARK: - DS2Metadata Tests

    func testMetadataInitialization() {
        let metadata = DS2Metadata(
            duration: 125.5,
            recordingDate: Date(),
            fileSize: 1024000,
            authorID: "AUTHOR001",
            authorName: "John Doe"
        )

        XCTAssertEqual(metadata.duration, 125.5)
        XCTAssertEqual(metadata.authorID, "AUTHOR001")
        XCTAssertEqual(metadata.authorName, "John Doe")
        XCTAssertEqual(metadata.fileSize, 1024000)
    }

    func testFormattedDuration() {
        // Test hours:minutes:seconds
        let metadata1 = DS2Metadata(duration: 3665) // 1h 1m 5s
        XCTAssertEqual(metadata1.formattedDuration, "01:01:05")

        // Test minutes:seconds
        let metadata2 = DS2Metadata(duration: 125) // 2m 5s
        XCTAssertEqual(metadata2.formattedDuration, "02:05")

        // Test zero
        let metadata3 = DS2Metadata(duration: 0)
        XCTAssertEqual(metadata3.formattedDuration, "00:00")
    }

    func testFormattedFileSize() {
        let metadata = DS2Metadata(fileSize: 1024000) // ~1 MB
        let formatted = metadata.formattedFileSize

        // Should contain size information
        XCTAssertTrue(formatted.contains("KB") || formatted.contains("MB"))
    }

    func testFormattedRecordingDate() {
        let date = Date()
        let metadata = DS2Metadata(recordingDate: date)

        XCTAssertNotNil(metadata.formattedRecordingDate)
    }

    // MARK: - DS2Priority Tests

    func testPriorityComparison() {
        XCTAssertTrue(DS2Priority.low < DS2Priority.normal)
        XCTAssertTrue(DS2Priority.normal < DS2Priority.high)
        XCTAssertTrue(DS2Priority.high < DS2Priority.urgent)
    }

    func testPriorityDisplayNames() {
        XCTAssertEqual(DS2Priority.low.displayName, "Low")
        XCTAssertEqual(DS2Priority.normal.displayName, "Normal")
        XCTAssertEqual(DS2Priority.high.displayName, "High")
        XCTAssertEqual(DS2Priority.urgent.displayName, "Urgent")
    }

    func testPriorityEmojis() {
        XCTAssertEqual(DS2Priority.low.emoji, "🔵")
        XCTAssertEqual(DS2Priority.normal.emoji, "⚪️")
        XCTAssertEqual(DS2Priority.high.emoji, "🟡")
        XCTAssertEqual(DS2Priority.urgent.emoji, "🔴")
    }

    // MARK: - DS2EncryptionType Tests

    func testEncryptionTypeKeyLength() {
        XCTAssertEqual(DS2EncryptionType.none.keyLength, 0)
        XCTAssertEqual(DS2EncryptionType.aes128.keyLength, 128)
        XCTAssertEqual(DS2EncryptionType.aes256.keyLength, 256)
    }

    func testEncryptionTypeDisplayNames() {
        XCTAssertEqual(DS2EncryptionType.none.displayName, "Not Encrypted")
        XCTAssertEqual(DS2EncryptionType.aes128.displayName, "AES-128")
        XCTAssertEqual(DS2EncryptionType.aes256.displayName, "AES-256")
    }

    // MARK: - DS2OutputFormat Tests

    func testOutputFormatExtensions() {
        XCTAssertEqual(DS2OutputFormat.pcm.fileExtension, "pcm")
        XCTAssertEqual(DS2OutputFormat.wav.fileExtension, "wav")
        XCTAssertEqual(DS2OutputFormat.m4a.fileExtension, "m4a")
        XCTAssertEqual(DS2OutputFormat.mp3.fileExtension, "mp3")
    }

    // MARK: - DS2WorkType Tests

    func testWorkTypeDisplayNames() {
        XCTAssertEqual(DS2WorkType.dictation.displayName, "Dictation")
        XCTAssertEqual(DS2WorkType.meeting.displayName, "Meeting")
        XCTAssertEqual(DS2WorkType.interview.displayName, "Interview")
    }

    // MARK: - DS2Status Tests

    func testStatusDisplayNames() {
        XCTAssertEqual(DS2Status.new.displayName, "New")
        XCTAssertEqual(DS2Status.inProgress.displayName, "In Progress")
        XCTAssertEqual(DS2Status.completed.displayName, "Completed")
        XCTAssertEqual(DS2Status.archived.displayName, "Archived")
    }

    // MARK: - Codable Tests

    func testMetadataCodable() throws {
        let original = DS2Metadata(
            duration: 100,
            fileSize: 500000,
            authorID: "TEST123",
            workType: .dictation,
            priority: .high,
            encryptionType: .aes256
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DS2Metadata.self, from: data)

        // Verify
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.fileSize, original.fileSize)
        XCTAssertEqual(decoded.authorID, original.authorID)
        XCTAssertEqual(decoded.workType, original.workType)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.encryptionType, original.encryptionType)
    }
}
