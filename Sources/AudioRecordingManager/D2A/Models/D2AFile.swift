// D2AFile.swift
// AudioRecordingManager / D2A
//
// Represents a single .d2a file discovered on a mounted SD card. Pure
// value type — holds metadata only; the bytes stay on the card until
// `D2ABridgeService` copies them into the VM shared folder.

import Foundation

struct D2AFile: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    let name: String
    let path: URL
    let size: Int64
    let createdAt: Date

    /// Encrypted-by-default. The Olympus DS-9500 ships D2A files with
    /// password protection enabled out of the box; we only learn it
    /// isn't encrypted when the VM service rejects the password header.
    let isEncrypted: Bool

    init(url: URL) {
        self.id = UUID()
        self.name = url.lastPathComponent
        self.path = url
        self.size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        self.createdAt = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
        self.isEncrypted = true
    }

    /// Human-readable name without the .d2a extension, used as the default
    /// `displayName` when the decrypted file is imported as a recording.
    var displayName: String {
        (name as NSString).deletingPathExtension
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
