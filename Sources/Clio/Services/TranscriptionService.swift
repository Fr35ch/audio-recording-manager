import AVFoundation
import Foundation

// MARK: - Error types

enum TranscriptionError: LocalizedError {
    case notInstalled
    case timeout
    case processFailed(String)
    case invalidOutput
    case cancelled
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return """
            no-transcribe er ikke installert. Installer via innstillingspanelet, \
            eller manuelt med:
              pip install git+https://github.com/Fr35ch/no-transcribe.git
            """
        case .timeout:
            return "Transkripsjon tok for lang tid. Prøv igjen eller velg en mindre modell."
        case .processFailed(let message):
            return "Transkripsjon feilet: \(message)"
        case .invalidOutput:
            return "Uventet svar fra transkripsjonsprosessen"
        case .cancelled:
            return "Transkripsjon avbrutt"
        case .alreadyRunning:
            return "En transkripsjon kjører allerede. Vent til den er ferdig før du starter en ny."
        }
    }
}

enum ModelDownloadState: Equatable {
    case idle
    case downloading(model: TranscriptionModel, message: String)
    case ready(model: TranscriptionModel)
    case failed(message: String)
}

enum InstallationState: Equatable {
    case unknown
    case installed
    case missing
}

// MARK: - Progress stage

enum TranscriptionStage: String {
    case idle
    case loadingModel = "loading_model"
    case transcribing
    case aligning
    case diarizing
    case complete

    /// Norwegian display string for the current stage.
    var displayName: String {
        switch self {
        case .idle:         return ""
        case .loadingModel: return "Laster modell..."
        case .transcribing: return "Transkriberer..."
        case .aligning:     return "Justerer tidsstempler..."
        case .diarizing:    return "Identifiserer talere..."
        case .complete:     return "Ferdig"
        }
    }
}

// MARK: - In-memory transcription cache

/// Holds TranscriptionResult objects keyed by audio file path for the duration of the app session.
/// Results are added when transcription completes and restored when the user navigates back to a file.
final class TranscriptionCache {
    static let shared = TranscriptionCache()
    private var cache: [String: TranscriptionResult] = [:]
    private let lock = NSLock()

    private init() {}

    func store(_ result: TranscriptionResult, for path: String) {
        lock.lock()
        cache[path] = result
        lock.unlock()
    }

    func result(for path: String) -> TranscriptionResult? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    func hasResult(for path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[path] != nil
    }
}

// MARK: - Service

/// Runs Clio's native, in-process transcription pipeline (WhisperKit /
/// CoreML) — see `NativeTranscriptionEngine`. Replaces the old
/// `no-transcribe` Python subprocess bridge entirely: no embedded
/// interpreter, no child executable, no sandbox entitlement conflict.
///
/// Threading model:
///   - All async methods dispatch work off the main thread (mostly via the
///     `NativeTranscriptionEngine` actor, which serializes CoreML calls).
///   - All @Published updates happen on the main thread.
final class TranscriptionService: ObservableObject, @unchecked Sendable {
    static let shared = TranscriptionService()

    @Published var progress: Double = 0
    @Published var stage: TranscriptionStage = .idle
    @Published var diarizationProgress: Double = 0
    @Published var isSettingUp: Bool = false
    @Published var setupError: String? = nil
    /// Human-readable description of the current setup step. Native
    /// pipeline has no install step, so this is normally empty.
    @Published var setupStageDescription: String = ""
    @Published var modelDownloadState: ModelDownloadState = .idle
    @Published private(set) var installationState: InstallationState = .unknown
    /// True while any transcription is in progress. Guards against concurrent calls.
    @Published var isBusy: Bool = false

    private init() {}

    // MARK: - Public API

    /// True when the bundled WhisperKit model is present in the app bundle.
    var isInstalled: Bool {
        installationState == .installed
    }

    func runtimeIsInstalled() -> Bool {
        NativeTranscriptionEngine.isBundled
    }

    /// Always true — the native pipeline is always "bundled" (in-process
    /// CoreML, no external interpreter of any kind). Kept for source-level
    /// back-compat with existing call sites.
    var isBundledRuntime: Bool {
        true
    }

    func refreshInstallationState() async {
        let state: InstallationState = runtimeIsInstalled() ? .installed : .missing
        DispatchQueue.main.async {
            self.installationState = state
        }
    }

