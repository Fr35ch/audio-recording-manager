import Foundation
import SwiftUI

struct TranscriptEditorWindow: View {
    let recordingId: UUID

    @State private var loadState: LoadState = .loading

    private enum LoadState {
        case loading
        case ready(TranscriptionResult, URL, String)
        case missingJSON(String)
        case missingAudio(String)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("Laster transkripsjon …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case let .ready(result, audioURL, displayName):
                TranscriptEditorView(
                    recordingId: recordingId,
                    audioURL: audioURL,
                    transcriptionResult: result
                )
                .navigationTitle(displayName)

            case let .missingJSON(displayName):
                fallback(
                    title: "Transkripsjon ikke funnet",
                    message: "Ingen transkripsjon funnet for dette opptaket. Kjør transkripsjon på nytt for å bruke editoren.",
                    displayName: displayName
                )

            case let .missingAudio(displayName):
                fallback(
                    title: "Lydfil mangler",
                    message: "Lydopptaket finnes ikke lenger på disken. Editoren kan ikke åpnes.",
                    displayName: displayName
                )
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear(perform: load)
    }

    private func fallback(title: String, message: String, displayName: String) -> some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.xl)
        .navigationTitle(displayName)
    }

    private func load() {
        let audioURL = StorageLayout.audioURL(id: recordingId)
        let displayName: String = {
            if let meta = try? RecordingStore.shared.load(id: recordingId) {
                return meta.displayName
            }
            return recordingId.uuidString
        }()

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            loadState = .missingAudio(displayName)
            return
        }

        // 1. In-memory cache (current session)
        if let cached = TranscriptionCache.shared.result(for: audioURL.path) {
            loadState = .ready(cached, audioURL, displayName)
            return
        }

        // 2. Legacy JSON on disk (written by saveTranscriptJSON after transcription/diarization)
        // TODO(ADR-1014 Phase 0D): migrate to StorageLayout-based path once Phase 0 D2 is complete.
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let jsonURL = support.appendingPathComponent(
            "AudioRecordingManager/transcripts/\(recordingId.uuidString).json"
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let data = try? Data(contentsOf: jsonURL),
           let result = try? decoder.decode(TranscriptionResult.self, from: data) {
            loadState = .ready(result, audioURL, displayName)
            return
        }

        // 3. Plain-text fallback: reconstruct from transcript.txt (recordings transcribed before
        //    JSON persistence was added). Segments are split on blank lines; no timing or speaker data.
        let txtURL = StorageLayout.transcriptURL(id: recordingId)
        if let text = try? String(contentsOf: txtURL, encoding: .utf8), !text.isEmpty {
            let paragraphs = text
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let segments = paragraphs.enumerated().map { i, para in
                TranscriptionSegment(
                    id: i, start: 0, end: 0,
                    text: para, speaker: "SPEAKER_0",
                    confidence: 1.0, words: []
                )
            }
            let result = TranscriptionResult(
                version: "1.0", model: "unknown", language: "no",
                durationSeconds: 0, numSpeakers: 1,
                segments: segments,
                metadata: TranscriptionResultMetadata(
                    inputFile: audioURL.lastPathComponent,
                    processingTimeSeconds: 0,
                    modelVariant: "unknown", computeType: "unknown", device: "unknown",
                    diarizationRun: false
                )
            )
            loadState = .ready(result, audioURL, displayName)
            return
        }

        loadState = .missingJSON(displayName)
    }
}
