//
//  DS2Models.swift
//  AudioRecordingManager
//
//  Domain models for DS2 file format
//

import Foundation

// MARK: - DS2 File Model

/// Represents a DS2 (DSS Pro) audio file
struct DS2File: Identifiable {
    let id: UUID
    let url: URL
    let metadata: DS2Metadata
    let isEncrypted: Bool

    init(url: URL, metadata: DS2Metadata, isEncrypted: Bool) {
        self.id = UUID()
        self.url = url
        self.metadata = metadata
        self.isEncrypted = isEncrypted
    }

    var filename: String {
        url.lastPathComponent
    }

    var fileExtension: String {
        url.pathExtension
    }
}

// MARK: - DS2 Metadata

/// Metadata extracted from DS2 files
struct DS2Metadata: Codable, Equatable {
    // Recording information
    let duration: TimeInterval
    let recordingDate: Date?
    let fileSize: Int64

    // Author information
    let authorID: String?
    let authorName: String?

    // Workflow metadata
    let workType: DS2WorkType?
    let priority: DS2Priority?
    let status: DS2Status?

    // Device information
    let deviceModel: String?
    let deviceSerialNumber: String?
    let firmwareVersion: String?

    // Audio format details
    let sampleRate: Int?
    let bitRate: Int?
    let channels: Int?
    let codec: String?

    // Encryption information
    let encryptionType: DS2EncryptionType?

    // Additional metadata
    let comments: String?
    let customFields: [String: String]?

    init(
        duration: TimeInterval = 0,
        recordingDate: Date? = nil,
        fileSize: Int64 = 0,
        authorID: String? = nil,
        authorName: String? = nil,
        workType: DS2WorkType? = nil,
        priority: DS2Priority? = nil,
        status: DS2Status? = nil,
        deviceModel: String? = nil,
        deviceSerialNumber: String? = nil,
        firmwareVersion: String? = nil,
        sampleRate: Int? = nil,
        bitRate: Int? = nil,
        channels: Int? = nil,
        codec: String? = nil,
        encryptionType: DS2EncryptionType? = nil,
        comments: String? = nil,
        customFields: [String: String]? = nil
    ) {
        self.duration = duration
        self.recordingDate = recordingDate
        self.fileSize = fileSize
        self.authorID = authorID
        self.authorName = authorName
        self.workType = workType
        self.priority = priority
        self.status = status
        self.deviceModel = deviceModel
        self.deviceSerialNumber = deviceSerialNumber
        self.firmwareVersion = firmwareVersion
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.channels = channels
        self.codec = codec
        self.encryptionType = encryptionType
        self.comments = comments
        self.customFields = customFields
    }

    // Formatted helpers
    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var formattedRecordingDate: String? {
        guard let date = recordingDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - DS2 Enums

/// Work type classification for DS2 files
enum DS2WorkType: String, Codable {
    case dictation
    case meeting
    case interview
    case lecture
    case memo
    case other

    var displayName: String {
        rawValue.capitalized
    }
}

/// Priority level for DS2 recordings
enum DS2Priority: Int, Codable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3

    static func < (lhs: DS2Priority, rhs: DS2Priority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    var emoji: String {
        switch self {
        case .low: return "🔵"
        case .normal: return "⚪️"
        case .high: return "🟡"
        case .urgent: return "🔴"
        }
    }
}

/// Recording status for workflow management
enum DS2Status: String, Codable {
    case new
    case inProgress
    case completed
    case archived

    var displayName: String {
        switch self {
        case .new: return "New"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .archived: return "Archived"
        }
    }
}

/// Encryption type used in DS2 file
enum DS2EncryptionType: String, Codable {
    case none
    case aes128
    case aes256

    var displayName: String {
        switch self {
        case .none: return "Not Encrypted"
        case .aes128: return "AES-128"
        case .aes256: return "AES-256"
        }
    }

    var keyLength: Int {
        switch self {
        case .none: return 0
        case .aes128: return 128
        case .aes256: return 256
        }
    }
}

// MARK: - DS2 Audio Output

/// Output format for decoded DS2 audio
enum DS2OutputFormat {
    case pcm
    case wav
    case m4a
    case mp3

    var fileExtension: String {
        switch self {
        case .pcm: return "pcm"
        case .wav: return "wav"
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        }
    }
}

/// Decoded audio data from DS2 file
struct DS2AudioData {
    let format: DS2OutputFormat
    let data: Data
    let sampleRate: Int
    let channels: Int
    let duration: TimeInterval

    /// Save decoded audio to file
    func save(to url: URL) throws {
        try data.write(to: url)
    }
}
