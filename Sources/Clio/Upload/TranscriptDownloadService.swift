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
//   - Plain `.txt`: the anonymized transcript, one line per segment,
//     each prefixed with its timestamp and speaker label (e.g.
//     `[0:15] Intervjuer: …`) — matching what the transcript editor shows.
//   - `.rtf`: delegates to the already-implemented `RTFExporter` for a
//     Word-compatible document with a redaction-stats line and compliance
//     footer, using the same per-line annotated body.

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
    /// transcript on confirm. `completion` receives the chosen URL on
    /// success, or `nil` if the researcher cancelled or the save failed
    /// (error already surfaced via `NSAlert` in that case).
    ///
    /// The panel presentation is deferred one run-loop tick via
    /// `DispatchQueue.main.async`. Calling `NSSavePanel.runModal()`
    /// synchronously from directly inside a SwiftUI `Button` action causes
    /// AppKit's modal session to be short-circuited (observed: `runModal()`
    /// returns `.cancel` with `panel.url == nil` immediately, with no panel
    /// ever appearing on screen) — a known SwiftUI/AppKit interaction
    /// issue. Deferring to the next tick lets SwiftUI's own transaction
    /// finish first, so the modal session can actually start.
    @MainActor
    static func saveTXT(recording: RecordingMeta, completion: @escaping (URL?) -> Void) {
        let sourceURL = StorageLayout.anonymizedTranscriptURL(id: recording.id)
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            NSAlert(error: DownloadError.transcriptMissing).runModal()
            completion(nil)
            return
        }
        let annotatedText = buildAnnotatedBody(recording: recording, anonymizedText: text)

        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = UploadGate.remoteName(
                displayName: recording.displayName,
                createdAt: recording.createdAt
            )
            panel.canCreateDirectories = true
            panel.title = "Last ned avidentifisert transkripsjon"
            panel.message = "Velg hvor du vil lagre tekstfilen. Husk å laste den opp til riktig Teams-/SharePoint-mappe selv."

            guard panel.runModal() == .OK, let url = panel.url else {
                completion(nil)
                return
            }

            do {
                try annotatedText.write(to: url, atomically: true, encoding: .utf8)
                completion(url)
            } catch {
                NSAlert(error: error).runModal()
                completion(nil)
            }
        }
    }

    /// Builds an `RTFExporter.Document` from `recording` and delegates to
    /// `RTFExporter.save` for the actual save panel + write. `completion`
    /// receives the chosen URL on success, `nil` on cancel/failure.
    @MainActor
    static func saveRTF(recording: RecordingMeta, completion: @escaping (URL?) -> Void) {
        let sourceURL = StorageLayout.anonymizedTranscriptURL(id: recording.id)
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            NSAlert(error: DownloadError.transcriptMissing).runModal()
            completion(nil)
            return
        }
        let annotatedText = buildAnnotatedBody(recording: recording, anonymizedText: text)

        var subtitle = "Avidentifisert"
        if let confirmedAt = recording.anonymization.researcherConfirmedAt {
            subtitle += " · \(confirmedAt.formatted(date: .long, time: .omitted))"
        }

        let statsLine = recording.anonymization.stats.map(AnonymizationMeta.statsSummary)

        let document = RTFExporter.Document(
            title: recording.displayName,
            subtitle: subtitle,
            statsLine: statsLine,
            body: annotatedText
        )

        let baseName = RTFExporter.sanitisedFilename(from: recording.displayName)
        RTFExporter.save(document: document, defaultFilename: "\(baseName)_avidentifisert.rtf", completion: completion)
    }

    // MARK: - Per-line timestamp + speaker annotation

    /// Builds the per-line, timestamped, speaker-labeled export body from
    /// the anonymized transcript. The anonymizer receives (and returns) the
    /// full transcript as `segments.map { $0.text }.joined(separator:
    /// "\n\n")` (see `TranscriptEditorView.runAnonymization`), so splitting
    /// the anonymized text by the same separator recovers a 1:1 mapping
    /// back to each segment's start time and speaker.
    ///
    /// Falls back to the flat, unannotated anonymized text if segments
    /// can't be loaded or the paragraph counts don't line up — defensive,
    /// so a mismatch never crashes or silently misattributes a line to the
    /// wrong timestamp/speaker.
    private static func buildAnnotatedBody(recording: RecordingMeta, anonymizedText: String) -> String {
        guard let segments = loadSegments(recordingId: recording.id), !segments.isEmpty else {
            return anonymizedText
        }
        let lines = anonymizedText.components(separatedBy: "\n\n")
        guard lines.count == segments.count else {
            return anonymizedText
        }
        return zip(segments, lines).map { segment, line in
            let timestamp = TranscriptionSegment.formatTimestamp(segment.start)
            let speaker = TranscriptionSegment.shortSpeakerLabel(segment.speaker)
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(timestamp)] \(speaker): \(trimmedLine)"
        }.joined(separator: "\n\n")
    }

    /// Loads segments (start/end/speaker) for `recording` from the
    /// canonical transcript JSON written by the editor
    /// (`~/Library/Application Support/AudioRecordingManager/transcripts/<uuid>.json`
    /// — see `TranscriptEditorState.save()`). Returns `nil` if the JSON
    /// doesn't exist or fails to decode (e.g. a recording transcribed
    /// before this sidecar existed).
    private static func loadSegments(recordingId: UUID) -> [TranscriptionSegment]? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jsonURL = support.appendingPathComponent("AudioRecordingManager/transcripts/\(recordingId.uuidString).json")
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? decoder.decode(TranscriptionResult.self, from: data) else { return nil }
        return result.segments
    }
}
