// TranscriptDownloadSection.swift
// Clio
//
// Local-download fallback shown in RecordingDetailView's right panel after
// transcription, replacing TeamsUploadSection while real Teams/SharePoint
// upload is not yet functional.
//
// Gate: identical to Teams upload — transcript must exist AND the researcher
// must have confirmed de-identification (`UploadGate.evaluate`, unchanged).
// Once both are satisfied, downloading is a synchronous local save (no
// pending/uploading/failed state to persist), so the ready view simply
// always offers both download formats.

import SwiftUI

struct TranscriptDownloadSection: View {

    let recording: RecordingMeta

    @State private var lastSavedURL: URL?

    private var readiness: UploadReadiness {
        UploadGate.evaluate(recording: recording)
    }

    var body: some View {
        sectionBody
    }

    // MARK: - State machine

    @ViewBuilder
    private var sectionBody: some View {
        switch readiness {
        case .blockedNoTranscript:
            blockedView(
                icon: "waveform.and.mic",
                iconColor: .secondary,
                title: "Ingen transkripsjon",
                message: "Transkriber opptaket for å aktivere nedlasting."
            )
        case .blockedNotConfirmed:
            blockedView(
                icon: "lock.shield",
                iconColor: AppColors.accent,
                title: "Avidentifisering ikke bekreftet",
                message: "Bekreft avidentifisering i seksjonen over for å aktivere nedlasting."
            )
        default:
            readyView
        }
    }

    // MARK: - State views

    private func blockedView(
        icon: String,
        iconColor: Color,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                    .font(.system(size: 14))
                Text("Klar for nedlasting")
                    .font(.system(size: 13, weight: .medium))
            }

            Text("Opplasting til Teams er midlertidig ikke tilgjengelig i Clio. Last ned den avidentifiserte transkripsjonen og last den opp til riktig Teams-/SharePoint-mappe selv.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Last ned som TXT") {
                    TranscriptDownloadService.saveTXT(recording: recording) { url in
                        if let url = url {
                            lastSavedURL = url
                            AuditLogger.shared.logTranscriptExported(
                                recordingId: recording.id.uuidString,
                                format: "txt",
                                filenameHint: url.lastPathComponent
                            )
                        }
                    }
                }
                .buttonStyle(PillButtonStyle(variant: .primary))

                Button("Last ned som RTF") {
                    TranscriptDownloadService.saveRTF(recording: recording) { url in
                        if let url = url {
                            lastSavedURL = url
                            AuditLogger.shared.logTranscriptExported(
                                recordingId: recording.id.uuidString,
                                format: "rtf",
                                filenameHint: url.lastPathComponent
                            )
                        }
                    }
                }
                .buttonStyle(PillButtonStyle(variant: .secondary))
            }

            if let url = lastSavedURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                        .font(.system(size: 11))
                    Text("Lagret som \(url.lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
