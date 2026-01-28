//
//  DS2MetadataExtractor.swift
//  AudioRecordingManager
//
//  DS2 file metadata extraction
//

import Foundation

/// Extracts metadata from DS2 files
final class DS2MetadataExtractor: DS2MetadataExtractorProtocol {

    // MARK: - DS2MetadataExtractorProtocol

    func extractBasicMetadata(from url: URL) throws -> DS2Metadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DS2Error.fileNotFound(url.path)
        }

        // Get file attributes
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        let modificationDate = attributes[.modificationDate] as? Date

        // Read file header for basic metadata
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw DS2Error.metadataReadFailed("Cannot open file")
        }

        // Read header (first 512 bytes should contain basic metadata)
        guard let headerData = try? fileHandle.read(upToCount: 512),
              headerData.count >= 4 else {
            throw DS2Error.corruptedFile("File header too short")
        }

        // Parse header
        let parsedData = parseHeader(headerData)

        // Extract duration from header if available
        // DS2 files store duration in header at specific offset
        let duration = parsedData.duration ?? 0

        // Basic metadata without SDK
        return DS2Metadata(
            duration: duration,
            recordingDate: modificationDate,
            fileSize: fileSize,
            authorID: parsedData.authorID,
            authorName: nil,
            workType: nil,
            priority: nil,
            status: nil,
            deviceModel: parsedData.deviceModel,
            deviceSerialNumber: nil,
            firmwareVersion: nil,
            sampleRate: parsedData.sampleRate,
            bitRate: nil,
            channels: parsedData.channels,
            codec: parsedData.codec,
            encryptionType: parsedData.encryptionType,
            comments: nil,
            customFields: nil
        )
    }

    func extractFullMetadata(from url: URL, password: String?) throws -> DS2Metadata {
        // TODO: Implement full metadata extraction with OM System Audio SDK
        // For now, fall back to basic metadata

        print("⚠️ Full metadata extraction requires OM System Audio SDK (not yet integrated)")
        return try extractBasicMetadata(from: url)

        // SDK integration pseudocode:
        // 1. Initialize SDK
        // 2. Open DS2 file
        // 3. If encrypted, decrypt with password
        // 4. Extract all metadata fields
        // 5. Return complete DS2Metadata
    }

    // MARK: - Private Helpers

    /// Parsed header data
    private struct HeaderData {
        var duration: TimeInterval?
        var authorID: String?
        var deviceModel: String?
        var sampleRate: Int?
        var channels: Int?
        var codec: String?
        var encryptionType: DS2EncryptionType?
    }

    /// Parse DS2 file header
    private func parseHeader(_ data: Data) -> HeaderData {
        var result = HeaderData()

        // Verify magic bytes
        guard data.count >= 4 else { return result }
        let magicBytes = [UInt8](data[0..<4])

        // Check if it's DS2 format
        if magicBytes[0] == 0x03 && magicBytes[1] == 0x64 &&
           magicBytes[2] == 0x73 && magicBytes[3] == 0x32 {
            result.codec = "DSS Pro"
        }

        // Parse duration (stored at specific offset in header)
        // Format: HHMMSS string at offset 38-43 (6 bytes)
        if data.count >= 44 {
            let durationBytes = data[38..<44]
            if let durationString = String(data: durationBytes, encoding: .ascii) {
                result.duration = parseDurationString(durationString)
            }
        }

        // Parse duration (also stored as milliseconds at offset 0x0C)
        if data.count >= 16 {
            let milliseconds = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: 0x0C, as: UInt32.self)
            }
            if milliseconds > 0 {
                result.duration = Double(milliseconds) / 1000.0
            }
        }

        // TODO: Parse other metadata fields
        // - Author ID (stored in header)
        // - Device model (stored in header)
        // - Sample rate (typically 8000 Hz for DSS)
        // - Channels (typically 1 for mono)
        // - Encryption type (flag in header)

        // Default audio properties for DSS/DS2
        result.sampleRate = 8000  // Typical for DSS format
        result.channels = 1       // Mono
        result.encryptionType = DS2EncryptionType.none  // Default, should be read from header

        return result
    }

    /// Parse duration string in HHMMSS format
    private func parseDurationString(_ string: String) -> TimeInterval? {
        // Expected format: "HHMMSS" (6 characters)
        guard string.count == 6 else { return nil }

        let hoursStr = String(string.prefix(2))
        let minutesStr = String(string.dropFirst(2).prefix(2))
        let secondsStr = String(string.suffix(2))

        guard let hours = Int(hoursStr),
              let minutes = Int(minutesStr),
              let seconds = Int(secondsStr) else {
            return nil
        }

        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }
}
