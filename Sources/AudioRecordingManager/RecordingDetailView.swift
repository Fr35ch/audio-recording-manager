import SwiftUI

// MARK: - Transcription UI state

private enum TranscriptionUIState {
    case notStarted
    case inProgress
    case completed(TranscriptionResult)
    case failed(TranscriptionError)
}

// MARK: - Recording Detail View
//
// Redesigned per RECORDING_DETAIL_VIEW.md (2026-04-17):
//   - Playback, transcription trigger, diarization placeholder, file info
//   - Anonymization, analysis, transcript modal, Finder — removed (moved to TranscriptEditorView)

struct RecordingDetailView: View {
    let recording: RecordingItem
    let onDismiss: () -> Void
    var onNavigateToTranscript: ((UUID) -> Void)?

    @ObservedObject var audioPlayer: AudioPlayer = .shared

    // Transcription state
    @ObservedObject private var transcriptionService = TranscriptionService.shared
    @State private var transcriptionState: TranscriptionUIState = .notStarted
    @State private var transcriptionTask: Task<Void, Never>? = nil
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
                transcriptionSection
                diarizationSection
                fileInfoSection
            }
            .padding(32)
        }
        .frame(width: 560)
        .onAppear {
            restoreTranscriptionState()
            startScrubberTimer()
        }
        .onDisappear {
            transcriptionTask?.cancel()
            scrubberTimer?.invalidate()
            scrubberTimer = nil
        }
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

    // MARK: - Playback

    private var playbackSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Button {
                    if isCurrentFile {
                        audioPlayer.restart()
                    } else {
                        audioPlayer.play(url: URL(fileURLWithPath: recording.path))
                    }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(redAccent)
                }
                .buttonStyle(.plain)
                .help("Start på nytt")

                Button {
                    let url = URL(fileURLWithPath: recording.path)
                    if isCurrentFile {
                        audioPlayer.togglePlayPause()
                    } else {
                        audioPlayer.play(url: url)
                    }
                } label: {
                    Image(systemName: isCurrentFile && audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46, weight: .thin))
                        .foregroundStyle(redAccent)
                }
                .buttonStyle(.plain)
                .help(isCurrentFile && audioPlayer.isPlaying ? "Pause" : "Spill av")
            }

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
                            if isCurrentFile {
                                audioPlayer.seek(to: scrubberProgress)
                            } else {
                                let url = URL(fileURLWithPath: recording.path)
                                audioPlayer.play(url: url)
                                audioPlayer.seek(to: scrubberProgress)
                            }
                            isDraggingScrubber = false
                        }
                    }
                )
                .accentColor(redAccent)

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

    // MARK: - Transcription (4-state machine)

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkripsjon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                switch transcriptionState {
                case .notStarted:
                    transcriptionNotStarted
                case .inProgress:
                    transcriptionInProgress
                case .completed(let result):
                    transcriptionCompleted(result: result)
                case .failed(let error):
                    transcriptionFailed(error: error)
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

    private var transcriptionNotStarted: some View {
        let model = TranscriptionModel(rawValue: defaultModelRaw) ?? .medium
        return VStack(alignment: .leading, spacing: 12) {
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

    private var transcriptionInProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(transcriptionService.stage.displayName.isEmpty
                     ? "Forbereder..."
                     : transcriptionService.stage.displayName)
                    .font(.system(size: 14, weight: .medium))
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
    }

    private func transcriptionCompleted(result: TranscriptionResult) -> some View {
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
                Button {
                    onNavigateToTranscript?(recording.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text("Åpne i transkripsjonseditoren")
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
    }

    private func transcriptionFailed(error: TranscriptionError) -> some View {
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
    }

    // MARK: - Taleutskilling (diarization placeholder)

    private var diarizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Taleutskilling")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                Text("Identifiser hvem som snakker i opptaket")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Button {
                    // Placeholder — not functional yet
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.wave.2")
                        Text("Kjør taleutskilling")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(true)
                .help("Taleutskilling kommer i en fremtidig versjon av ARM")
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

    // MARK: - Filinformasjon

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
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

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

    private func startScrubberTimer() {
        scrubberTimer?.invalidate()
        scrubberTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            guard !isDraggingScrubber else { return }
            _ = audioPlayer.playbackProgress
        }
    }

    private func restoreTranscriptionState() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jsonURL = support.appendingPathComponent("AudioRecordingManager/transcripts/\(recording.id.uuidString).json")
        if let data = try? Data(contentsOf: jsonURL) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let result = try? decoder.decode(TranscriptionResult.self, from: data) {
                transcriptionState = .completed(result)
                return
            }
        }
        let txtURL = StorageLayout.transcriptURL(id: recording.id)
        if FileManager.default.fileExists(atPath: txtURL.path) {
            transcriptionState = .completed(TranscriptionResult(
                version: "1.0", model: "ukjent", language: "no",
                durationSeconds: 0, numSpeakers: 1,
                segments: [], metadata: TranscriptionResultMetadata(
                    inputFile: recording.path, processingTimeSeconds: 0,
                    modelVariant: "ukjent", computeType: "ukjent",
                    device: "ukjent", diarizationRun: nil
                )
            ))
        }
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

                let plainText = result.segments
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n\n")

                let transcriptURL = StorageLayout.transcriptURL(id: recording.id)
                try? plainText.write(to: transcriptURL, atomically: true, encoding: .utf8)
                _ = try? RecordingStore.shared.updateMeta(id: recording.id) { meta in
                    meta.transcript.status = .done
                    meta.transcript.completedAt = Date()
                }

                TranscriptionService.shared.saveTranscriptJSONPublic(result, recordingId: recording.id)

                transcriptionState = .completed(result)
            } catch let error as TranscriptionError {
                guard !Task.isCancelled else { return }
                transcriptionState = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                transcriptionState = .failed(.processFailed(error.localizedDescription))
            }
        }
    }

    private func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        TranscriptionService.shared.cancel()
        transcriptionState = .notStarted
    }
}
