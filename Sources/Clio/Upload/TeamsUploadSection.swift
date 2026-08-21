// TeamsUploadSection.swift
// Clio
//
// Upload widget shown in RecordingDetailView's right panel after transcription.
// Gate: transcript must exist AND researcher must have confirmed de-identification.
// Real Microsoft Graph upload — see TeamsUploadService.performGraphUpload
// and GraphClient. Tapping "Last opp til Teams" signs the researcher in
// (if needed) and then presents UploadConfirmationSheet so they pick which
// project this specific recording belongs to — researchers can be working
// on several projects at once, so this is a per-recording choice, not a
// single app-wide setting. The chosen project is persisted onto
// RecordingMeta.projectId (pre-selected, but always changeable, next time).

import SwiftUI

struct TeamsUploadSection: View {

    let recording: RecordingMeta

    @StateObject private var uploadService = TeamsUploadService.shared
    @ObservedObject private var authService = GraphAuthService.shared
    @State private var configurationErrorMessage: String?
    @State private var isSigningIn = false
    @State private var showingProjectPicker = false

    private var readiness: UploadReadiness {
        UploadGate.evaluate(recording: recording)
    }

    /// All configured projects the researcher can choose between when
    /// uploading this recording (a researcher may work on several projects
    /// at once, and each recording can belong to a different one).
    private var availableProjects: [ProjectConfig] {
        AppStateStore.load().projects
    }

    var body: some View {
        sectionBody
            .alert(
                "Kan ikke laste opp",
                isPresented: Binding(
                    get: { configurationErrorMessage != nil },
                    set: { if !$0 { configurationErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(configurationErrorMessage ?? "")
            }
            .sheet(isPresented: $showingProjectPicker) {
                UploadConfirmationSheet(
                    recording: recording,
                    projects: availableProjects,
                    onConfirmed: { project, remoteName in
                        showingProjectPicker = false
                        assignProjectAndUpload(project: project, remoteName: remoteName)
                    },
                    onCancel: { showingProjectPicker = false }
                )
            }
    }

    // MARK: - State machine

    @ViewBuilder
    private var sectionBody: some View {
        let r = readiness
        if case .uploading = r {
            uploadingView
        } else if case .alreadyUploaded(let uploadedAt, let remoteName) = r {
            uploadedView(uploadedAt: uploadedAt, remoteName: remoteName)
        } else if case .uploadFailed(let remoteName) = r {
            failedView(remoteName: remoteName)
        } else if case .ready(let remoteName) = r {
            readyView(remoteName: remoteName)
        } else if case .blockedNoTranscript = r {
            blockedView(
                icon: "waveform.and.mic",
                iconColor: .secondary,
                title: "Ingen transkripsjon",
                message: "Transkriber opptaket for å aktivere opplasting til Teams."
            )
        } else if case .blockedNotConfirmed = r {
            blockedView(
                icon: "lock.shield",
                iconColor: AppColors.accent,
                title: "Avidentifisering ikke bekreftet",
                message: "Bekreft avidentifisering i seksjonen over for å aktivere opplasting."
            )
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

    private func readyView(remoteName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                    .font(.system(size: 14))
                Text("Klar for opplasting")
                    .font(.system(size: 13, weight: .medium))
            }
            Text(remoteName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button {
                beginUploadFlow()
            } label: {
                if isSigningIn {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Logger inn…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Last opp til Teams")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PillButtonStyle(variant: .primary))
            .disabled(isSigningIn)
        }
    }

    private var uploadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Laster opp…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uploadedView(uploadedAt: Date, remoteName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text("Lastet opp")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.success)
            }
            Text(remoteName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Lastet opp \(uploadedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func failedView(remoteName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppColors.destructive)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Opplasting feilet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Kontroller nettverkstilkobling og prøv igjen.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Button("Prøv igjen") {
                beginUploadFlow()
            }
            .buttonStyle(PillButtonStyle(variant: .primary))
        }
    }

    // MARK: - Actions

    /// Entry point for "Last opp til Teams" / "Prøv igjen". If the
    /// researcher isn't signed in to Microsoft yet, signs in first (same
    /// button, no separate "Logg inn" state) and only then shows the
    /// project picker — signing in and picking a project are two steps of
    /// one flow, not two separate actions the researcher has to trigger.
    private func beginUploadFlow() {
        guard !isSigningIn else { return }
        if authService.signedIn {
            showingProjectPicker = true
            return
        }
        isSigningIn = true
        Task {
            do {
                try await authService.signInInteractive()
                isSigningIn = false
                showingProjectPicker = true
            } catch {
                print("🔑 TeamsUploadSection.beginUploadFlow: caught error: \(error)")
                isSigningIn = false
                configurationErrorMessage = error.localizedDescription
            }
        }
    }

    /// Persists the researcher's chosen project onto this recording (so
    /// it's pre-selected — but still changeable — next time), then starts
    /// the actual Graph upload. A researcher can be working on several
    /// projects at once, so this choice is per-recording, not app-wide.
    private func assignProjectAndUpload(project: ProjectConfig, remoteName: String) {
        do {
            try RecordingStore.shared.updateMeta(id: recording.id) { $0.projectId = project.id }
        } catch {
            print("⚠️ TeamsUploadSection: could not persist projectId for \(recording.id): \(error)")
        }
        Task {
            await uploadService.upload(recording: recording, project: project, remoteName: remoteName)
        }
    }
}
