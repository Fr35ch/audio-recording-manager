//
//  DS2PasswordManagerTests.swift
//  AudioRecordingManagerTests
//
//  Tests for DS2 password manager
//

import XCTest
@testable import AudioRecordingManagerLib

final class DS2PasswordManagerTests: XCTestCase {

    var passwordManager: DS2PasswordManager!
    var testFileURL: URL!

    override func setUp() {
        super.setUp()
        passwordManager = DS2PasswordManager.shared

        // Create a test file URL (doesn't need to exist for password storage)
        let tempDir = FileManager.default.temporaryDirectory
        testFileURL = tempDir.appendingPathComponent("test-recording.ds2")

        // Clean up any existing test passwords
        try? passwordManager.deletePassword(for: testFileURL)
    }

    override func tearDown() {
        // Clean up test passwords
        try? passwordManager.deletePassword(for: testFileURL)
        super.tearDown()
    }

    // MARK: - Store Password Tests

    func testStorePassword() throws {
        let testPassword = "SecurePassword123!"

        // Store password
        try passwordManager.storePassword(testPassword, for: testFileURL)

        // Verify it was stored
        XCTAssertTrue(passwordManager.hasPassword(for: testFileURL))
    }

    func testStorePasswordOverwrites() throws {
        let firstPassword = "FirstPassword"
        let secondPassword = "SecondPassword"

        // Store first password
        try passwordManager.storePassword(firstPassword, for: testFileURL)

        // Store second password (should overwrite)
        try passwordManager.storePassword(secondPassword, for: testFileURL)

        // Retrieve and verify it's the second password
        let retrieved = try passwordManager.retrievePassword(for: testFileURL)
        XCTAssertEqual(retrieved, secondPassword)
    }

    // MARK: - Retrieve Password Tests

    func testRetrievePassword() throws {
        let testPassword = "TestPassword456"

        // Store password
        try passwordManager.storePassword(testPassword, for: testFileURL)

        // Retrieve password
        let retrieved = try passwordManager.retrievePassword(for: testFileURL)

        // Verify it matches
        XCTAssertEqual(retrieved, testPassword)
    }

    func testRetrieveNonExistentPassword() throws {
        let nonExistentURL = testFileURL.appendingPathExtension("nonexistent")

        // Try to retrieve password for file that doesn't have one
        let retrieved = try passwordManager.retrievePassword(for: nonExistentURL)

        // Should return nil
        XCTAssertNil(retrieved)
    }

    // MARK: - Delete Password Tests

    func testDeletePassword() throws {
        let testPassword = "DeleteMe"

        // Store password
        try passwordManager.storePassword(testPassword, for: testFileURL)
        XCTAssertTrue(passwordManager.hasPassword(for: testFileURL))

        // Delete password
        try passwordManager.deletePassword(for: testFileURL)

        // Verify it's deleted
        XCTAssertFalse(passwordManager.hasPassword(for: testFileURL))
    }

    func testDeleteNonExistentPassword() throws {
        let nonExistentURL = testFileURL.appendingPathExtension("nonexistent")

        // Should not throw when deleting non-existent password
        XCTAssertNoThrow(try passwordManager.deletePassword(for: nonExistentURL))
    }

    // MARK: - Has Password Tests

    func testHasPassword() throws {
        let testPassword = "CheckMe"

        // Initially should not have password
        XCTAssertFalse(passwordManager.hasPassword(for: testFileURL))

        // Store password
        try passwordManager.storePassword(testPassword, for: testFileURL)

        // Now should have password
        XCTAssertTrue(passwordManager.hasPassword(for: testFileURL))
    }

    // MARK: - Clear All Passwords Tests

    func testClearAllPasswords() throws {
        let testURL1 = testFileURL!
        let testURL2 = testFileURL.appendingPathExtension("second")

        // Store multiple passwords
        try passwordManager.storePassword("Password1", for: testURL1)
        try passwordManager.storePassword("Password2", for: testURL2)

        XCTAssertTrue(passwordManager.hasPassword(for: testURL1))
        XCTAssertTrue(passwordManager.hasPassword(for: testURL2))

        // Clear all passwords
        try passwordManager.clearAllPasswords()

        // Verify both are cleared
        XCTAssertFalse(passwordManager.hasPassword(for: testURL1))
        XCTAssertFalse(passwordManager.hasPassword(for: testURL2))
    }

    // MARK: - Special Characters Tests

    func testPasswordWithSpecialCharacters() throws {
        let complexPassword = "P@ssw0rd!#$%^&*()_+-=[]{}|;':\",./<>?"

        // Store password with special characters
        try passwordManager.storePassword(complexPassword, for: testFileURL)

        // Retrieve and verify
        let retrieved = try passwordManager.retrievePassword(for: testFileURL)
        XCTAssertEqual(retrieved, complexPassword)
    }

    func testPasswordWithUnicodeCharacters() throws {
        let unicodePassword = "日本語パスワード🔐"

        // Store password with unicode
        try passwordManager.storePassword(unicodePassword, for: testFileURL)

        // Retrieve and verify
        let retrieved = try passwordManager.retrievePassword(for: testFileURL)
        XCTAssertEqual(retrieved, unicodePassword)
    }
}
