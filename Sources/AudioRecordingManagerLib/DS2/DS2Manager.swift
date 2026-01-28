//
//  DS2Manager.swift
//  AudioRecordingManager
//
//  Main manager for DS2 file operations
//

import Foundation
import Combine

/// Main manager for DS2 file operations
/// Coordinates decoding, password management, and metadata extraction
final class DS2Manager: ObservableObject {
    static let shared = DS2Manager()

    // MARK: - Published Properties

    @Published var ds2Files: [DS2File] = []
    @Published var isScanning: Bool = false
    @Published var lastError: DS2Error?

    // MARK: - Dependencies

    private let decoder: DS2DecoderProtocol
    private let passwordManager: DS2PasswordManagerProtocol
    private let metadataExtractor: DS2MetadataExtractorProtocol

    // MARK: - Initialization

    private init(
        decoder: DS2DecoderProtocol = DS2Decoder(),
        passwordManager: DS2PasswordManagerProtocol = DS2PasswordManager.shared,
        metadataExtractor: DS2MetadataExtractorProtocol = DS2MetadataExtractor()
    ) {
        self.decoder = decoder
        self.passwordManager = passwordManager
        self.metadataExtractor = metadataExtractor

        print("📀 DS2Manager initialized")
    }

    // MARK: - File Discovery

    /// Scan a directory for DS2 files
    func scanForDS2Files(in directory: URL) async {
        await MainActor.run { isScanning = true }

        defer {
            Task { @MainActor in
                isScanning = false
            }
        }

        do {
            let fileManager = FileManager.default
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            var discoveredFiles: [DS2File] = []

            for fileURL in files {
                // Check if it's a DS2 file
                guard decoder.isValidDS2File(at: fileURL) else { continue }

                // Extract metadata
                do {
                    let metadata = try metadataExtractor.extractBasicMetadata(from: fileURL)
                    let isEncrypted = try decoder.isEncrypted(at: fileURL)

                    let ds2File = DS2File(
                        url: fileURL,
                        metadata: metadata,
                        isEncrypted: isEncrypted
                    )

                    discoveredFiles.append(ds2File)
                } catch {
                    print("⚠️ Failed to read DS2 file: \(fileURL.lastPathComponent) - \(error)")
                }
            }

            // Sort and update on main actor
            let sortedFiles = discoveredFiles.sorted { $0.metadata.recordingDate ?? Date.distantPast > $1.metadata.recordingDate ?? Date.distantPast }
            let fileCount = discoveredFiles.count

            await MainActor.run {
                self.ds2Files = sortedFiles
                print("📀 Found \(fileCount) DS2 files")
            }

        } catch {
            await MainActor.run {
                self.lastError = .unknown(error)
                print("❌ Error scanning for DS2 files: \(error)")
            }
        }
    }

    // MARK: - File Operations

    /// Validate a DS2 file
    func validateFile(at url: URL) -> DS2ValidationResult {
        var errors: [DS2Error] = []
        var warnings: [String] = []

        // Check if valid DS2
        guard decoder.isValidDS2File(at: url) else {
            errors.append(.invalidFileFormat("Not a valid DS2 file"))
            return DS2ValidationResult(isValid: false, errors: errors, warnings: warnings)
        }

        // Check file size
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int64, fileSize == 0 {
                errors.append(.corruptedFile("File is empty"))
            }
        } catch {
            errors.append(.fileNotFound(url.path))
        }

        // Check if encrypted
        do {
            let encrypted = try decoder.isEncrypted(at: url)
            if encrypted {
                warnings.append("File is encrypted and requires password for decoding")
            }
        } catch let error as DS2Error {
            errors.append(error)
        } catch {
            errors.append(.unknown(error))
        }

        return DS2ValidationResult(
            isValid: errors.isEmpty,
            errors: errors,
            warnings: warnings
        )
    }

    /// Decode DS2 file with password handling
    func decodeFile(
        at sourceURL: URL,
        to destinationURL: URL,
        outputFormat: DS2OutputFormat = .wav,
        promptForPassword: @escaping () async -> String?
    ) async throws {
        // Validate file
        let validation = validateFile(at: sourceURL)
        guard validation.isValid else {
            throw validation.errors.first ?? DS2Error.invalidFileFormat("Unknown validation error")
        }

        // Check if encrypted
        let isEncrypted = try decoder.isEncrypted(at: sourceURL)
        var password: String?

        if isEncrypted {
            // Try to retrieve stored password
            password = try passwordManager.retrievePassword(for: sourceURL)

            // If no stored password, prompt user
            if password == nil {
                password = await promptForPassword()

                // Store password if provided
                if let pwd = password {
                    try passwordManager.storePassword(pwd, for: sourceURL)
                }
            }

            // If still no password, cannot proceed
            guard password != nil else {
                throw DS2Error.encryptionKeyRequired
            }
        }

        // Decode file
        try await decoder.decodeAndSave(
            from: sourceURL,
            to: destinationURL,
            password: password,
            outputFormat: outputFormat
        )

        print("✅ Successfully decoded: \(sourceURL.lastPathComponent)")
    }

    /// Get metadata for a DS2 file
    func getMetadata(for url: URL) throws -> DS2Metadata {
        guard decoder.isValidDS2File(at: url) else {
            throw DS2Error.invalidFileFormat("Not a valid DS2 file")
        }

        return try metadataExtractor.extractBasicMetadata(from: url)
    }

    // MARK: - Password Management

    /// Store password for a DS2 file
    func storePassword(_ password: String, for fileURL: URL) throws {
        try passwordManager.storePassword(password, for: fileURL)
    }

    /// Check if password is stored for a file
    func hasStoredPassword(for fileURL: URL) -> Bool {
        return passwordManager.hasPassword(for: fileURL)
    }

    /// Delete stored password
    func deleteStoredPassword(for fileURL: URL) throws {
        try passwordManager.deletePassword(for: fileURL)
    }

    /// Clear all stored passwords
    func clearAllPasswords() throws {
        try passwordManager.clearAllPasswords()
    }

    // MARK: - Batch Operations

    /// Decode multiple DS2 files
    func decodeMultipleFiles(
        files: [(source: URL, destination: URL)],
        outputFormat: DS2OutputFormat = .wav,
        promptForPassword: @escaping (URL) async -> String?
    ) async -> [(url: URL, result: Result<Void, Error>)] {
        var results: [(url: URL, result: Result<Void, Error>)] = []

        for (source, destination) in files {
            do {
                try await decodeFile(
                    at: source,
                    to: destination,
                    outputFormat: outputFormat,
                    promptForPassword: { await promptForPassword(source) }
                )
                results.append((url: source, result: .success(())))
            } catch {
                results.append((url: source, result: .failure(error)))
            }
        }

        return results
    }
}
