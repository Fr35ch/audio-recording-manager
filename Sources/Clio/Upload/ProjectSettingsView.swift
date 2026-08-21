import SwiftUI

/// Project configuration UI: create/edit/select `ProjectConfig`s (name,
/// neutral code prefix, study + consent Teams channels) and manage the
/// Microsoft sign-in used for Teams/SharePoint upload.
///
/// This UI did not exist before — `AppState.projects`/`TeamsChannelRef`
/// were pure data models with no editor. Channel selection is always
/// manual entry (Team ID + Channel ID pasted in by the researcher); the
/// granted Graph scopes don't support a "browse my Teams" picker.
struct ProjectSettingsView: View {
    @ObservedObject private var authService = GraphAuthService.shared

    @State private var projects: [ProjectConfig] = AppStateStore.load().projects
    @State private var selectedProjectId: UUID?
    @State private var errorMessage: String?
    @State private var isResolvingChannel = false
    @State private var channelAgeNotice: String?

    // Draft fields for the selected project's study channel — edited in
    // a local buffer, only written back to AppState on explicit Save.
    @State private var draftDisplayName = ""
    @State private var draftTeamId = ""
    @State private var draftChannelId = ""

    private var selectedProject: ProjectConfig? {
        projects.first(where: { $0.id == selectedProjectId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            signInSection
            Divider()
            projectListSection
            Divider()
            if selectedProjectId != nil {
                studyChannelSection
            }
        }
        .padding(AppSpacing.xl)
        .frame(width: 520)
        .onAppear { syncDraftFromSelection() }
        .onChange(of: selectedProjectId) { _, _ in syncDraftFromSelection() }
    }

    // MARK: - Sign-in section

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader("Microsoft-pålogging", systemImage: "person.crop.circle.badge.checkmark")

            GroupBox {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: authService.signedIn ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(authService.signedIn ? .green : .secondary)

                    if authService.signedIn, let name = authService.accountDisplayName {
                        Text("Logget inn som \(name)")
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Text("Ikke logget inn")
                            .font(.system(size: 13, weight: .medium))
                    }

                    Spacer()

                    Button(authService.signedIn ? "Logg ut" : "Logg inn") {
                        Task { await toggleSignIn() }
                    }
                    .buttonStyle(HoverButtonStyle())
                }
                .padding(AppSpacing.sm)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func toggleSignIn() async {
        errorMessage = nil
        do {
            if authService.signedIn {
                try authService.signOut()
            } else {
                try await authService.signInInteractive()
            }
        } catch {
            print("🔑 ProjectSettingsView.toggleSignIn: caught error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Project list

    private var projectListSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader("Prosjekter", systemImage: "folder.badge.gearshape")

            if projects.isEmpty {
                Text("Ingen prosjekter konfigurert ennå.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(projects) { project in
                Button {
                    selectedProjectId = project.id
                } label: {
                    HStack {
                        Text(project.projectName.isEmpty ? "(Uten navn)" : project.projectName)
                        Spacer()
                        if project.isReadyForUpload {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.xs)
                    .background(
                        selectedProjectId == project.id
                            ? AppColors.accent.opacity(0.12) : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                }
                .buttonStyle(.plain)
            }

            Button(AppCopy.Common.add + " nytt prosjekt") {
                addProject()
            }
            .buttonStyle(HoverButtonStyle())
        }
    }

    private func addProject() {
        var newProject = ProjectConfig()
        newProject.projectName = "Nytt prosjekt"
        projects.append(newProject)
        selectedProjectId = newProject.id
        persistProjects()
    }

    // MARK: - Study channel section

    private var studyChannelSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader("Studiekanal (Teams)", systemImage: "person.2.badge.gearshape")

            Text("""
            Lim inn Team-ID og Kanal-ID for den private, sikkerhetskopi-utelukkede \
            Teams-kanalen som er satt opp for dette prosjektet. ARM oppretter aldri \
            kanaler selv.
            """)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Prosjektnavn") {
                TextField("", text: projectNameBinding)
            }

            TextField("Visningsnavn (f.eks. «Studie Bærekraft Q2»)", text: $draftDisplayName)
            TextField("Team-ID (GUID)", text: $draftTeamId)
            TextField("Kanal-ID (GUID)", text: $draftChannelId)

            if let notice = channelAgeNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(AppCopy.Common.save) {
                    Task { await saveStudyChannel() }
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(isResolvingChannel || draftTeamId.isEmpty || draftChannelId.isEmpty)
            }
        }
    }

    private func syncDraftFromSelection() {
        guard let project = selectedProject, let channel = project.studyChannel else {
            draftDisplayName = ""
            draftTeamId = ""
            draftChannelId = ""
            channelAgeNotice = nil
            return
        }
        draftDisplayName = channel.displayName
        draftTeamId = channel.teamId
        draftChannelId = channel.channelId
        channelAgeNotice = nil
    }

    /// Resolves the channel's drive/files-folder and estimates its
    /// creation date via `GraphClient`, then persists the result on the
    /// project's `TeamsChannelRef`. Surfaces the channel-age result
    /// immediately, at configuration time, rather than deferring it to
    /// the first upload attempt.
    private func saveStudyChannel() async {
        guard var project = selectedProject else { return }
        errorMessage = nil
        channelAgeNotice = nil
        isResolvingChannel = true
        defer { isResolvingChannel = false }

        do {
            let folder = try await GraphClient.shared.resolveChannelFilesFolder(
                teamId: draftTeamId, channelId: draftChannelId)
            let createdAt = try await GraphClient.shared.estimateChannelCreatedDate(
                teamId: draftTeamId, channelId: draftChannelId)

            var channel = TeamsChannelRef(
                displayName: draftDisplayName, teamId: draftTeamId, channelId: draftChannelId)
            channel.channelCreatedAt = createdAt
            channel.driveId = folder.driveId
            channel.filesFolderItemId = folder.itemId

            let ageCheck = try GraphClient.assertChannelAgeOK(createdAt: createdAt)
            if ageCheck == .unknown {
                channelAgeNotice = """
                Kunne ikke bekrefte når kanalen ble opprettet (ingen meldingshistorikk å \
                anslå ut fra). Vent minst 24 timer etter at kanalen ble opprettet før du \
                laster opp, av hensyn til utelukkelse fra sikkerhetskopiering.
                """
            }

            project.studyChannel = channel
            updateProjectInList(project)
            persistProjects()
        } catch GraphAPIError.channelTooNew(let createdAt, let hoursRemaining) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.locale = Locale(identifier: "nb_NO")
            channelAgeNotice = """
            Kanalen ble opprettet \(formatter.string(from: createdAt)) — vent ca. \
            \(Int(hoursRemaining.rounded(.up))) time(r) til før du kan bruke den, av \
            hensyn til utelukkelse fra sikkerhetskopiering.
            """
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateProjectInList(_ updated: ProjectConfig) {
        guard let idx = projects.firstIndex(where: { $0.id == updated.id }) else { return }
        projects[idx] = updated
    }

    /// Two-way binding to the selected project's `projectName`, writing
    /// back through `updateProjectInList` + `persistProjects` on every
    /// edit (matches the simple, non-debounced persistence style already
    /// used elsewhere in this file for the channel fields).
    private var projectNameBinding: Binding<String> {
        Binding(
            get: { selectedProject?.projectName ?? "" },
            set: { newValue in
                guard var project = selectedProject else { return }
                project.projectName = newValue
                updateProjectInList(project)
                persistProjects()
            }
        )
    }

    private func persistProjects() {
        do {
            _ = try AppStateStore.update { $0.projects = projects }
        } catch {
            errorMessage = "Kunne ikke lagre prosjektinnstillinger: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
