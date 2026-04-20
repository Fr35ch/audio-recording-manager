// ComplianceChecklistView.swift
// AudioRecordingManager
//
// Compliance acknowledgement screen shown before the first upload in a
// project. All items must be checked before upload proceeds.
// See: US-FM-15, FILE_MANAGEMENT_AND_TEAMS_SYNC.md §Compliance Constraints

import SwiftUI

struct ComplianceChecklistView: View {
    @State private var checks: [Bool] = Array(repeating: false, count: 6)
    @State private var confirmed = false
    @Environment(\.dismiss) private var dismiss

    private let items = [
        "Deltakerne er informert om innsiktsarbeidet og har gitt gyldig samtykke.",
        "Ingen deltakere med kode 6 eller 7 er inkludert i datamaterialet.",
        "Ingen deltakere under 18 år er inkludert.",
        "Lydopptak er godkjent gjennom risikovurdering og annen relevant dokumentasjon.",
        "Ingen video eller bilder av deltakere er inkludert.",
        "En datahåndteringsplan er på plass og oppdatert.",
    ]

    private var allChecked: Bool { checks.allSatisfy { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            Text("Bekreft at kravene er oppfylt")
                .font(.system(size: 18, weight: .semibold))

            Text("Før data kan lastes opp til Teams, må du bekrefte at følgende krav fra NAVs rutine for midlertidig lagring av innsiktsdata (PVK 25/35628) er oppfylt:")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ForEach(items.indices, id: \.self) { index in
                    Toggle(isOn: $checks[index]) {
                        Text(items[index])
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(AppSpacing.lg)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )

            HStack {
                Spacer()

                if confirmed {
                    Label("Bekreftet", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                }

                Button {
                    confirmCompliance()
                } label: {
                    Text("Bekreft og godkjenn")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allChecked)
            }

            Text("Denne bekreftelsen gjelder for hele prosjektet og vises ikke igjen med mindre prosjektkonfigurasjonen endres.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.xl)
        .frame(minWidth: 520)
    }

    private func confirmCompliance() {
        let state = AppStateStore.load()
        let projectId = state.currentProject?.projectName ?? "unknown"

        _ = try? AppStateStore.update { s in
            s.currentProject?.complianceConfirmedAt = Date()
        }

        AuditLogger.shared.logComplianceCheckConfirmed(projectId: projectId)
        confirmed = true
    }
}
