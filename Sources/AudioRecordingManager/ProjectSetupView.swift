// ProjectSetupView.swift
// AudioRecordingManager
//
// Project configuration screen. The researcher sets project name,
// Teams channel references, and neutral code format.
// See: US-FM-13, US-FM-14

import SwiftUI

struct ProjectSetupView: View {
    @State private var appState = AppStateStore.load()
    @State private var projectName: String = ""
    @State private var neutralCodePrefix: String = "D"

    // Study channel
    @State private var studyChannelName: String = ""
    @State private var studyTeamId: String = ""
    @State private var studyChannelId: String = ""

    // Consent channel
    @State private var consentChannelName: String = ""
    @State private var consentTeamId: String = ""
    @State private var consentChannelId: String = ""

    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Prosjekt") {
                TextField("Prosjektnavn", text: $projectName)
                HStack {
                    Text("Deltakerkode-prefiks:")
                    TextField("D", text: $neutralCodePrefix)
                        .frame(width: 60)
                    Text("→ \(neutralCodePrefix)01, \(neutralCodePrefix)02, ...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Studiekanal (lyd, transkripsjoner, analyser)") {
                TextField("Kanalnavn", text: $studyChannelName)
                TextField("Team-ID (GUID)", text: $studyTeamId)
                    .font(.system(.body, design: .monospaced))
                TextField("Kanal-ID (GUID)", text: $studyChannelId)
                    .font(.system(.body, design: .monospaced))
                Text("Bruk en privat kanal som er ekskludert fra backup (jf. PVK 25/35628).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Samtykkekanal (samtykkeskjemaer — separat tilgang)") {
                TextField("Kanalnavn", text: $consentChannelName)
                TextField("Team-ID (GUID)", text: $consentTeamId)
                    .font(.system(.body, design: .monospaced))
                TextField("Kanal-ID (GUID)", text: $consentChannelId)
                    .font(.system(.body, design: .monospaced))
                Text("Bør ha strengere tilgang enn studiekanalen — ideelt kun studieansvarlig.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if studyTeamId == consentTeamId && studyChannelId == consentChannelId
                && !studyChannelId.isEmpty {
                Label("Studiekanal og samtykkekanal er den samme — dette anbefales ikke.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                    .font(.caption)
            }

            Section {
                Button {
                    saveProject()
                } label: {
                    Text("Lagre prosjektkonfigurasjon")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(projectName.isEmpty || studyChannelId.isEmpty)

                if saved {
                    Label("Lagret", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500)
        .onAppear { loadExisting() }
    }

    private func loadExisting() {
        guard let project = appState.currentProject else { return }
        projectName = project.projectName
        neutralCodePrefix = project.neutralCodePrefix
        if let ch = project.studyChannel {
            studyChannelName = ch.displayName
            studyTeamId = ch.teamId
            studyChannelId = ch.channelId
        }
        if let ch = project.consentChannel {
            consentChannelName = ch.displayName
            consentTeamId = ch.teamId
            consentChannelId = ch.channelId
        }
    }

    private func saveProject() {
        let study = TeamsChannelRef(
            displayName: studyChannelName,
            teamId: studyTeamId.trimmingCharacters(in: .whitespacesAndNewlines),
            channelId: studyChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let consent: TeamsChannelRef? = consentChannelId.isEmpty ? nil : TeamsChannelRef(
            displayName: consentChannelName,
            teamId: consentTeamId.trimmingCharacters(in: .whitespacesAndNewlines),
            channelId: consentChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let existing = appState.currentProject
        let config = ProjectConfig(
            projectName: projectName,
            studyChannel: study,
            consentChannel: consent,
            neutralCodePrefix: neutralCodePrefix.isEmpty ? "D" : neutralCodePrefix,
            configuredAt: Date(),
            complianceConfirmedAt: existing?.complianceConfirmedAt,
            nextNeutralCodeNumber: existing?.nextNeutralCodeNumber ?? 1
        )

        _ = try? AppStateStore.update { state in
            state.currentProject = config
        }
        appState = AppStateStore.load()
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
