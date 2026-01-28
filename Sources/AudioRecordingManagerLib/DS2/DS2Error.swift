//
//  DS2Error.swift
//  AudioRecordingManager
//
//  DS2 format error definitions
//

import Foundation

/// Errors that can occur during DS2 file operations
enum DS2Error: Error, LocalizedError {
    // File errors
    case fileNotFound(String)
    case invalidFileFormat(String)
    case corruptedFile(String)
    case unsupportedVersion(String)

    // Encryption errors
    case encryptionKeyRequired
    case invalidPassword
    case decryptionFailed(String)
    case keyDerivationFailed(String)

    // Decoding errors
    case codecNotSupported(String)
    case decodingFailed(String)
    case audioStreamInvalid(String)

    // Metadata errors
    case metadataReadFailed(String)
    case metadataCorrupted(String)

    // SDK/Implementation errors
    case sdkNotAvailable
    case sdkInitializationFailed(String)
    case sdkLicenseInvalid(String)

    // General errors
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "DS2 file not found: \(path)"
        case .invalidFileFormat(let detail):
            return "Invalid DS2 file format: \(detail)"
        case .corruptedFile(let detail):
            return "DS2 file is corrupted: \(detail)"
        case .unsupportedVersion(let version):
            return "Unsupported DS2 version: \(version)"

        case .encryptionKeyRequired:
            return "DS2 file is encrypted and requires a password"
        case .invalidPassword:
            return "Invalid password for encrypted DS2 file"
        case .decryptionFailed(let detail):
            return "Failed to decrypt DS2 file: \(detail)"
        case .keyDerivationFailed(let detail):
            return "Failed to derive encryption key: \(detail)"

        case .codecNotSupported(let codec):
            return "DS2 codec not supported: \(codec)"
        case .decodingFailed(let detail):
            return "Failed to decode DS2 audio: \(detail)"
        case .audioStreamInvalid(let detail):
            return "Invalid DS2 audio stream: \(detail)"

        case .metadataReadFailed(let detail):
            return "Failed to read DS2 metadata: \(detail)"
        case .metadataCorrupted(let detail):
            return "DS2 metadata is corrupted: \(detail)"

        case .sdkNotAvailable:
            return "OM System Audio SDK is not available or not initialized"
        case .sdkInitializationFailed(let detail):
            return "Failed to initialize OM System Audio SDK: \(detail)"
        case .sdkLicenseInvalid(let detail):
            return "Invalid SDK license: \(detail)"

        case .unknown(let error):
            return "Unknown DS2 error: \(error.localizedDescription)"
        }
    }
}
