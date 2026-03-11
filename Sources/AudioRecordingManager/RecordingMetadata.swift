import Foundation

// MARK: - Anonymization Result (mirrors no-anonymizer Python model)

struct Redaction: Codable {
    let position: Int
    let length: Int
    let category: String
    let replacement: String
}

struct AnonymizationResult: Codable {
    let anonymizedText: String
    let redactions: [Redaction]
    let stats: [String: Int]
    let processingTimeMs: Double
}

// MARK: - Recording Metadata (persisted alongside .m4a as .metadata.json)

struct RecordingMetadata: Codable {
    /// Stable identifier derived from the recording filename (without extension).
    let recordingId: String

    /// Original transcript — immutable after first write.
    /// Only RecordingMetadataManager.setOriginalTranscript() may populate this field,
    /// and it refuses to overwrite a non-nil value.
    var originalTranscript: String?

    /// Anonymized version — nil until user triggers anonymization.
    var anonymizedTranscript: String?

    /// When anonymization last completed successfully.
    var anonymizationDate: Date?

    /// Redaction counts per category from the last successful run.
    var anonymizationStats: [String: Int]?
}
