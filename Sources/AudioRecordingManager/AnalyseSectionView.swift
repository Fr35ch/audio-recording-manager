// AnalyseSectionView.swift
// AudioRecordingManager
//
// LLM analysis state machine + UI for the transcript editor.
// Moved from RecordingDetailView per RECORDING_DETAIL_VIEW.md.
//
// Runs against the saved (on-disk) transcript text via Ollama.
// isDirty gates the button. Ollama must be running.

import SwiftUI

private enum AnalysisState: Equatable {
    case idle
    case running
    case completed(String)
    case failed(String)
}

struct AnalyseSectionView: View {
    let recordingId: UUID
    let isDirty: Bool

    @State private var state: AnalysisState = .idle
    @State private var task: Task<Void, Never>?
    @State private var ollamaRunning = false
    @AppStorage("analysis.llmModel") private var llmModel = "qwen3:8b"

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Analyse")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                switch state {
                case .idle:
                    idleView
                case .running:
                    runningView
                case .completed(let text):
                    completedView(text: text)
                case .failed(let error):
                    failedView(error: error)
                }
            }
            .padding(AppSpacing.lg)
            .background(Color.gray.opacity(0.04))
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
        .onAppear {
            checkOllama()
            loadExistingResult()
        }
    }

    // MARK: - States

    private var idleView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Button { runAnalysis() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Analyser transkripsjon")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDirty || !ollamaRunning)
            .help(
                isDirty
                    ? "Lagre endringer før analyse"
                    : (!ollamaRunning ? "Ollama er ikke kjørende — start Ollama og prøv igjen" : "")
            )

            Text("Modell: \(llmModel)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var runningView: some View {
        VStack(spacing: AppSpacing.md) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Analyserer med \(llmModel)...")
                    .font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity)

            Button {
                task?.cancel()
                task = nil
                state = .idle
            } label: {
                Text("Avbryt")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    private func completedView(text: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text("Analyse fullført")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.success)
            }

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { state = .idle } label: {
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

    private func failedView(error: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.destructive)
                Text("Analysefeil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.destructive)
            }

            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button { runAnalysis() } label: {
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

    // MARK: - Logic

    private func checkOllama() {
        ollamaRunning = OllamaManager.shared.isRunning()
    }

    private func loadExistingResult() {
        let url = StorageLayout.analysisURL(id: recordingId)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url),
              let result = try? decoder.decode(AnalysisResult.self, from: data) else { return }
        state = .completed(result.rawMarkdown)
    }

    private func runAnalysis() {
        // Load the transcription result JSON to pass to the analysis service
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jsonURL = support.appendingPathComponent("AudioRecordingManager/transcripts/\(recordingId.uuidString).json")
        guard let jsonData = try? Data(contentsOf: jsonURL) else {
            state = .failed("Ingen transkripsjon funnet")
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let transcriptionResult = try? decoder.decode(TranscriptionResult.self, from: jsonData) else {
            state = .failed("Kunne ikke lese transkripsjonsfil")
            return
        }

        state = .running

        // Auto-start Ollama if needed
        if !OllamaManager.shared.isRunning() {
            OllamaManager.shared.startServer()
        }

        task = Task {
            do {
                let audioURL = StorageLayout.audioURL(id: recordingId)
                let analysis = try await TranscriptionService.shared.analyze(
                    audioFile: audioURL,
                    existingResult: transcriptionResult,
                    llmModel: llmModel
                )

                await MainActor.run {
                    // Persist
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    if let data = try? encoder.encode(analysis) {
                        let url = StorageLayout.analysisURL(id: recordingId)
                        try? data.write(to: url, options: .atomic)
                    }

                    AuditLogger.shared.log(.transcriptAnalysed, payload: [
                        "recordingId": .string(recordingId.uuidString),
                        "model": .string(llmModel),
                    ])

                    state = .completed(analysis.rawMarkdown)
                }
            } catch {
                await MainActor.run {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
