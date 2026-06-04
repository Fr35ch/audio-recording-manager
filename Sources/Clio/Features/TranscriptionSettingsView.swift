import SwiftUI

// MARK: - Settings View

/// Settings panel for no-transcribe configuration.
/// Shows installation status, model selection, and per-run defaults.
struct TranscriptionSettingsView: View {
    @ObservedObject private var service = TranscriptionService.shared

    // Persisted defaults
    @AppStorage("transcription.defaultModel")   private var defaultModelRaw = TranscriptionModel.large.rawValue
    @AppStorage("transcription.defaultSpeakers") private var defaultSpeakers = 2
    @AppStorage("transcription.verbatim")        private var verbatim = false
    @AppStorage("transcription.language")        private var language = "no"
    @AppStorage("transcription.validateMode")    private var validateMode = "warn"
    @AppStorage("transcription.numBeams")        private var numBeams = 3
    // Transient UI state
    @State private var installState: ActionState = .idle
    @State private var updateState: ActionState = .idle
    @State private var downloadState: ActionState = .idle
    @State private var downloadingModel: TranscriptionModel?
    @State private var versionString: String? = nil

    private var defaultModel: Binding<TranscriptionModel> {
        Binding(
            get: { TranscriptionModel(rawValue: defaultModelRaw) ?? .medium },
            set: { defaultModelRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                installSection
                Divider()
                modelSection
                Divider()
                defaultsSection
            }
            .padding(24)
        }
        .frame(width: 480)
        .onAppear { loadVersion() }
    }

