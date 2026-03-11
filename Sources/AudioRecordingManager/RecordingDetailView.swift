import SwiftUI

// MARK: - Anonymization UI state

private enum AnonymizationUIState {
    case notStarted
    case inProgress
    case completed(date: Date, stats: [String: Int])
    case failed(AnonymizationError)
}

// MARK: - Transcription UI state

private enum TranscriptionUIState {
    case notStarted
    case inProgress
    case completed(TranscriptionResult)
    case failed(TranscriptionError)
}

// MARK: - Recording Detail View

/// Sheet showing playback, transcription and anonymization controls for a single recording.
struct RecordingDetailView: View {
    let recording: RecordingItem
    let onDismiss: () -> Void

    @ObservedObject var audioPlayer: AudioPlayer = .shared

    @State private var metadata: RecordingMetadata? = nil
    @State private var transcriptDraft: String = ""
    @State private var anonymizationState: AnonymizationUIState = .notStarted
    @State private var showAnonymizationModal = false
    @State private var showOriginal: Bool = true
    @State private var anonymizationTask: Task<Void, Never>? = nil
    @State private var startTime: Date? = nil

    // Transcription state
    @ObservedObject private var transcriptionService = TranscriptionService.shared
    @State private var transcriptionState: TranscriptionUIState = .notStarted
    @State private var transcriptionTask: Task<Void, Never>? = nil
    @State private var showTranscriptionResult = false
    @AppStorage("transcription.defaultModel")    private var defaultModelRaw = TranscriptionModel.large.rawValue
    @AppStorage("transcription.defaultSpeakers") private var defaultSpeakers = 2
    @AppStorage("transcription.verbatim")        private var verbatim = false
    @AppStorage("transcription.language")        private var language = "no"

    // Scrubber state
    @State private var scrubberProgress: Double = 0
    @State private var isDraggingScrubber = false
    @State private var scrubberTimer: Timer? = nil

    private var isCurrentFile: Bool {
        audioPlayer.currentPlayingURL == URL(fileURLWithPath: recording.path)
    }

    private var hasTranscript: Bool { metadata?.originalTranscript != nil }
    private var hasAnonymized: Bool { metadata?.anonymizedTranscript != nil }

    // Displayed scrubber position (use dragging value when dragging, else live playback)
    private var displayedProgress: Double {
        if isDraggingScrubber { return scrubberProgress }
        return isCurrentFile ? audioPlayer.playbackProgress : 0
    }

    private var displayedCurrentTime: TimeInterval {
        displayedProgress * audioPlayer.duration
    }

