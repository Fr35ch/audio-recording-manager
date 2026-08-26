// AvidentifiseringBekreftSection.swift
// Clio
//
// Standalone section for researcher sign-off on de-identification.
// Shown in RecordingDetailView whenever a transcript exists.
// Independent of the Teams upload section — sign-off is a compliance
// step that belongs to the researcher workflow, not the upload workflow.

import SwiftUI

struct AvidentifiseringBekreftSection: View {

    let recording: RecordingMeta
    let onMetaChanged: (RecordingMeta) -> Void

    @State private var showSignOffAlert = false
    @State private var showRevokeAlert = false

    private var isConfirmed: Bool {
        recording.anonymization.researcherConfirmedAt != nil
    }

    private var armToolRan: Bool {
        recording.anonymization.status == .done
    }

    var body: some View {
        if isConfirmed {
            confirmedView
        } else {
            pendingView
        }
    }

    // MARK: - Confirmed state

    private var confirmedView: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 16))
                .foregroundStyle(AppColors.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("Avidentifisering bekreftet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.success)
                if let confirmedAt = recording.anonymization.researcherConfirmedAt {
                    Text("Bekreftet \(confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Trekk tilbake") {
                showRevokeAlert = true
            }
            .buttonStyle(PillButtonStyle(variant: .secondary))
            .font(.system(size: 11))
        }
        .alert("Trekk tilbake bekreftelse?", isPresented: $showRevokeAlert) {
            Button("Trekk tilbake", role: .destructive) { revokeSignOff() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Bekreftelsen på avidentifisering fjernes. Opptaket kan ikke lastes opp til Teams før det bekreftes på nytt.")
        }
    }

    // MARK: - Pending state

    private var pendingView: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.anonymizerBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.large)
                        .strokeBorder(AppColors.accent.opacity(0.25), lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 2)
                .fill(AppColors.accent)
                .frame(width: 3)
                .padding(.vertical, 10)
                .clipped()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: armToolRan ? "checkmark.seal.fill" : "lock.shield")
                        .font(.system(size: 18))
                        .foregroundStyle(AppColors.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Bekreft avidentifisering")
                            .font(.system(size: 13, weight: .semibold))
                        Text(armToolRan ? "Clio-verktøyet er brukt" : "Manuell eller Clio")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(armToolRan
                    ? "Gjennomgå transkripsjonen og bekreft at alle personopplysninger er fjernet."
                    : "Avidentifiser transkripsjonen med Clio-verktøyet eller manuelt, og bekreft før opplasting."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    showSignOffAlert = true
                } label: {
                    Label("Jeg bekrefter", systemImage: "checkmark")
                }
                .buttonStyle(PillButtonStyle(variant: .primary))
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
        }
        .alert("Bekreft avidentifisering", isPresented: $showSignOffAlert) {
            Button("Bekreft", role: .none) { confirmSignOff() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Jeg bekrefter at transkripsjonen er avidentifisert og ikke inneholder personidentifiserbare opplysninger.")
        }
    }

    // MARK: - Action

    private func confirmSignOff() {
        do {
            let updated = try AnonymizationConfirmationService.confirm(recordingId: recording.id)
            onMetaChanged(updated)
        } catch {
            print("⚠️ AvidentifiseringBekreftSection: confirmSignOff failed: \(error)")
        }
    }

    private func revokeSignOff() {
        var updated = recording
        updated.anonymization.researcherConfirmedAt = nil
        AuditLogger.shared.logAnonymizationConfirmationRevoked(recordingId: recording.id)
        onMetaChanged(updated)
    }
}