    // MARK: - Install section

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Installasjon", systemImage: "wrench.and.screwdriver")

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Status row
                    HStack(spacing: 8) {
                        Image(systemName: service.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(service.isInstalled ? .green : .red)
                        Text(service.isInstalled ? "no-transcribe er installert" : "no-transcribe er ikke installert")
                            .font(.system(size: 13, weight: .medium))

                        if let ver = versionString {
                            Text("(\(ver))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    // Install / Update buttons
                    HStack(spacing: 8) {
                        if !service.isInstalled {
                            ActionButton(
                                label: "Installer",
                                systemImage: "arrow.down.circle",
                                state: installState
                            ) {
                                performInstall()
                            }
                        } else {
                            ActionButton(
                                label: "Oppdater",
                                systemImage: "arrow.triangle.2.circlepath",
                                state: updateState
                            ) {
                                performUpdate()
                            }
                        }
                    }

                    if !service.isInstalled {
                        Text("Krever Python 3.9+ og internettilgang for nedlasting av pakken.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    // MARK: - Model section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Modellstørrelser", systemImage: "cpu")

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Last ned modellvekter lokalt for raskere oppstart. Vektene lagres i ~/.cache/huggingface.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(TranscriptionModel.allCases) { model in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(model.displayName)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(model.estimatedRAM)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                }
                                Text(model.modelDescription)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if downloadingModel == model && downloadState == .running {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.6)
                            } else {
                                Button("Last ned") {
                                    performDownload(model)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!service.isInstalled || downloadState == .running)
                                .font(.system(size: 12))
                            }
                        }
                        if model != TranscriptionModel.allCases.last {
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    // MARK: - Defaults section

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Standardinnstillinger", systemImage: "slider.horizontal.3")

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {

                    // Default model picker
                    LabeledContent("Standard modell") {
                        Picker("", selection: defaultModel) {
                            ForEach(TranscriptionModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    Divider()

                    // Number of speakers — minimum is 2 because the
                    // diarization model would otherwise be told
                    // "exactly 1 cluster" and collapse all turns into
                    // a single speaker. For genuine monologue
                    // recordings, just don't run diarization.
                    LabeledContent("Antall talere") {
                        Stepper(value: $defaultSpeakers, in: 2...10) {
                            Text("\(defaultSpeakers)")
                                .monospacedDigit()
                                .frame(width: 24, alignment: .trailing)
                        }
                    }

                    Divider()

                    // Transkripsjonsformat
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Transkripsjonsformat") {
                            Picker("", selection: $verbatim) {
                                Text("Renset").tag(false)
                                Text("Ordrett").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            if verbatim {
                                Text("Alle lyder skrives ned nøyaktig slik de ble sagt – fyllord (ehm, liksom), nøling og gjentakelser tas med.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Bruk dette når du analyserer talemønstre eller trenger fullstendig kilde.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Fyllord (ehm, liksom), nøling og gjentakelser fjernes automatisk. Gir flytende tekst klar for analyse.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Anbefalt for de fleste intervjuer.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppColors.accent.opacity(0.8))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    // Transcription precision
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Transkripsjonsnøyaktighet") {
                            Picker("", selection: $numBeams) {
                                Text("Raskest – mer manuell retting").tag(1)
                                Text("Rask – anbefalt").tag(2)
                                Text("Middels – god balanse").tag(3)
                                Text("Treg – høy nøyaktighet").tag(4)
                                Text("Svært treg – best mulig").tag(5)
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        Text(numBeamsDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    // Language picker
                    LabeledContent("Språk") {
                        Picker("", selection: $language) {
                            Text("Bokmål").tag("no")
                            Text("Nynorsk").tag("nn")
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    Divider()

                    // Validation mode
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Kvalitetskontroll") {
                            Picker("", selection: $validateMode) {
                                Text("Advar (anbefalt)").tag("warn")
                                Text("Merk usikre").tag("flag")
                                Text("Prøv på nytt").tag("retry")
                                Text("Av").tag("none")
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        Text(validateModeDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var numBeamsDescription: String {
        switch numBeams {
        case 1: return "Raskest mulig, men modellen tar snarveier og hopper over usikker tale. Forvent hyppigere feil som du må rette manuelt."
        case 2: return "Rask med god kvalitet. Anbefalt for de fleste intervjuer."
        case 3: return "Noe tregere, men fanger opp mer tvetydig tale. Bra for opptak med mye bakgrunnsstøy eller sterke dialekter."
        case 4: return "Treg. Brukes til opptak der nøyaktighet er viktigere enn ventetid."
        case 5: return "Svært treg (3–5× lenger enn rask). Bruk kun når du absolutt trenger best mulig resultat."
        default: return ""
        }
    }

    private var validateModeDescription: String {
        switch validateMode {
        case "warn":  return "Logger potensielle problemer (hull, gjentakelser, hallusinasjoner) til diagnoseloggen uten å endre resultatet."
        case "flag":  return "Markerer usikre segmenter i JSON-utdataene. Disse kan vises dempet i editoren."
        case "retry": return "Transkriberer usikre regioner på nytt med høyere beam-bredde (saktere, men mer nøyaktig)."
        case "none":  return "Ingen kvalitetskontroll kjøres etter transkripsjon."
        default:      return ""
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

    private func loadVersion() {
        guard service.isInstalled else { return }
        Task {
            // Run `no-transcribe --version` via a quick shell invocation
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-lc", "no-transcribe --version 2>/dev/null || echo ''"]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let ver = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                versionString = ver?.isEmpty == false ? ver : nil
            }
        }
    }

    private func performInstall() {
        installState = .running
        Task {
            do {
                try await service.install()
                await MainActor.run { installState = .success }
                loadVersion()
            } catch {
                await MainActor.run { installState = .failed(error.localizedDescription) }
            }
        }
    }

    private func performUpdate() {
        updateState = .running
        Task {
            do {
                try await service.update()
                await MainActor.run { updateState = .success }
                loadVersion()
            } catch {
                await MainActor.run { updateState = .failed(error.localizedDescription) }
            }
        }
    }

    private func performDownload(_ model: TranscriptionModel) {
        downloadingModel = model
        downloadState = .running
        Task {
            do {
                try await service.downloadModel(model)
                await MainActor.run { downloadState = .success }
            } catch {
                await MainActor.run { downloadState = .failed(error.localizedDescription) }
            }
            await MainActor.run { downloadingModel = nil }
        }
    }
}

// MARK: - Action state

private enum ActionState: Equatable {
    case idle
    case running
    case success
    case failed(String)
}

// MARK: - Action Button

private struct ActionButton: View {
    let label: String
    let systemImage: String
    let state: ActionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch state {
                case .idle, .failed:
                    Image(systemName: systemImage)
                    Text(label)
                case .running:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.65)
                    Text(label + "...")
                case .success:
                    Image(systemName: "checkmark")
                    Text("Fullført")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state == .running)
    }
}