    /// Transcribes an audio file. Reports real-time progress via `stage` and `progress`.
    func transcribe(
        audioFile: URL,
        speakers: Int,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String
    ) async throws -> TranscriptionResult {
        // Enforce single-transcription-at-a-time. NB-Whisper is GPU-bound;
        // two concurrent jobs corrupt activeProcess and may deadlock.
        guard !isBusy else {
            throw TranscriptionError.alreadyRunning
        }
        DispatchQueue.main.async { self.isBusy = true }
        defer { DispatchQueue.main.async { self.isBusy = false } }

        // Check for RØDE stereo sidecar — if present and diarization_required is false,
        // use the channel-split pipeline instead of probabilistic diarization.
        if let meta = ClioMeta.load(for: audioFile), !meta.diarizationRequired {
            return try await runStereoTranscription(
                audioFile: audioFile,
                meta: meta,
                model: model,
                verbatim: verbatim,
                language: language)
        }

        // Robustness fallback: no ClioMeta sidecar present, but the recording was
        // imported as dual-channel (mobileImport.isDualChannel). Synthesize a
        // default ClioMeta and route to the channel split.
        if ClioMeta.load(for: audioFile) == nil,
           let recId = StorageLayout.recordingId(from: audioFile.deletingLastPathComponent()),
           let recMeta = try? RecordingStore.shared.load(id: recId),
           recMeta.mobileImport?.isDualChannel == true {
            let synthesized = ClioMeta.rodeDualChannelDefault()
            return try await runStereoTranscription(
                audioFile: audioFile,
                meta: synthesized,
                model: model,
                verbatim: verbatim,
                language: language)
        }

        // Non-RØDE / mono recordings: force single speaker to skip
        // probabilistic diarization which is too error-prone on software
        // audio spectrum alone.
        return try await runNative(
            audioFile: audioFile,
            speakers: 1,
            model: model,
            verbatim: verbatim,
            language: language
        )
    }

    /// Verifies the bundled WhisperKit model is present. With the native
    /// pipeline there's no pip venv or subprocess to install — the model
    /// ships inside the app bundle — so this just checks bundle presence
    /// and (optionally) pre-warms the CoreML pipeline into memory.
    func setupIfNeeded() async {
        let available = NativeTranscriptionEngine.isBundled
        DispatchQueue.main.async {
            self.isSettingUp = false
            self.setupStageDescription = ""
            self.installationState = available ? .installed : .missing
            self.setupError = available ? nil : "Innebygd NB-Whisper-modell mangler i appbunten."
        }
    }

    /// Kept for source-level back-compat with existing call sites — the
    /// native pipeline has nothing to install (the model is bundled), so
    /// this just re-checks bundle presence.
    func install() async throws {
        await setupIfNeeded()
        guard NativeTranscriptionEngine.isBundled else {
            throw TranscriptionError.notInstalled
        }
    }

    /// No-op — the bundled model is fixed at build time; there is no
    /// separate "update" step for the native pipeline.
    func update() async throws {}

    /// No-op — the model is bundled in the app, never downloaded.
    /// Kept for source-level back-compat with existing call sites.
    func downloadModel(_ model: TranscriptionModel, announce: Bool = true) async throws {
        guard NativeTranscriptionEngine.isBundled else {
            throw TranscriptionError.notInstalled
        }
        if announce {
            setModelDownloadState(.ready(model: model))
            clearModelDownloadStateLater()
        }
    }

    /// Ensures the requested model is present before transcription starts.
    /// Always resolves immediately — the model is bundled, never downloaded.
    func ensureModelAvailable(_ model: TranscriptionModel, announce: Bool = false) async throws {
        try await downloadModel(model, announce: announce)
    }

    /// Kept for source-level back-compat — nothing to prefetch, the model
    /// is already bundled in the app.
    func prefetchDefaultModelIfNeeded() async {
        if NativeTranscriptionEngine.isBundled {
            setModelDownloadState(.ready(model: .large))
            clearModelDownloadStateLater()
        }
    }

    /// Terminates any running transcription. The native pipeline runs
    /// in-process via an actor rather than a subprocess, so there is
    /// nothing to signal here yet — this resets UI state only.
    /// TODO: wire real cancellation through to WhisperKit once it exposes
    /// a cancellation token on `transcribe(audioPath:)`.
    func cancel() {
        DispatchQueue.main.async {
            self.progress = 0
            self.stage = .idle
        }
    }

    // MARK: - Native transcription (WhisperKit)

