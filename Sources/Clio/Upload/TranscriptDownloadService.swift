// TranscriptDownloadService.swift
// Clio
//
// Local-download fallback for anonymized transcripts while Teams/SharePoint
// upload is not yet functional. Same precondition gate as Teams upload
// (`UploadGate`) — the researcher must confirm de-identification before
// either flow is offered — but the download itself is a synchronous local
// save, not a tracked remote operation, so there is no upload-style
// pending/uploading/uploaded/failed state to persist in the sidecar.
//
// Two formats:
//   - Plain `.txt`: exactly the anonymized transcript content on disk,
//     the same bytes that would have gone to Teams.
//   - `.rtf`: delegates to the already-implemented `RTFExporter` for a
//     Word-compatible document with a redaction-stats line and compliance
//     footer.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum TranscriptDownloadService {

    enum DownloadError: LocalizedError {
        case transcriptMissing

        var errorDescription: String? {
            switch self {
            case .transcriptMissing:
                return "Fant ikke den avidentifiserte transkripsjonen på disk."
            }
        }
    }

    /// Presents a native save panel and writes the plain-text anonymized
    /// transcript on confirm. Returns the chosen URL on success, `nil` if
    /// the researcher cancelled or the save failed (error already surfaced
    /// via `NSAlert` in that case).
    @MainActor
    static func saveTXT(recording: RecordingMeta) -> URL? {
        let sourceURL = StorageLayout.anonymizedTranscriptURL(id: recording.id)
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            NSAlert(error: DownloadError.transcriptMissing).runModal()
            return nil
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = UploadGate.remoteName(
            displayName: recording.displayName,
            createdAt: recording.createdAt
        )
        panel.canCreateDirectories = true
        panel.title = "Last ned avidentifisert transkripsjon"
        panel.message = "Velg hvor du vil lagre tekstfilen. Husk å laste den opp til riktig Teams-/SharePoint-mappe selv."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Builds an `RTFExporter.Document` from `recording` and delegates to
    /// `RTFExporter.save` for the actual save panel + write.
    @MainActor
    static func saveRTF(recording: RecordingMeta) -> URL? {
        let sourceURL = StorageLayout.anonymizedTranscriptURL(id: recording.id)
        guard let body = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            NSAlert(error: DownloadError.transcriptMissing).runModal()
            return nil
        }

        var subtitle = "Avidentifisert"
        if let confirmedAt = recording.anonymization.researcherConfirmedAt {
            subtitle += " · \(confirmedAt.formatted(date: .long, time: .omitted))"
        }

        let statsLine = recording.anonymization.stats.map(AnonymizationMeta.statsSummary)

        let document = RTFExporter.Document(
            title: recording.displayName,
            subtitle: subtitle,
            statsLine: statsLine,
            body: body
        )

        let baseName = RTFExporter.sanitisedFilename(from: recording.displayName)
        return RTFExporter.save(document: document, defaultFilename: "\(baseName)_avidentifisert.rtf")
    }
}
