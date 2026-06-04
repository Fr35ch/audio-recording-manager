// FluidDiarizationService.swift
// Clio
//
// Swift wrapper around FluidAudio's `OfflineDiarizerManager`. Replaces
// the pyannote.audio Python subprocess that previously ran in
// `TranscriptionService.diarize()`.
//
// Why FluidAudio?
//   - Open source, Apache 2.0
//   - Models run on Apple Neural Engine (CoreML), no Python venv
//   - First-run model download from FluidInference/speaker-diarization-coreml
//     on HuggingFace; the models are public and need no HF token, so
//     the researcher-facing UX is "click button, wait" with no
//     auth step
//   - Diarization is language-agnostic (speaker-acoustic) — works on
//     Norwegian out of the box
//
// Lifecycle:
//   - First call to `diarize(...)` triggers `prepareModels()` which
//     downloads (~100 MB) and CoreML-compiles the segmentation +
//     embedding models. Subsequent calls reuse the cached manager.
//   - Cancellation: SwiftUI Task cancellation propagates through
//     `await` checkpoints inside FluidAudio.

import Foundation
import FluidAudio

@MainActor
final class FluidDiarizationService: ObservableObject {
    static let shared = FluidDiarizationService()

    // MARK: - Public state

    /// Lifecycle stage exposed to UI. `progress` advances roughly with
    /// the underlying pipeline stages — FluidAudio's `OfflineDiarizerManager`
    /// reports `PipelineTimings` after completion rather than streaming
    /// per-frame progress, so we drive `progress` from the stage
    /// transitions instead of from the model itself.
    enum Stage: Equatable {
        case idle
        case loadingModels
        case processing
        case completed
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var progress: Double = 0

    // MARK: - Result type (mirrors TimedSpeakerSegment with Double precision)

    struct DiarizationSegment: Equatable {
        let speakerId: String          // "Speaker 1", "Speaker 2", ... per FluidAudio convention
        let startSeconds: Double
        let endSeconds: Double
    }

    // MARK: - Private

    /// Cached manager — keeps compiled CoreML models in memory across
    /// successive diarization runs in the same app session. The first
    /// call to `diarize(...)` builds it lazily.
    private var manager: OfflineDiarizerManager?

    /// The `expectedSpeakers` value the cached `manager` was built
    /// with. If the next call asks for a different count, we have to
    /// discard the cached manager — `OfflineDiarizerManager` takes its
    /// config via `init`, so a stale manager keeps applying the old
    /// constraint regardless of what we pass to `process`.
    private var cachedExpectedSpeakers: Int?

    /// Tracks the in-flight task so `cancel()` can interrupt it.
    private var task: Task<[DiarizationSegment], Error>?

    private init() {}

    // MARK: - Public API