    /// Returns the duration in seconds of an audio file via AVFoundation.
    private func audioDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Transcribes a single mono audio file via the native WhisperKit engine.
    /// Replaces the old `no-transcribe` Python subprocess call — runs
    /// entirely in-process (CoreML/ANE), so there is no sandbox entitlement
    /// conflict with the main app's own sandbox.
    private func runNative(
        audioFile: URL,
        speakers: Int,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String
    ) async throws -> TranscriptionResult {
        let wavURL: URL
        do {
            wavURL = try AudioWAVConverter.convertToWAV(sourceURL: audioFile)
        } catch let error as AudioWAVConverterError {
            throw TranscriptionError.processFailed(error.errorDescription ?? "WAV-konvertering feilet")
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        DispatchQueue.main.async {
            self.stage = .transcribing
            self.progress = 0.1
        }

        let duration = await audioDuration(url: wavURL)
        let result = try await NativeTranscriptionEngine.shared.transcribe(
            wavPath: wavURL.path, language: language, speakerLabel: "SPEAKER_0",
            durationSeconds: duration)

        DispatchQueue.main.async {
            self.progress = 1.0
            self.stage = .complete
        }

        return result
    }

    // MARK: - Native mono transcription (stereo-split path)

    /// Runs the native WhisperKit engine on a single mono M4A (one RØDE
    /// channel). Does NOT update `stage`/`progress` — those are managed by
    /// the outer stereo orchestrator. All returned segments are labelled
    /// `speakerLabel`.
    private func runNativeMono(
        audioFile: URL,
        speakerLabel: String,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String
    ) async throws -> TranscriptionResult {
        let wavURL: URL
        do {
            wavURL = try AudioWAVConverter.convertToWAV(sourceURL: audioFile)
        } catch let error as AudioWAVConverterError {
            throw TranscriptionError.processFailed(error.errorDescription ?? "WAV-konvertering feilet")
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let duration = await audioDuration(url: wavURL)
        var result = try await NativeTranscriptionEngine.shared.transcribe(
            wavPath: wavURL.path, language: language, speakerLabel: speakerLabel,
            durationSeconds: duration)

        result.metadata.diarizationRun = true  // channel split IS our diarization
        return result
    }

    // MARK: - Stereo pipeline orchestrator

    private func runStereoTranscription(
        audioFile: URL,
        meta: ClioMeta,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String
    ) async throws -> TranscriptionResult {

        AuditLogger.shared.log(.transcriptionStereoSplitStarted, payload: [
            "sourceFile": .string(audioFile.lastPathComponent),
            "leftLabel":  .string(meta.resolvedLeft),
            "rightLabel": .string(meta.resolvedRight),
        ])

        // Step 1: split
        let (leftURL, rightURL): (URL, URL)
        do {
            (leftURL, rightURL) = try await StereoSplitter.splitStereoM4A(sourceURL: audioFile)
        } catch {
            AuditLogger.shared.log(.transcriptionStereoSplitFailed, payload: [
                "errorType":    .string("split"),
                "errorMessage": .string(error.localizedDescription),
            ])
            throw error
        }

        defer {
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
        }

        // Step 2: transcribe each channel. Both calls target the same
        // NativeTranscriptionEngine actor, so they naturally serialize on
        // the underlying CoreML/ANE model instance — matches the GPU-bound
        // serialization behavior of the old subprocess path.
        async let leftResult: TranscriptionResult = runNativeMono(
            audioFile: leftURL, speakerLabel: meta.resolvedLeft,
            model: model, verbatim: verbatim, language: language)
        async let rightResult: TranscriptionResult = runNativeMono(
            audioFile: rightURL, speakerLabel: meta.resolvedRight,
            model: model, verbatim: verbatim, language: language)

        var (left, right): (TranscriptionResult, TranscriptionResult)
        do {
            (left, right) = try await (leftResult, rightResult)
        } catch {
            AuditLogger.shared.log(.transcriptionStereoSplitFailed, payload: [
                "errorType":    .string("transcription"),
                "errorMessage": .string(error.localizedDescription),
            ])
            throw error
        }

        // Step 2b: cross-talk suppression + timestamp tightening.
        // Both RØDE transmitters pick up both speakers, so each utterance is
        // transcribed on BOTH channels — surfacing as duplicate lines (one per
        // label) in the merge. For every segment we ask the energy analysis
        // whether that segment's own channel is actually the dominant, active
        // speaker within it: if not, the segment is bleed from the other mic
        // and is dropped. If it is, we tighten the segment's timestamps to the
        // real speech onset/offset — NB-Whisper's segment boundaries often
        // reach into the other speaker's audio, which both misattributes lines
        // and makes distinct utterances appear at the same time. Working
        // window-by-window (rather than averaging over the loose nominal span)
        // is what lets a genuine line survive even when its reported start
        // overlaps the other speaker. If analysis fails we keep both channels
        // unchanged rather than risk dropping content.
        if let energy = try? StereoSplitter.analyzeChannelEnergy(sourceURL: audioFile) {
            let leftBefore = left.segments.count
            let rightBefore = right.segments.count

            func tighten(
                _ segments: [TranscriptionSegment],
                side: StereoSplitter.ChannelEnergy.Side
            ) -> [TranscriptionSegment] {
                segments.compactMap { seg in
                    guard let range = energy.dominantRange(
                        start: seg.start, end: seg.end, side: side
                    ) else { return nil }
                    return TranscriptionSegment(
                        id: seg.id,
                        start: range.lowerBound,
                        end: range.upperBound,
                        text: seg.text,
                        speaker: seg.speaker,
                        confidence: seg.confidence,
                        words: seg.words)
                }
            }

            left.segments = tighten(left.segments, side: .left)
            right.segments = tighten(right.segments, side: .right)

            AuditLogger.shared.log(.transcriptionStereoSplitCompleted, payload: [
                "stage":           .string("crossTalkFilter"),
                "leftDropped":     .int(leftBefore - left.segments.count),
                "rightDropped":    .int(rightBefore - right.segments.count),
            ])
        }

        // Step 3: merge segments sorted by start time, renumber IDs
        let merged = mergeTranscriptionResults(
            left: left,
            right: right,
            leftLabel: meta.resolvedLeft,
            rightLabel: meta.resolvedRight)

        AuditLogger.shared.log(.transcriptionStereoSplitCompleted, payload: [
            "leftSegments":   .int(left.segments.count),
            "rightSegments":  .int(right.segments.count),
            "mergedSegments": .int(merged.segments.count),
        ])

        return merged
    }

    // MARK: - Merge helpers

    /// Merges two single-speaker TranscriptionResults into one by interleaving
    /// segments sorted by start time. Left wins on timestamp ties.
    private func mergeTranscriptionResults(
        left: TranscriptionResult,
        right: TranscriptionResult,
        leftLabel: String,
        rightLabel: String
    ) -> TranscriptionResult {
        let segments = (left.segments + right.segments)
            .sorted { a, b in
                if a.start == b.start {
                    // tie-break: left channel first
                    return a.speaker == leftLabel
                }
                return a.start < b.start
            }
            .enumerated()
            .map { idx, seg -> TranscriptionSegment in
                TranscriptionSegment(
                    id: idx,
                    start: seg.start,
                    end: seg.end,
                    text: seg.text,
                    speaker: seg.speaker,
                    confidence: seg.confidence,
                    words: seg.words)
            }

        // Build combined metadata from the left result (representative)
        var metadata = left.metadata
        metadata.diarizationRun = true

        return TranscriptionResult(
            version: left.version,
            model: left.model,
            language: left.language,
            durationSeconds: max(left.durationSeconds, right.durationSeconds),
            numSpeakers: 2,
            segments: segments,
            metadata: metadata)
    }

    /// Text-level merge of two timestamped plain-text transcripts.
    /// Each line has the format `[HH:MM:SS] Tekst`.
    /// Used for plain-text export / display. Speaker labels are injected.
    ///
    /// - Returns: merged plain text where each line is `[HH:MM:SS] LABEL: Tekst`
    static func mergeTranscripts(
        left: String,
        right: String,
        leftLabel: String,
        rightLabel: String
    ) -> String {
        struct TimedLine {
            let seconds: Int    // parsed timestamp in total seconds
            let label: String
            let text: String
            var formatted: String { "[\(hhmmss(seconds))] \(label): \(text)" }
        }

        func parseLines(_ transcript: String, label: String) -> [TimedLine] {
            transcript
                .components(separatedBy: "\n")
                .compactMap { line -> TimedLine? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("["),
                          let close = trimmed.firstIndex(of: "]") else { return nil }
                    let tsRange = trimmed.index(trimmed.startIndex, offsetBy: 1)..<close
                    let ts = String(trimmed[tsRange])
                    let parts = ts.split(separator: ":").compactMap { Int($0) }
                    guard parts.count == 3 else { return nil }
                    let secs = parts[0] * 3600 + parts[1] * 60 + parts[2]
                    let rest = String(trimmed[trimmed.index(after: close)...])
                        .trimmingCharacters(in: .whitespaces)
                    return TimedLine(seconds: secs, label: label, text: rest)
                }
        }

        func hhmmss(_ totalSeconds: Int) -> String {
            let h = totalSeconds / 3600
            let m = (totalSeconds % 3600) / 60
            let s = totalSeconds % 60
            return String(format: "%02d:%02d:%02d", h, m, s)
        }

        var all = parseLines(left, label: leftLabel) + parseLines(right, label: rightLabel)
        all.sort {
            if $0.seconds == $1.seconds { return $0.label == leftLabel }
            return $0.seconds < $1.seconds
        }
        return all.map { $0.formatted }.joined(separator: "\n")
    }

    // MARK: - Model availability (native — bundled, no install/download needed)

    /// True if the bundled WhisperKit model is present in the app bundle.
    /// With the native pipeline there is nothing to install or download —
    /// the model ships inside the app — so this simply reflects bundle
    /// presence rather than a pip/venv installation state.
    private func isModelCached(_ model: TranscriptionModel) -> Bool {
        NativeTranscriptionEngine.isBundled
    }

    func modelIsCached(_ model: TranscriptionModel) -> Bool {
        isModelCached(model)
    }

    private func setModelDownloadState(_ state: ModelDownloadState) {
        DispatchQueue.main.async {
            self.modelDownloadState = state
        }
    }

    private func clearModelDownloadStateLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if case .ready = self.modelDownloadState {
                self.modelDownloadState = .idle
            }
        }
    }

