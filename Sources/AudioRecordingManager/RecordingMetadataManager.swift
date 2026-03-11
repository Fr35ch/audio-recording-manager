import Foundation

/// Persists RecordingMetadata as JSON side-car files alongside each .m4a.
///
/// File naming: `<recording-stem>.metadata.json`
/// Example:     `interview_20260304_120000.m4a`
///              `interview_20260304_120000.metadata.json`
///
/// All I/O is synchronous and lightweight (small JSON blobs).
/// Callers that want to avoid blocking the main thread should dispatch onto
/// a background queue before calling these methods.
class RecordingMetadataManager {
    static let shared = RecordingMetadataManager()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - URL helpers

    func metadataURL(for recordingPath: String) -> URL {
        let url = URL(fileURLWithPath: recordingPath)
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(stem).metadata.json")
    }

    private func stableId(for recordingPath: String) -> String {
        URL(fileURLWithPath: recordingPath).deletingPathExtension().lastPathComponent
    }

    // MARK: - Load / Save

    func load(for recordingPath: String) -> RecordingMetadata? {
        let url = metadataURL(for: recordingPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(RecordingMetadata.self, from: data)
    }

    private func save(_ metadata: RecordingMetadata, for recordingPath: String) {
        let url = metadataURL(for: recordingPath)
        guard let data = try? encoder.encode(metadata) else {
            print("❌ RecordingMetadataManager: failed to encode metadata for \(recordingPath)")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("❌ RecordingMetadataManager: failed to write metadata: \(error)")
        }
    }

    // MARK: - Mutations

    /// Store the original transcript. No-op if one already exists (immutable after creation).
    func setOriginalTranscript(_ transcript: String, for recordingPath: String) {
        var metadata = load(for: recordingPath) ?? RecordingMetadata(
            recordingId: stableId(for: recordingPath),
            originalTranscript: nil,
            anonymizedTranscript: nil,
            anonymizationDate: nil,
            anonymizationStats: nil
        )
        // Immutability guarantee: never overwrite an existing original transcript
        guard metadata.originalTranscript == nil else {
            print("⚠️ RecordingMetadataManager: originalTranscript already set — not overwriting")
            return
        }
        metadata.originalTranscript = transcript
        save(metadata, for: recordingPath)
    }

    /// Store the anonymization result. Never touches originalTranscript.
    func applyAnonymizationResult(_ result: AnonymizationResult, for recordingPath: String) {
        var metadata = load(for: recordingPath) ?? RecordingMetadata(
            recordingId: stableId(for: recordingPath),
            originalTranscript: nil,
            anonymizedTranscript: nil,
            anonymizationDate: nil,
            anonymizationStats: nil
        )
        metadata.anonymizedTranscript = result.anonymizedText
        metadata.anonymizationDate = Date()
        metadata.anonymizationStats = result.stats
        save(metadata, for: recordingPath)
    }
}
