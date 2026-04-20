// TranscriptEditorState.swift
// AudioRecordingManager
//
// In-memory working copy of a transcript's segments with dirty tracking.
// Edits are collected here and flushed to disk on an explicit save().

import Foundation

@MainActor
final class TranscriptEditorState: ObservableObject {
    @Published var result: TranscriptionResult
    @Published var isDirty: Bool = false
    @Published var isSaving: Bool = false
    @Published var saveError: String?

    let recordingId: UUID

    init(result: TranscriptionResult, recordingId: UUID) {
        self.result = result
        self.recordingId = recordingId
    }

    // MARK: - Edit

    func updateSegment(id: Int, text: String) {
        guard let idx = result.segments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != result.segments[idx].text else { return }
        result.segments[idx].text = trimmed
        isDirty = true
    }

    // MARK: - Save

    func save() async {
        isSaving = true
        saveError = nil

        do {
            // 1. Write the JSON (canonical transcript)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let jsonDir = support.appendingPathComponent("AudioRecordingManager/transcripts")
            try FileManager.default.createDirectory(at: jsonDir, withIntermediateDirectories: true)
            let jsonURL = jsonDir.appendingPathComponent("\(recordingId.uuidString).json")

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(result)
            try data.write(to: jsonURL, options: .atomic)

            // 2. Regenerate the .txt from edited segments
            let plainText = result.segments
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n\n")
            let txtURL = StorageLayout.transcriptURL(id: recordingId)
            try plainText.write(to: txtURL, atomically: true, encoding: .utf8)

            // 3. Update sidecar
            _ = try RecordingStore.shared.updateMeta(id: recordingId) { meta in
                meta.transcript.status = .done
                meta.transcript.completedAt = Date()
                meta.transcript.lastEditedAt = Date()
            }

            // 4. Audit event
            AuditLogger.shared.log(.transcriptEdited, payload: [
                "recordingId": .string(recordingId.uuidString),
                "segmentCount": .int(result.segments.count),
            ])

            isDirty = false
        } catch {
            saveError = error.localizedDescription
            print("❌ TranscriptEditorState.save failed: \(error)")
        }

        isSaving = false
    }
}