    // MARK: - Public diarize/analyze API

    /// Speaker diarization via FluidAudio (CoreML, on-device).
    ///
    /// Replaces the previous pyannote.audio Python subprocess. The
    /// `hfToken` parameter is kept on the signature for source-level
    /// back-compat with the player's old call site — its value is
    /// ignored; FluidAudio pulls public CoreML models from
    /// `FluidInference/speaker-diarization-coreml` without auth.
    /// Drop the parameter once the player stops passing it.
    func diarize(
        audioFile: URL,
        existingResult: TranscriptionResult,
        hfToken: String = "",
        speakers: Int
    ) async throws -> TranscriptionResult {
        _ = hfToken  // ignored — see docstring

        await MainActor.run {
            self.stage = .diarizing
            self.diarizationProgress = 0
        }
        ProcessingStateCache.shared.setStep(.diarization, status: .inProgress, for: audioFile.path)

        do {
            // 1. Run FluidAudio diarization on the audio file. Yields
            //    [DiarizationSegment] with absolute timestamps; speaker
            //    identity is local to this recording.
            let speakerSegments = try await FluidDiarizationService.shared.diarize(
                audioURL: audioFile, expectedSpeakers: speakers)

            // 2. Align the speaker timeline with the existing transcript
            //    segments by maximum temporal overlap, mutating speaker
            //    labels in place.
            var result = existingResult
            result.segments = SpeakerAlignment.attachSpeakers(
                to: result.segments,
                using: speakerSegments)
            result.numSpeakers = Set(result.segments.map { $0.speaker }).count
            result.metadata.diarizationRun = true

            TranscriptionCache.shared.store(result, for: audioFile.path)
            if let recId = StorageLayout.recordingId(from: audioFile.deletingLastPathComponent()) {
                saveTranscriptJSON(result, recordingId: recId)
            }
            ProcessingStateCache.shared.setStep(.diarization, status: .completed, for: audioFile.path)
            await MainActor.run {
                self.diarizationProgress = 1.0
                self.stage = .idle
            }
            return result
        } catch {
            ProcessingStateCache.shared.setStep(.diarization, status: .failed, for: audioFile.path,
                                                error: error.localizedDescription)
            await MainActor.run { self.stage = .idle }
            throw error
        }
    }

    // MARK: - Transcript JSON persistence

    func saveTranscriptJSONPublic(_ result: TranscriptionResult, recordingId: UUID) {
        saveTranscriptJSON(result, recordingId: recordingId)
    }

    private func saveTranscriptJSON(_ result: TranscriptionResult, recordingId: UUID) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AudioRecordingManager/transcripts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(recordingId.uuidString).json")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? encoder.encode(result) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
