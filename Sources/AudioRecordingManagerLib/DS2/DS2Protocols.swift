//
//  DS2Protocols.swift
//  AudioRecordingManager
//
//  Protocol definitions for DS2 file handling
//

import Foundation

// MARK: - DS2 Decoder Protocol

/// Protocol for DS2 file decoding
protocol DS2DecoderProtocol {
    /// Check if a file is a valid DS2 file
    /// - Parameter url: File URL to check
    /// - Returns: True if the file is a valid DS2 file
    func isValidDS2File(at url: URL) -> Bool

    /// Check if a DS2 file is encrypted
    /// - Parameter url: File URL to check
    /// - Returns: True if the file is encrypted
    /// - Throws: DS2Error if file cannot be read
    func isEncrypted(at url: URL) throws -> Bool

    /// Extract metadata from DS2 file without decrypting
    /// - Parameter url: File URL to read
    /// - Returns: DS2Metadata containing file information
    /// - Throws: DS2Error if metadata cannot be extracted
    func extractMetadata(from url: URL) throws -> DS2Metadata

    /// Decode DS2 file to specified output format
    /// - Parameters:
    ///   - url: DS2 file URL
    ///   - password: Optional password for encrypted files
    ///   - outputFormat: Desired output format (default: WAV)
    /// - Returns: Decoded audio data
    /// - Throws: DS2Error if decoding fails
    func decode(
        fileAt url: URL,
        password: String?,
        outputFormat: DS2OutputFormat
    ) async throws -> DS2AudioData

    /// Decode and save DS2 file directly to output URL
    /// - Parameters:
    ///   - sourceURL: DS2 file URL
    ///   - destinationURL: Output file URL
    ///   - password: Optional password for encrypted files
    ///   - outputFormat: Desired output format
    /// - Throws: DS2Error if decoding or saving fails
    func decodeAndSave(
        from sourceURL: URL,
        to destinationURL: URL,
        password: String?,
        outputFormat: DS2OutputFormat
    ) async throws
}

// MARK: - DS2 Password Manager Protocol

/// Protocol for secure password storage and retrieval
protocol DS2PasswordManagerProtocol {
    /// Store password for a specific DS2 file
    /// - Parameters:
    ///   - password: Password to store
    ///   - fileURL: DS2 file URL (used as identifier)
    /// - Throws: Error if storage fails
    func storePassword(_ password: String, for fileURL: URL) throws

    /// Retrieve stored password for a DS2 file
    /// - Parameter fileURL: DS2 file URL
    /// - Returns: Stored password, or nil if not found
    /// - Throws: Error if retrieval fails
    func retrievePassword(for fileURL: URL) throws -> String?

    /// Delete stored password for a DS2 file
    /// - Parameter fileURL: DS2 file URL
    /// - Throws: Error if deletion fails
    func deletePassword(for fileURL: URL) throws

    /// Check if a password exists for a file
    /// - Parameter fileURL: DS2 file URL
    /// - Returns: True if password is stored
    func hasPassword(for fileURL: URL) -> Bool

    /// Clear all stored passwords (for security/cleanup)
    /// - Throws: Error if cleanup fails
    func clearAllPasswords() throws
}

// MARK: - DS2 Metadata Extractor Protocol

/// Protocol for DS2 metadata extraction
protocol DS2MetadataExtractorProtocol {
    /// Extract basic metadata without SDK (header parsing only)
    /// - Parameter url: DS2 file URL
    /// - Returns: Partial metadata that can be read without decryption
    /// - Throws: DS2Error if file cannot be read
    func extractBasicMetadata(from url: URL) throws -> DS2Metadata

    /// Extract full metadata using SDK (requires decryption if encrypted)
    /// - Parameters:
    ///   - url: DS2 file URL
    ///   - password: Optional password for encrypted files
    /// - Returns: Complete metadata
    /// - Throws: DS2Error if extraction fails
    func extractFullMetadata(from url: URL, password: String?) throws -> DS2Metadata
}

// MARK: - DS2 File Validator Protocol

/// Protocol for DS2 file validation
protocol DS2FileValidatorProtocol {
    /// Validate DS2 file integrity
    /// - Parameter url: DS2 file URL
    /// - Returns: Validation result with details
    func validate(fileAt url: URL) -> DS2ValidationResult
}

/// Result of DS2 file validation
struct DS2ValidationResult {
    let isValid: Bool
    let errors: [DS2Error]
    let warnings: [String]

    var hasErrors: Bool {
        !errors.isEmpty
    }

    var hasWarnings: Bool {
        !warnings.isEmpty
    }
}