    /// Run speaker diarization on the audio at `audioURL`. Throws if
    /// the model can't be downloaded/compiled or the audio is invalid.
    ///
    /// - Parameters:
    ///   - audioURL: file URL to a recorded `.m4a` (or any
    ///     FluidAudio-accepted format)
    ///   - expectedSpeakers: optional exact speaker count to bias the
    ///     clustering. `nil` lets the model decide. ARM stores the
    ///     researcher's preference under
    ///     `@AppStorage("transcription.defaultSpeakers")`.
    func diarize(
        audioURL: URL,
        expectedSpeakers: Int? = nil
    ) async throws -> [DiarizationSegment] {
        // If a previous task is still in-flight, cancel it so we
        // don't double-process.
        task?.cancel()

        let newTask = Task<[DiarizationSegment], Error> {
            try await self.runDiarization(
                audioURL: audioURL, expectedSpeakers: expectedSpeakers)
        }
        task = newTask
        do {
            let segments = try await newTask.value
            task = nil
            return segments
        } catch {
            task = nil
            throw error
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stage = .idle
        progress = 0
    }

    // MARK: - Internal pipeline

    private func runDiarization(
        audioURL: URL, expectedSpeakers: Int?
    ) async throws -> [DiarizationSegment] {
        // Normalise the speaker-count constraint: `expectedSpeakers <= 1`
        // is treated as "auto-detect" since `withSpeakers(exactly: 1)`
        // forces every segment into a single cluster, defeating
        // diarization entirely.
        let effectiveCount: Int? = (expectedSpeakers ?? 0) >= 2 ? expectedSpeakers : nil

        // Discard the cached manager when the speaker constraint
        // changes — `OfflineDiarizerManager` takes its config via
        // `init`, so a stale manager keeps applying the old constraint
        // regardless of what we pass to `process`.
        if manager != nil && cachedExpectedSpeakers != effectiveCount {
            print("🎤 FluidAudio: speaker constraint changed "
                + "(\(cachedExpectedSpeakers.map(String.init) ?? "auto") → "
                + "\(effectiveCount.map(String.init) ?? "auto")); "
                + "rebuilding diarizer.")
            manager = nil
        }

        var config: OfflineDiarizerConfig = .default
        if let count = effectiveCount {
            config = config.withSpeakers(exactly: count)
        }

        // Stage 1: prepare models (download + compile). First call only;
        // subsequent calls hit the in-memory `manager`. CoreML
        // compilation is cached on disk, so even a rebuild after a
        // config change is fast.
        if manager == nil {
            stage = .loadingModels
            progress = 0.05
            let m = OfflineDiarizerManager(config: config)
            do {
                try await m.prepareModels()
            } catch {
                stage = .failed(humanError(error))
                throw error
            }
            manager = m
            cachedExpectedSpeakers = effectiveCount
        }

        guard let manager else {
            stage = .failed("Diariseringsmodellen kunne ikke initialiseres.")
            throw FluidDiarizationError.modelNotReady
        }

        // Stage 2: process. FluidAudio doesn't stream per-frame
        // progress, so we just flip to .processing and let the UI
        // show an indeterminate-bar-fallback.
        stage = .processing
        progress = 0.5

        let result: DiarizationResult
        do {
            result = try await manager.process(audioURL)
        } catch {
            stage = .failed(humanError(error))
            throw error
        }

        try Task.checkCancellation()

        let mapped = result.segments.map {
            DiarizationSegment(
                speakerId: $0.speakerId,
                startSeconds: Double($0.startTimeSeconds),
                endSeconds: Double($0.endTimeSeconds)
            )
        }

        // Diagnostic log — surfaces in the Xcode console + audit log
        // so we can tell whether the model found multiple speakers or
        // just collapsed everything into one cluster. Remove (or
        // demote to debug) once the diarization quality is verified.
        let uniqueSpeakers = Set(mapped.map { $0.speakerId }).sorted()
        let constraint = expectedSpeakers.map(String.init) ?? "nil (auto)"
        let url = audioURL.lastPathComponent
        print("""
            🎤 FluidAudio diarization
              file: \(url)
              expectedSpeakers: \(constraint)
              returned segments: \(mapped.count)
              unique speakers: \(uniqueSpeakers.joined(separator: ", "))
              first 3 segments: \(mapped.prefix(3).map { "[\($0.speakerId) \($0.startSeconds)→\($0.endSeconds)]" }.joined(separator: " "))
            """)

        stage = .completed
        progress = 1.0
        return mapped
    }

    /// FluidAudio surfaces error descriptions through `LocalizedError`,
    /// but some `OfflineDiarizationError` cases include path / size
    /// detail we don't want to leak in the UI. Normalise to a short
    /// Norwegian string here.
    private func humanError(_ error: Error) -> String {
        if let known = error as? OfflineDiarizationError {
            return known.errorDescription ?? "Diarisering feilet."
        }
        if let known = error as? DiarizerError {
            return known.errorDescription ?? "Diarisering feilet."
        }
        return error.localizedDescription
    }
}

// MARK: - Errors

enum FluidDiarizationError: LocalizedError {
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "Diariseringsmodellen kunne ikke lastes."
        }
    }
}
