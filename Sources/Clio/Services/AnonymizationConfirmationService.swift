// AnonymizationConfirmationService.swift
// Clio
//
// Single source of truth for what happens when a researcher confirms
// de-identification — whether they ran the automatic anonymization tool
// first or are confirming a manual/external de-identification instead.
//
// Two call sites share this: AvidentifiseringBekreftSection (recording
// detail panel) and TranscriptEditorView's sign-off bar (inside the
// editor). Both used to hand-set `researcherConfirmedAt` directly, which
// left a gap: if the automatic tool never ran, no
// `transcript_anonymized.txt` ever existed, so the transcript download
// feature (which reads that file) failed even though confirmation
// succeeded and `UploadGate` reported ready.

import Foundation

enum AnonymizationConfirmationService {

    /// Confirms de-identification for `recordingId`.
    ///
    /// If the automatic anonymization tool has not completed
    /// (`anonymization.status != .done`), copies the *current*
    /// `transcript.txt` content into `transcript_anonymized.txt` verbatim —
    /// the researcher confirming is asserting that the current transcript
    /// text, however it was produced (manual edits, an external tool,
    /// etc.), no longer contains identifying information. This always
    /// reflects the latest transcript text, so re-confirming after further
    /// manual edits refreshes the copy rather than leaving a stale one
    /// behind.
    ///
    /// If the automatic tool already completed, the anonymized file it
    /// produced is left untouched — this never overwrites a real
    /// anonymization run with a plain copy.
    @discardableResult
    static func confirm(recordingId: UUID) throws -> RecordingMeta {
        guard let meta = try RecordingStore.shared.load(id: recordingId) else {
            throw RecordingStoreError.recordingNotFound(recordingId)
        }
        let armToolRan = meta.anonymization.status == .done

        if !armToolRan {
            let transcriptURL = StorageLayout.transcriptURL(id: recordingId)
            let text = try String(contentsOf: transcriptURL, encoding: .utf8)
            let anonURL = StorageLayout.anonymizedTranscriptURL(id: recordingId)
            try text.write(to: anonURL, atomically: true, encoding: .utf8)
        }

        let updated = try RecordingStore.shared.updateMeta(id: recordingId) { current in
            current.anonymization.researcherConfirmedAt = Date()
            if current.anonymization.filename == nil {
                current.anonymization.filename = "transcript_anonymized.txt"
            }
        }

        AuditLogger.shared.logAnonymizationConfirmedByResearcher(
            recordingId: recordingId,
            armToolUsed: armToolRan
        )

        return updated
    }
}