    private var redAccent: Color {
        Color(red: 200 / 255, green: 16 / 255, blue: 46 / 255)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                playbackSection
                transcriptionButtonSection
                if case .completed(let result) = transcriptionState {
                    transcriptionResultSection(result: result)
                } else if case .inProgress = transcriptionState {
                    transcriptionProgressSection
                } else if case .failed(let error) = transcriptionState {
                    transcriptionErrorSection(error: error)
                }
                if hasTranscript {
                    anonymizationSection
                }
                transcriptSection
                fileInfoSection
            }
            .padding(32)
        }
        .frame(width: 560)
        .onAppear {
            loadMetadata()
            startScrubberTimer()
        }
        .onDisappear {
            anonymizationTask?.cancel()
            transcriptionTask?.cancel()
            scrubberTimer?.invalidate()
            scrubberTimer = nil
        }
        .sheet(isPresented: $showAnonymizationModal) {
            AnonymizationModal(isPresented: $showAnonymizationModal, onConfirm: startAnonymization)
        }
        .sheet(isPresented: $showTranscriptionResult) {
            if case .completed(let result) = transcriptionState {
                transcriptionResultSheet(result: result)
            }
        }
    }

    private func transcriptionResultSheet(result: TranscriptionResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transkripsjon")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Lukk") { showTranscriptionResult = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            TranscriptionResultView(result: result)
        }
        .frame(width: 680, height: 560)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(redAccent)

            Text(recording.filename)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Playback section

    private var playbackSection: some View {
        VStack(spacing: 14) {
            // Play/pause and restart row
            HStack(spacing: 16) {
                // Restart button
                Button(action: {
                    if isCurrentFile {
                        audioPlayer.restart()
                    } else {
                        audioPlayer.play(url: URL(fileURLWithPath: recording.path))
                    }
                }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(redAccent)
                }
                .buttonStyle(.plain)
                .help("Start på nytt")

                // Play / Pause button
                Button(action: {
                    let url = URL(fileURLWithPath: recording.path)
                    if isCurrentFile {
                        audioPlayer.togglePlayPause()
                    } else {
                        audioPlayer.play(url: url)
                    }
                }) {
                    Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46, weight: .thin))
                        .foregroundStyle(redAccent)
                }
                .buttonStyle(.plain)
                .help(isCurrentFile && audioPlayer.isPlaying ? "Pause" : "Spill av")
            }

            // Scrubber
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { displayedProgress },
                        set: { newValue in
                            scrubberProgress = newValue
                            isDraggingScrubber = true
                        }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            // Committed — seek
                            if isCurrentFile {
                                audioPlayer.seek(to: scrubberProgress)
                            } else {
                                // Start playing from that position
                                let url = URL(fileURLWithPath: recording.path)
                                audioPlayer.play(url: url)
                                audioPlayer.seek(to: scrubberProgress)
                            }
                            isDraggingScrubber = false
                        }
                    }
                )
                .accentColor(redAccent)

                // Timestamps
                HStack {
                    Text(formatTime(displayedCurrentTime))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(recording.formattedDuration)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(AppRadius.large)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Transcription button section (state A — not started)

    private var transcriptionButtonSection: some View {
        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .medium
        return VStack(alignment: .leading, spacing: 12) {
            Text("Transkripsjon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                Button(action: startTranscription) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.and.mic")
                        Text("Transkriber lydfil automatisk")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(redAccent)
                .disabled(!transcriptionService.isInstalled)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        Label("Modell: \(model.displayName)", systemImage: "cpu")
                        Label("\(defaultSpeakers) taler\(defaultSpeakers == 1 ? "" : "e")", systemImage: "person.2")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                    if !transcriptionService.isInstalled {
                        Label("no-transcribe er ikke installert. Åpne innstillinger for å installere.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: - Transcription in progress

    private var transcriptionProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkripsjon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.75)
                    Text(transcriptionService.stage.displayName.isEmpty
                         ? "Forbereder..."
                         : transcriptionService.stage.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .animation(.default, value: transcriptionService.stage.displayName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if transcriptionService.progress > 0 {
                    ProgressView(value: transcriptionService.progress)
                        .progressViewStyle(.linear)
                        .animation(.easeInOut(duration: 0.4), value: transcriptionService.progress)
                }

                Text("NB-Whisper-modellen lastes ved første kjøring – dette kan ta et minutt.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: cancelTranscription) {
                    Text("Avbryt")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: - Transcription result

    private func transcriptionResultSection(result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkripsjon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                    Text("Transkripsjon fullført")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColors.success)
                }

                HStack(spacing: 16) {
                    Label("\(result.segments.count) segmenter", systemImage: "text.quote")
                    Label("\(result.numSpeakers) taler\(result.numSpeakers == 1 ? "" : "e")", systemImage: "person.2")
                    Label(formattedDuration(result.durationSeconds), systemImage: "clock")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(action: { showTranscriptionResult = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.rectangle")
                            Text("Vis segmenter")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(redAccent)

                    Button(action: startTranscription) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Kjør på nytt")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: - Transcription error

    private func transcriptionErrorSection(error: TranscriptionError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkripsjon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.destructive)
                    Text("Feil ved transkripsjon")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.destructive)
                }

                Text(error.errorDescription ?? "Ukjent feil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: startTranscription) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Prøv igjen")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: - Transcript Section

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let original = metadata?.originalTranscript {
                // Transcript stored — show it (read-only)
                transcriptContent(
                    text: (showOriginal ? original : metadata?.anonymizedTranscript) ?? original,
                    isAnonymized: !showOriginal && hasAnonymized
                )
            } else {
                // No transcript yet — show paste-in editor
                transcriptInputArea
            }
        }
    }

    private func transcriptContent(text: String, isAnonymized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isAnonymized {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.success)
                    Text("Anonymisert versjon")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.success)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }

            Text(text)
                .font(.system(size: 13, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(isAnonymized ? AppColors.success.opacity(0.05) : Color.gray.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .stroke(
                    isAnonymized ? AppColors.success.opacity(0.25) : Color.gray.opacity(0.2),
                    lineWidth: 1
                )
        )
        .cornerRadius(AppRadius.medium)
    }

    private var transcriptInputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lim inn transkripsjon manuelt, eller bruk «Transkriber» ovenfor:")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)

            TextEditor(text: $transcriptDraft)
                .font(.system(size: 13))
                .frame(minHeight: 140)
                .padding(8)
                .background(Color.gray.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .cornerRadius(AppRadius.medium)

            Button(action: saveTranscript) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Lagre transkripsjon")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(redAccent)
            .disabled(transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Anonymization Section

    private var anonymizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anonymisering")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 16) {
                switch anonymizationState {
                case .notStarted:
                    stateA
                case .inProgress:
                    stateB
                case .completed(let date, let stats):
                    stateC(date: date, stats: stats)
                case .failed(let error):
                    stateD(error: error)
                }
            }
            .padding(16)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // State A — not yet anonymized
    private var stateA: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { showAnonymizationModal = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                    Text("Anonymiser transkripsjon")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(redAccent)

            VStack(alignment: .leading, spacing: 6) {
                Text("Hva som fjernes:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(whatIsRemoved, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.warning)
                            .padding(.top, 1)
                        Text(item)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // State B — in progress
    private var stateB: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.75)
                Text("Anonymiserer...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)

            Text("NLP-modellen lastes ved første kjøring – dette kan ta noen sekunder.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button(action: cancelAnonymization) {
                Text("Avbryt")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    // State C — completed
    private func stateC(date: Date, stats: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(AppColors.success)
                Text("Anonymisert \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.success)
            }

            if !stats.isEmpty {
                Text(statsSummary(stats))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // Toggle original / anonymized
            HStack(spacing: 0) {
                toggleButton(label: "Original", icon: "doc.text", selected: showOriginal) {
                    showOriginal = true
                }
                toggleButton(label: "Anonymisert", icon: "shield.lefthalf.filled", selected: !showOriginal) {
                    showOriginal = false
                }
            }
            .background(Color.gray.opacity(0.1))
            .cornerRadius(AppRadius.medium)

            Button(action: { showAnonymizationModal = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Kjør på nytt")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    // State D — error
    private func stateD(error: AnonymizationError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                Text("Feil ved anonymisering")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.destructive)
            }

            Text(error.errorDescription ?? "Ukjent feil")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { showAnonymizationModal = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Prøv igjen")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Filinformasjon (bottom)

    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filinformasjon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                infoRow(label: "Filnavn", value: recording.filename)
                Divider().background(Color.gray.opacity(0.2))
                infoRow(label: "Dato", value: recording.formattedDate)
                Divider().background(Color.gray.opacity(0.2))
                infoRow(label: "Varighet", value: recording.formattedDuration)
                Divider().background(Color.gray.opacity(0.2))
                infoRow(label: "Størrelse", value: recording.formattedSize)
            }
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func toggleButton(
        label: String, icon: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.white : Color.clear)
            .foregroundStyle(selected ? redAccent : .secondary)
            .cornerRadius(AppRadius.small)
        }
        .buttonStyle(.plain)
    }

    private let whatIsRemoved = [
        "Navn på personer",
        "Telefonnumre og e-postadresser",
        "Fødselsnumre og d-numre",
        "Steds- og organisasjonsnavn (via NER)",
    ]

    private func statsSummary(_ stats: [String: Int]) -> String {
        let parts = stats.compactMap { (key, count) -> String? in
            guard count > 0 else { return nil }
            switch key {
            case "NAVN": return "\(count) \(count == 1 ? "navn" : "navn")"
            case "TELEFON": return "\(count) telefonnummer"
            case "FØDSELSNUMMER": return "\(count) fødselsnummer"
            case "D-NUMMER": return "\(count) d-nummer"
            case "EPOST": return "\(count) e-postadresse"
            case "ORG": return "\(count) organisasjon"
            case "STED": return "\(count) stedsnavn"
            default: return "\(count) \(key.lowercased())"
            }
        }
        if parts.isEmpty { return "Ingen identifiserende informasjon funnet" }
        return parts.joined(separator: ", ") + " fjernet"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = Int(seconds) % 3600 / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Scrubber timer

    private func startScrubberTimer() {
        scrubberTimer?.invalidate()
        scrubberTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            guard !isDraggingScrubber else { return }
            // Force a view update to reflect live playback progress
            _ = audioPlayer.playbackProgress
        }
    }

    // MARK: - Actions

    private func loadMetadata() {
        let loaded = RecordingMetadataManager.shared.load(for: recording.path)
        metadata = loaded
        if let loaded = loaded, let date = loaded.anonymizationDate {
            anonymizationState = .completed(
                date: date, stats: loaded.anonymizationStats ?? [:]
            )
        }
    }

    private func saveTranscript() {
        let text = transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        RecordingMetadataManager.shared.setOriginalTranscript(text, for: recording.path)
        loadMetadata()
        transcriptDraft = ""
    }

    private func startAnonymization() {
        guard let transcript = metadata?.originalTranscript else { return }
        anonymizationTask?.cancel()
        anonymizationState = .inProgress
        startTime = Date()

        anonymizationTask = Task { @MainActor in
            do {
                let result = try await AnonymizationService.shared.anonymize(transcript: transcript)

                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(startTime ?? Date()) * 1000
                RecordingMetadataManager.shared.applyAnonymizationResult(result, for: recording.path)

                let stableId = URL(fileURLWithPath: recording.path)
                    .deletingPathExtension().lastPathComponent
                AuditLogger.shared.logAnonymization(
                    recordingId: stableId,
                    stats: result.stats,
                    processingTimeMs: elapsed,
                    outcome: .success
                )

                loadMetadata()
                anonymizationState = .completed(
                    date: Date(), stats: result.stats
                )
                showOriginal = false
            } catch let error as AnonymizationError {
                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(startTime ?? Date()) * 1000
                let stableId = URL(fileURLWithPath: recording.path)
                    .deletingPathExtension().lastPathComponent
                AuditLogger.shared.logAnonymization(
                    recordingId: stableId,
                    stats: nil,
                    processingTimeMs: elapsed,
                    outcome: .error,
                    errorMessage: error.errorDescription
                )
                anonymizationState = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                anonymizationState = .failed(.processFailed(error.localizedDescription))
            }
        }
    }

    private func cancelAnonymization() {
        anonymizationTask?.cancel()
        anonymizationTask = nil
        anonymizationState = .notStarted
    }

    // MARK: - Transcription actions

    private func startTranscription() {
        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .medium
        let audioURL = URL(fileURLWithPath: recording.path)

        transcriptionTask?.cancel()
        transcriptionState = .inProgress

        transcriptionTask = Task { @MainActor in
            do {
                let result = try await TranscriptionService.shared.transcribe(
                    audioFile: audioURL,
                    speakers: defaultSpeakers,
                    model: model,
                    verbatim: verbatim,
                    language: language
                )

                guard !Task.isCancelled else { return }

                // Build plain-text transcript for metadata + anonymization
                let plainText = result.segments
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n\n")

                // Persist transcript in metadata sidecar (no JSON export to tekstfiler)
                RecordingMetadataManager.shared.setOriginalTranscript(plainText, for: recording.path)

                // Save .txt transcript to ~/Desktop/tekstfiler/ (plain text only, no JSON)
                savePlainTextTranscript(plainText, audioURL: audioURL)

                transcriptionState = .completed(result)
                loadMetadata()
            } catch let error as TranscriptionError {
                guard !Task.isCancelled else { return }
                transcriptionState = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                transcriptionState = .failed(.processFailed(error.localizedDescription))
            }
        }
    }

    /// Save plain-text transcript to ~/Desktop/tekstfiler/<stem>.txt.
    /// Deliberately does NOT save a JSON file.
    private func savePlainTextTranscript(_ text: String, audioURL: URL) {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let tekstfilerURL = desktop.appendingPathComponent("tekstfiler")

        do {
            if !FileManager.default.fileExists(atPath: tekstfilerURL.path) {
                try FileManager.default.createDirectory(at: tekstfilerURL, withIntermediateDirectories: true)
            }
            let stem = audioURL.deletingPathExtension().lastPathComponent
            let txtURL = tekstfilerURL.appendingPathComponent("\(stem).txt")
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
            print("📄 Saved transcript: \(txtURL.lastPathComponent)")
        } catch {
            print("⚠️ Could not save transcript to tekstfiler: \(error)")
        }
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        TranscriptionService.shared.cancel()
        transcriptionState = .notStarted
    }
}
