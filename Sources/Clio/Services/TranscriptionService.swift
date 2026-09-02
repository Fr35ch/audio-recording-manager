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

/// Runs Clio's native, in-process transcription pipeline (whisper.cpp,
/// on-device via Metal) — see `WhisperCppEngine`. Replaces the old
/// `no-transcribe` Python subprocess bridge entirely: no embedded
/// interpreter, no child executable, no sandbox entitlement conflict.
/// (Clio previously ran WhisperKit/CoreML here — see
/// `NativeTranscriptionEngine`, kept in the tree but no longer called by
/// this service — switched to whisper.cpp because WhisperKit has no
/// beam-search decode path at all, while whisper.cpp does, matching how
/// VG's "Jojo" app does on-device NB-Whisper transcription.)
///
/// Threading model:
///   - All async methods dispatch work off the main thread (mostly via the
///     `WhisperCppEngine` actor, which serializes GPU/Metal decode calls).
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

    /// The current run's cancellation flag, created fresh at the start of
    /// every `transcribe(...)` call and threaded down into every
    /// `WhisperCppEngine.shared.transcribe(...)` call site (main pass,
    /// per-channel stereo pass, escalating-temperature repair). Deliberately
    /// NOT actor state — see `WhisperCppEngine.CancellationToken`'s own doc
    /// comment for why `cancel()` needs to flip this instantly from
    /// whatever (main-actor) context calls it, without waiting on
    /// `WhisperCppEngine`'s serial executor, which is busy for the entire
    /// duration of a real decode.
    private var currentCancellationToken: WhisperCppEngine.CancellationToken?

    private init() {}

    // MARK: - Public API

    /// True when the bundled whisper.cpp GGML model is present in the app bundle.
    var isInstalled: Bool {
        installationState == .installed
    }

    func runtimeIsInstalled() -> Bool {
        WhisperCppEngine.isBundled
    }

    /// Always true — the native pipeline is always "bundled" (in-process
    /// GGML/Metal, no external interpreter of any kind). Kept for source-level
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
        language: String,
        accuracyLevel: TranscriptionAccuracyLevel = .default
    ) async throws -> TranscriptionResult {
        // Enforce single-transcription-at-a-time. NB-Whisper is GPU-bound;
        // two concurrent jobs corrupt activeProcess and may deadlock.
        guard !isBusy else {
            throw TranscriptionError.alreadyRunning
        }
        DispatchQueue.main.async { self.isBusy = true }
        let token = WhisperCppEngine.CancellationToken()
        currentCancellationToken = token
        defer {
            DispatchQueue.main.async { self.isBusy = false }
            currentCancellationToken = nil
        }

        // Check for RØDE stereo sidecar — if present and diarization_required is false,
        // use the channel-split pipeline instead of probabilistic diarization.
        if let meta = ClioMeta.load(for: audioFile), !meta.diarizationRequired {
            return try await runStereoTranscription(
                audioFile: audioFile,
                meta: meta,
                model: model,
                verbatim: verbatim,
                language: language,
                accuracyLevel: accuracyLevel)
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
                language: language,
                accuracyLevel: accuracyLevel)
        }

        // Non-RØDE / mono recordings: force single speaker to skip
        // probabilistic diarization which is too error-prone on software
        // audio spectrum alone.
        return try await runNative(
            audioFile: audioFile,
            speakers: 1,
            model: model,
            verbatim: verbatim,
            language: language,
            accuracyLevel: accuracyLevel
        )
    }

    /// Verifies the bundled whisper.cpp GGML model is present. With the native
    /// pipeline there's no pip venv or subprocess to install — the model
    /// ships inside the app bundle — so this just checks bundle presence
    /// and (optionally) pre-warms the GPU/Metal context into memory.
    func setupIfNeeded() async {
        let available = WhisperCppEngine.isBundled
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
        guard WhisperCppEngine.isBundled else {
            throw TranscriptionError.notInstalled
        }
    }

    /// No-op — the bundled model is fixed at build time; there is no
    /// separate "update" step for the native pipeline.
    func update() async throws {}

    /// No-op — the model is bundled in the app, never downloaded.
    /// Kept for source-level back-compat with existing call sites.
    func downloadModel(_ model: TranscriptionModel, announce: Bool = true) async throws {
        guard WhisperCppEngine.isBundled else {
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
        if WhisperCppEngine.isBundled {
            setModelDownloadState(.ready(model: .large))
            clearModelDownloadStateLater()
        }
    }

    /// Terminates any running transcription.
    ///
    /// Real bug found via a live user report: this used to only reset UI
    /// state (`progress`/`stage`) while the actual in-process whisper.cpp
    /// decode kept running to completion in the background — Swift's
    /// `Task.cancel()` (called by `TranscriptionRunner.cancel`) cannot
    /// interrupt a single long synchronous C call with no cooperative
    /// cancellation checks. `isBusy` stayed `true` for however long that
    /// orphaned decode actually took (many minutes for a real interview),
    /// permanently blocking every subsequent "Transkriber" attempt with
    /// "en transkripsjon kjører allerede" even though the UI had already
    /// moved on. Now signals the real, mid-decode
    /// `WhisperCppEngine.CancellationToken` for the in-flight run — see its
    /// own doc comment for how whisper.cpp's `abort_callback` mechanism
    /// makes this a genuine, prompt (sub-second) interruption, not just a
    /// UI reset racing an orphaned background task.
    func cancel() {
        currentCancellationToken?.cancel()
        DispatchQueue.main.async {
            self.progress = 0
            self.stage = .idle
        }
    }

    // MARK: - Native transcription (whisper.cpp)

    /// Returns the duration in seconds of an audio file via AVFoundation.
    private func audioDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Restores the quality-validation safety net the old `no-transcribe`
    /// Python pipeline had (`--validate warn/retry/flag` in `navt.py`) and
    /// the WhisperKit port dropped entirely. Reads
    /// `transcription.validateMode` directly from `UserDefaults`;
    /// `"none"` skips validation altogether (today's behavior, unchanged).
    /// `wavURL` must still exist
    /// on disk — call this before the caller's `defer` cleanup runs.
    ///
    /// `"retry"` (automatic re-transcription of flagged regions) is not
    /// implemented yet — WhisperKit has no beam-count knob to escalate to
    /// like the old pipeline did, so it needs its own design; deliberately
    /// scoped out of this change. Selecting "retry" currently behaves the
    /// same as "warn".
    ///
    /// Never logs matched phrase text, segment text, or any other
    /// transcript content to `AuditLogger` — only the mode, score, and
    /// issue count, per this project's audit-log content policy.
    private func applyValidation(to result: inout TranscriptionResult, wavURL: URL) {
        let mode = UserDefaults.standard.string(forKey: "transcription.validateMode") ?? "warn"
        guard mode != "none" else { return }

        let summary = TranscriptValidation.validate(segments: result.segments, wavURL: wavURL)
        result.validation = summary

        if mode == "flag" {
            result.segments = TranscriptValidation.flagLowConfidenceSegments(
                segments: result.segments, summary: summary)
        }

        AuditLogger.shared.log(.transcriptValidationCompleted, payload: [
            "mode":       .string(mode),
            "score":      .int(summary.score),
            "issueCount": .int(summary.issueCount),
        ])
    }

    /// Consolidated check for whether a segment's text is suspect enough
    /// to warrant a repair attempt — replaces two narrower checks that
    /// used to gate repair separately: an exact match against
    /// `NativeTranscriptionEngine.unclearAudioPlaceholder`, and (upstream,
    /// in `NativeTranscriptionEngine.sanitize`) letter-free text. Both
    /// still apply here, plus a new case that neither caught: a segment
    /// whose text is technically non-empty and contains letters, but is
    /// far too sparse for its own duration — the exact shape of a real,
    /// reported bug (an isolated `>` was already caught by the
    /// letter-free rule and converted to the placeholder upstream, but a
    /// segment reading e.g. a single short word over an 11-second span
    /// would not be, and is just as clearly a decode failure).
    ///
    /// Deliberately distinct from `TranscriptValidation.detectLowDensityRegions`,
    /// which operates over a 60-second sliding window across the whole
    /// transcript (a different granularity, meant for whole-recording
    /// quality scoring) — this checks one segment's own duration in
    /// isolation, which is what repair needs to decide about one segment
    /// at a time. `minDurationForDensityCheck` keeps this from ever
    /// misfiring on genuinely short real utterances ("Ja.", "Mhm") by
    /// only applying the density math to segments already long enough
    /// that a real utterance would easily clear the bar.
    static func isSuspectSegment(
        _ segment: TranscriptionSegment,
        minDurationForDensityCheck: Double = 3.0,
        minLettersPerSecond: Double = 0.5
    ) -> Bool {
        if segment.text == NativeTranscriptionEngine.unclearAudioPlaceholder {
            return true
        }
        let duration = segment.end - segment.start
        guard duration >= minDurationForDensityCheck else { return false }
        return contentDensityScore(text: segment.text, durationSeconds: duration) < minLettersPerSecond
    }

    /// Letters-per-second content-density score for a candidate decode
    /// result, used both by `isSuspectSegment` (is this existing segment
    /// bad enough to retry?) and `retryDecodeEscalating` (which of
    /// several retry candidates is the best one to keep?). Counts letters
    /// specifically (not raw character count) so punctuation/whitespace
    /// differences between candidates don't skew the comparison.
    static func contentDensityScore(text: String, durationSeconds: Double) -> Double {
        guard durationSeconds > 0 else { return 0 }
        let letterCount = text.filter { $0.isLetter }.count
        return Double(letterCount) / durationSeconds
    }

    /// A single successful decode candidate from `retryDecodeEscalating`,
    /// carrying the subclip padding that produced it — needed by
    /// `recoverGap` to correctly remap the winning candidate's segment
    /// timestamps back to absolute time via `remapRecoveredSegment`, since
    /// different padding candidates each define their own subclip-relative
    /// coordinate origin.
    private struct RepairCandidate {
        let result: TranscriptionResult
        let padding: Double
    }

    /// Subclip padding variants tried when re-decoding an isolated region,
    /// in optimistic-first order. The default (2.0s, matching
    /// `no-transcribe`'s own `CONTEXT_S`) is tried first; a narrower 0.5s
    /// framing is tried as a fallback since pulling in less of a
    /// neighboring speaker's audio sometimes decodes more reliably.
    /// Deliberately bounded to two values, not an open-ended search, to
    /// keep retry cost roughly proportionate to the actual expected win.
    private static let repairPaddingCandidates: [Double] = [2.0, 0.5]

    /// Tries decoding an isolated region of `wavURL` with escalating
    /// decode strategies — subclip framing *and* temperature — scoring
    /// every real (non-empty, non-placeholder) candidate by content
    /// density and returning the best-scoring one, not the first attempt
    /// that merely isn't empty. Quality-gate relaxation
    /// (`disableNoSpeechSkip`) alone only helps when the model itself
    /// flags low confidence — it does nothing for a *confidently wrong*
    /// greedy decode, confirmed by a real rebuild-and-retest of an actual
    /// reported recording: output was byte-for-byte identical with the
    /// gates disabled, meaning WhisperKit's own fallback ladder never even
    /// started (no gate ever flagged a problem for that clip). Forcing
    /// progressively higher starting temperatures introduces the sampling
    /// diversity a deterministic greedy decode can't provide on its own;
    /// varying subclip padding addresses the separate possibility that
    /// the specific boundary chosen (not just the temperature) is part of
    /// why a given decode fails. Stops early once a candidate's density
    /// score is already clearly good, to bound total retry cost. Shared
    /// by `repairUnclearSegments` and `recoverGap` so both retry paths get
    /// the same consensus logic instead of duplicating it.
    private func retryDecodeEscalating(
        wavURL: URL, start: Double, end: Double, speakerLabel: String,
        language: String, verbatim: Bool
    ) async -> RepairCandidate? {
        let nominalDuration = end - start
        var best: (candidate: RepairCandidate, score: Double)?

        for padding in Self.repairPaddingCandidates {
            guard let subclipURL = try? AudioWAVConverter.extractSubClip(
                wavURL: wavURL, start: start, end: end, padding: padding
            ) else { continue }
            defer { try? FileManager.default.removeItem(at: subclipURL) }
            let clipDuration = nominalDuration + 2 * padding

            for temperature: Float? in [nil, 0.4, 0.8] {
                // Bail out of the whole (small, bounded) consensus search the
                // moment a cancellation is requested, rather than burning
                // several more retry attempts that would each abort almost
                // instantly anyway — see `WhisperCppEngine.CancellationToken`.
                if currentCancellationToken?.isCancelled == true { return best?.candidate }

                guard let retry = try? await WhisperCppEngine.shared.transcribe(
                    wavPath: subclipURL.path, language: language, speakerLabel: speakerLabel,
                    durationSeconds: clipDuration, verbatim: verbatim,
                    disableNoSpeechSkip: true, forcedTemperature: temperature,
                    cancellationToken: currentCancellationToken
                ) else { continue }

                let text = retry.segments
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0 != NativeTranscriptionEngine.unclearAudioPlaceholder }
                    .joined(separator: " ")
                guard !text.isEmpty else { continue }

                let score = Self.contentDensityScore(text: text, durationSeconds: nominalDuration)
                let candidate = RepairCandidate(result: retry, padding: padding)
                if best == nil || score > best!.score {
                    best = (candidate, score)
                }
                // Already clearly good (roughly a real word or more per
                // second) — stop escalating further rather than trying
                // every remaining combination for no real benefit.
                if score >= 1.5 { return best?.candidate }
            }
        }
        return best?.candidate
    }

    /// Re-transcribes suspect segments (see `isSuspectSegment`) using an
    /// isolated sub-clip of just that segment's own time range (see
    /// `AudioWAVConverter.extractSubClip`) rather than trusting the single
    /// full-file decode that produced the placeholder or sparse text.
    ///
    /// This is the concrete, narrowly-scoped repair mechanism for a real,
    /// reported failure mode: bad content appearing over audio that is
    /// clearly audible to a human listener, with no overlapping segment
    /// on another channel for `deduplicateCrossTalk` to fall back to —
    /// i.e. nothing else in the pipeline can recover this content except
    /// asking the model to try again on just this narrow slice. Mirrors
    /// `no-transcribe`'s own `_fill_gap`, which re-transcribed short
    /// isolated clips for exactly the same reason (they decode far more
    /// reliably than a mid-stream window of a much longer file).
    ///
    /// Strictly improve-or-leave-unchanged: only replaces a segment's text
    /// if the retry produces real, non-placeholder content. If the retry
    /// also comes back unclear (or fails outright), the original text is
    /// left in place — this can never make a segment worse than it
    /// already was.
    ///
    /// - Parameter forceAll: at `TranscriptionAccuracyLevel.accurate`/
    ///   `.mostAccurate`, every segment gets a second, scored opinion —
    ///   not just ones `isSuspectSegment` already flagged as bad. Since
    ///   these segments already look fine, a replacement only happens if
    ///   the retry's own content-density score is strictly better than
    ///   the existing text's — otherwise a second look at genuinely good
    ///   content could gratuitously swap it for a different-but-not-better
    ///   alternative. Segments already flagged by `isSuspectSegment` keep
    ///   the existing any-real-text-wins behavior regardless of this flag,
    ///   since their starting point has no real content to compare against.
    private func repairUnclearSegments(
        _ segments: [TranscriptionSegment], wavURL: URL, speakerLabel: String,
        language: String, verbatim: Bool, forceAll: Bool = false
    ) async -> [TranscriptionSegment] {
        var result = segments
        for (idx, seg) in segments.enumerated() {
            let isSuspect = Self.isSuspectSegment(seg)
            guard isSuspect || forceAll else { continue }

            guard let candidate = await retryDecodeEscalating(
                wavURL: wavURL, start: seg.start, end: seg.end,
                speakerLabel: speakerLabel, language: language, verbatim: verbatim
            ) else { continue }

            let realText = candidate.result.segments
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != NativeTranscriptionEngine.unclearAudioPlaceholder }
                .joined(separator: " ")
            guard !realText.isEmpty else { continue }

            if !isSuspect {
                // Already-good segment re-checked proactively — only
                // replace if the retry is a genuine improvement, not just
                // "also non-empty".
                let duration = seg.end - seg.start
                let currentScore = Self.contentDensityScore(text: seg.text, durationSeconds: duration)
                let candidateScore = Self.contentDensityScore(text: realText, durationSeconds: duration)
                guard candidateScore > currentScore else { continue }
            }

            result[idx].text = realText
        }
        return result
    }


    /// Detects and fills timeline gaps left by WhisperKit's own no-speech
    /// skip (`DecodingOptions.noSpeechThreshold`, `SegmentSeeker
    /// .findSeekPointAndSegments`): when a decode window's no-speech
    /// probability exceeds the threshold, WhisperKit silently discards that
    /// *entire* ~30s window — no segment, not even a placeholder — which
    /// surfaces as real, audible speech simply missing from the transcript
    /// with no trace it was ever attempted. `repairUnclearSegments` above
    /// cannot catch this: it only retries segments that already exist with
    /// placeholder text, but a whole-window skip produces no segment at all.
    ///
    /// This mirrors `no-transcribe`'s own `_fill_gap` mechanism exactly
    /// (`GAP_FILL_S = 5.0`, `CONTEXT_S = 2.0` in `navt.py`): any gap between
    /// consecutive segments (or before the first / after the last) wider
    /// than `gapThresholdSeconds` is re-transcribed in isolation via
    /// `AudioWAVConverter.extractSubClip`, and any real (non-empty,
    /// non-placeholder) recovered text is spliced into the timeline at the
    /// correct absolute position. Isolated short clips decode far more
    /// reliably than a mid-stream window of a much longer file — the same
    /// reasoning `no-transcribe` and `repairUnclearSegments` both rely on.
    ///
    /// Strictly additive: only ever inserts segments into a span that
    /// previously had none. Never removes or modifies an existing segment.
    /// (Subclip padding is now chosen dynamically by `retryDecodeEscalating`'s
    /// consensus search — see `repairPaddingCandidates` — rather than a
    /// single fixed constant; `no-transcribe`'s own `CONTEXT_S = 2.0`
    /// remains the first, optimistic candidate tried.)

    /// Pure gap-detection: given a segment timeline and total duration,
    /// returns every span wider than `gapThresholdSeconds` that has no
    /// segment covering it — including before the first segment and after
    /// the last. Extracted as its own function (rather than inlined in
    /// `repairTimelineGaps`) so it can be exercised directly by tests
    /// without needing a real WhisperKit decode.
    static func detectTimelineGaps(
        segments: [TranscriptionSegment], durationSeconds: Double,
        gapThresholdSeconds: Double
    ) -> [(start: Double, end: Double)] {
        guard durationSeconds > 0 else { return [] }
        let sorted = segments.sorted { $0.start < $1.start }

        var gaps: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for seg in sorted {
            if seg.start - cursor > gapThresholdSeconds {
                gaps.append((cursor, seg.start))
            }
            cursor = max(cursor, seg.end)
        }
        if durationSeconds - cursor > gapThresholdSeconds {
            gaps.append((cursor, durationSeconds))
        }
        return gaps
    }

    /// Detects only the trailing span after a timeline's *last* segment,
    /// using a much smaller threshold than the general
    /// `detectTimelineGaps` — specifically to catch a real, guaranteed
    /// failure mode confirmed by reading `TranscribeTask.run`'s own seek
    /// loop directly: `while seek < seekClipEnd - windowPadding`, where
    /// `windowPadding` defaults to `options.windowClipTime` (`1.0` second)
    /// worth of samples. WhisperKit deliberately never even attempts to
    /// decode the last ~1 second of *any* clip, on every single
    /// transcription — a small, universal tail loss with no equivalent
    /// anywhere in Clio's pipeline today (`no-transcribe`'s own tail
    /// handling, `TAIL_PAD_S`, solved a structurally different problem —
    /// stride right-context in the HuggingFace pipeline — and doesn't
    /// carry over). Deliberately a much smaller minimum than
    /// `detectTimelineGaps`' 5-second default: a ~1s loss would never
    /// trigger that threshold, so without this dedicated check it goes
    /// entirely unrepaired on every recording, every time.
    static func detectTrailingGap(
        segments: [TranscriptionSegment], durationSeconds: Double,
        minTrailingGapSeconds: Double = 0.3
    ) -> (start: Double, end: Double)? {
        guard durationSeconds > 0 else { return nil }
        let lastEnd = segments.map(\.end).max() ?? 0
        guard durationSeconds - lastEnd > minTrailingGapSeconds else { return nil }
        return (lastEnd, durationSeconds)
    }

    /// Pure timestamp remap + clamp for a single segment recovered by
    /// re-transcribing an isolated gap subclip. `extractSubClip` clamps its
    /// own start to `max(0, gap.start - padding)`, so this recomputes the
    /// same clamp to map the retry's subclip-relative timestamps back to
    /// absolute time, then clamps the result to the gap's own bounds so
    /// recovered speech from the context padding (which belongs to an
    /// already-transcribed neighboring segment) is excluded. Returns `nil`
    /// if the recovered span doesn't actually fall inside the gap at all.
    static func remapRecoveredSegment(
        relativeStart: Double, relativeEnd: Double,
        gap: (start: Double, end: Double), subclipPadding: Double
    ) -> (start: Double, end: Double)? {
        let clipStart = max(0.0, gap.start - subclipPadding)
        let absStart = clipStart + relativeStart
        let absEnd = clipStart + relativeEnd
        guard absEnd > gap.start, absStart < gap.end else { return nil }
        return (max(absStart, gap.start), min(absEnd, gap.end))
    }

    /// Attempts to recover real content for a single timeline gap by
    /// re-transcribing an isolated subclip of `wavURL`. Returns recovered,
    /// correctly-offset segments (empty if nothing recoverable). Shared by
    /// both the single-channel `repairTimelineGaps` (mono path) and the
    /// stereo-specific `repairMutualTimelineGaps` below.
    private func recoverGap(
        _ gap: (start: Double, end: Double), wavURL: URL, speakerLabel: String,
        language: String, verbatim: Bool
    ) async -> [TranscriptionSegment] {
        guard let candidate = await retryDecodeEscalating(
            wavURL: wavURL, start: gap.start, end: gap.end,
            speakerLabel: speakerLabel, language: language, verbatim: verbatim
        ) else { return [] }

        var recovered: [TranscriptionSegment] = []
        for seg in candidate.result.segments {
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text != NativeTranscriptionEngine.unclearAudioPlaceholder
            else { continue }
            guard let range = Self.remapRecoveredSegment(
                relativeStart: seg.start, relativeEnd: seg.end,
                gap: gap, subclipPadding: candidate.padding
            ) else { continue }
            recovered.append(TranscriptionSegment(
                id: 0, start: range.start, end: range.end,
                text: text, speaker: speakerLabel, confidence: seg.confidence,
                words: [], lowConfidence: seg.lowConfidence))
        }
        return recovered
    }

    private func repairTimelineGaps(
        _ segments: [TranscriptionSegment], wavURL: URL, speakerLabel: String,
        language: String, verbatim: Bool, durationSeconds: Double,
        gapThresholdSeconds: Double = 5.0
    ) async -> [TranscriptionSegment] {
        var gaps = Self.detectTimelineGaps(
            segments: segments, durationSeconds: durationSeconds,
            gapThresholdSeconds: gapThresholdSeconds)
        // Also catch WhisperKit's own deterministic ~1s tail-skip (see
        // `detectTrailingGap`'s doc comment) — too small to ever trigger
        // the 5s general threshold above, so it needs its own dedicated
        // check. Skipped if a general gap already covers the same span.
        if let trailing = Self.detectTrailingGap(segments: segments, durationSeconds: durationSeconds),
           !gaps.contains(where: { $0.start <= trailing.start && $0.end >= trailing.end }) {
            gaps.append(trailing)
        }
        guard !gaps.isEmpty else { return segments }

        var recovered: [TranscriptionSegment] = []
        for gap in gaps {
            recovered += await recoverGap(
                gap, wavURL: wavURL, speakerLabel: speakerLabel,
                language: language, verbatim: verbatim)
        }
        guard !recovered.isEmpty else { return segments }

        return (segments + recovered)
            .sorted { $0.start < $1.start }
            .enumerated()
            .map { idx, seg in
                TranscriptionSegment(
                    id: idx, start: seg.start, end: seg.end, text: seg.text,
                    speaker: seg.speaker, confidence: seg.confidence,
                    words: seg.words, lowConfidence: seg.lowConfidence)
            }
    }

    /// Stereo-specific gap fill: only repairs spans missing from BOTH
    /// channels at once. A gap on only one channel almost always just means
    /// the other person was speaking and that mic legitimately picked up
    /// nothing — repairing it independently risks re-decoding near-silence
    /// with `disableNoSpeechSkip` and inserting a hallucinated line that
    /// duplicates the other channel's already-correct segment for the same
    /// moment (reintroducing the exact duplicate-lines problem fixed
    /// earlier). Only a gap present in *both* channels' own timelines at
    /// once is genuinely unexplained. Tries the left channel's audio first,
    /// then the right, keeping whichever produces real content.
    private func repairMutualTimelineGaps(
        left: inout TranscriptionResult, right: inout TranscriptionResult,
        leftWavURL: URL, rightWavURL: URL,
        leftLabel: String, rightLabel: String,
        language: String, verbatim: Bool,
        gapThresholdSeconds: Double = 5.0
    ) async {
        let duration = max(left.durationSeconds, right.durationSeconds)
        let leftGaps = Self.detectTimelineGaps(
            segments: left.segments, durationSeconds: duration,
            gapThresholdSeconds: gapThresholdSeconds)
        let rightGaps = Self.detectTimelineGaps(
            segments: right.segments, durationSeconds: duration,
            gapThresholdSeconds: gapThresholdSeconds)

        var mutualGaps: [(start: Double, end: Double)] = []
        for lg in leftGaps {
            for rg in rightGaps {
                let start = max(lg.start, rg.start)
                let end = min(lg.end, rg.end)
                if end - start > gapThresholdSeconds {
                    mutualGaps.append((start, end))
                }
            }
        }

        // Also catch WhisperKit's own deterministic ~1s tail-skip on
        // BOTH channels at once (see `detectTrailingGap`'s doc comment) —
        // too small to survive the `gapThresholdSeconds` filter above, so
        // it needs its own dedicated, much smaller threshold. Both
        // channels share the same total duration, so their independent
        // trailing gaps are computed directly rather than via the
        // pairwise loop above (which would filter this out too).
        if let leftTrailing = Self.detectTrailingGap(segments: left.segments, durationSeconds: duration),
           let rightTrailing = Self.detectTrailingGap(segments: right.segments, durationSeconds: duration) {
            let start = max(leftTrailing.start, rightTrailing.start)
            let end = min(leftTrailing.end, rightTrailing.end)
            if end > start, !mutualGaps.contains(where: { $0.start <= start && $0.end >= end }) {
                mutualGaps.append((start, end))
            }
        }

        guard !mutualGaps.isEmpty else { return }

        for gap in mutualGaps {
            let fromLeft = await recoverGap(
                gap, wavURL: leftWavURL, speakerLabel: leftLabel,
                language: language, verbatim: verbatim)
            if !fromLeft.isEmpty {
                left.segments += fromLeft
                continue
            }
            let fromRight = await recoverGap(
                gap, wavURL: rightWavURL, speakerLabel: rightLabel,
                language: language, verbatim: verbatim)
            if !fromRight.isEmpty {
                right.segments += fromRight
            }
        }

        func renumber(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
            segments.sorted { $0.start < $1.start }.enumerated().map { idx, seg in
                TranscriptionSegment(
                    id: idx, start: seg.start, end: seg.end, text: seg.text,
                    speaker: seg.speaker, confidence: seg.confidence,
                    words: seg.words, lowConfidence: seg.lowConfidence)
            }
        }
        left.segments = renumber(left.segments)
        right.segments = renumber(right.segments)
    }

    /// Transcribes a single mono audio file via the native whisper.cpp engine.
    /// Replaces the old `no-transcribe` Python subprocess call — runs
    /// entirely in-process (GGML/Metal), so there is no sandbox entitlement
    /// conflict with the main app's own sandbox.
    private func runNative(
        audioFile: URL,
        speakers: Int,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String,
        accuracyLevel: TranscriptionAccuracyLevel = .default
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
        var result = try await WhisperCppEngine.shared.transcribe(
            wavPath: wavURL.path, language: language, speakerLabel: "SPEAKER_0",
            durationSeconds: duration, verbatim: verbatim,
            beamSize: accuracyLevel.beamSize, cancellationToken: currentCancellationToken)
        result.segments = await repairTimelineGaps(
            result.segments, wavURL: wavURL, speakerLabel: "SPEAKER_0",
            language: language, verbatim: verbatim, durationSeconds: duration)
        result.segments = await repairUnclearSegments(
            result.segments, wavURL: wavURL, speakerLabel: "SPEAKER_0",
            language: language, verbatim: verbatim, forceAll: accuracyLevel.proactiveConsensusRepair)
        applyValidation(to: &result, wavURL: wavURL)

        DispatchQueue.main.async {
            self.progress = 1.0
            self.stage = .complete
        }

        return result
    }


    // MARK: - Native mono transcription (stereo-split path)

    /// WAV-conversion + raw whisper.cpp transcription only, for one channel —
    /// no repair, no validation. Extracted so the stereo orchestrator can
    /// run cross-talk tightening/dedup on the RAW segments first and only
    /// repair gaps/placeholders afterward (see `runStereoTranscription`'s
    /// own doc comment for why the order matters), while `runNativeMono`
    /// below still does repair+validate inline for its other caller (the
    /// merged-channels fallback, which has no subsequent dedup step to
    /// worry about). Caller owns `wavURL` cleanup.
    private func transcribeChannelRaw(
        audioFile: URL, speakerLabel: String, model: TranscriptionModel,
        verbatim: Bool, language: String, accuracyLevel: TranscriptionAccuracyLevel = .default
    ) async throws -> (result: TranscriptionResult, wavURL: URL) {
        let wavURL: URL
        do {
            wavURL = try AudioWAVConverter.convertToWAV(sourceURL: audioFile)
        } catch let error as AudioWAVConverterError {
            throw TranscriptionError.processFailed(error.errorDescription ?? "WAV-konvertering feilet")
        }
        let duration = await audioDuration(url: wavURL)
        let result = try await WhisperCppEngine.shared.transcribe(
            wavPath: wavURL.path, language: language, speakerLabel: speakerLabel,
            durationSeconds: duration, verbatim: verbatim,
            beamSize: accuracyLevel.beamSize, cancellationToken: currentCancellationToken)
        return (result, wavURL)
    }

    /// Runs the native whisper.cpp engine on a single mono M4A (one RØDE
    /// channel), including repair and validation. Does NOT update
    /// `stage`/`progress` — those are managed by the outer stereo
    /// orchestrator. All returned segments are labelled `speakerLabel`.
    ///
    /// Only used by the merged-channels fallback path (a single pass with
    /// no subsequent cross-talk dedup to interact with). The normal
    /// dual-channel path calls `transcribeChannelRaw` directly instead —
    /// see `runStereoTranscription`.
    private func runNativeMono(
        audioFile: URL,
        speakerLabel: String,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String,
        accuracyLevel: TranscriptionAccuracyLevel = .default
    ) async throws -> TranscriptionResult {
        let (raw, wavURL) = try await transcribeChannelRaw(
            audioFile: audioFile, speakerLabel: speakerLabel,
            model: model, verbatim: verbatim, language: language, accuracyLevel: accuracyLevel)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        var result = raw

        result.segments = await repairTimelineGaps(
            result.segments, wavURL: wavURL, speakerLabel: speakerLabel,
            language: language, verbatim: verbatim, durationSeconds: result.durationSeconds)
        result.segments = await repairUnclearSegments(
            result.segments, wavURL: wavURL, speakerLabel: speakerLabel,
            language: language, verbatim: verbatim, forceAll: accuracyLevel.proactiveConsensusRepair)
        applyValidation(to: &result, wavURL: wavURL)

        result.metadata.diarizationRun = true  // channel split IS our diarization
        return result
    }

    // MARK: - Stereo pipeline orchestrator

    private func runStereoTranscription(
        audioFile: URL,
        meta: ClioMeta,
        model: TranscriptionModel,
        verbatim: Bool,
        language: String,
        accuracyLevel: TranscriptionAccuracyLevel = .default
    ) async throws -> TranscriptionResult {

        // Real bug found via a live user report ("transcription isn't
        // stopping"): this whole function previously never touched
        // `self.progress`/`self.stage` at all, unlike the mono path
        // (`runNative`). Since `TranscriptionRunner` mirrors this
        // service's `$progress` publisher straight into the UI, the
        // progress indicator sat frozen at its initial 0% for the ENTIRE
        // stereo pipeline. Confirmed via direct benchmark against the
        // user's own real ~35-minute interview recording that whisper.cpp
        // itself decodes it in ~4 minutes (not slow) — the pipeline was
        // genuinely working the whole time, just invisibly. These
        // `DispatchQueue.main.async` updates mirror `runNative`'s existing
        // pattern, extended to every stage of the stereo orchestration so
        // the UI shows real, visible movement throughout a run that can
        // legitimately take many minutes on a real interview.
        DispatchQueue.main.async {
            self.stage = .transcribing
            self.progress = 0.05
        }

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

        DispatchQueue.main.async { self.progress = 0.1 }

        // Step 1b: detect a real, discovered-in-the-field hardware
        // misconfiguration — the RØDE capture app set to "merge" rather
        // than "split" channel mode, which sums both mics to one mono
        // signal duplicated onto both stereo channels before Clio ever
        // sees the file. No amount of software-side energy analysis can
        // separate speakers once this has happened, and running two full
        // transcriptions of literally the same audio is both wasteful and
        // produces a meaningless duplicate-everything "diarization". Fall
        // back to a single mono pass and flag it clearly instead.
        if let energy = try? StereoSplitter.analyzeChannelEnergy(sourceURL: audioFile),
           StereoSplitter.isLikelyMergedChannels(energy) {
            AuditLogger.shared.log(.transcriptionMergedChannelsDetected, payload: [
                "sourceFile": .string(audioFile.lastPathComponent),
            ])

            var mono = try await runNativeMono(
                audioFile: leftURL, speakerLabel: "SPEAKER_0",
                model: model, verbatim: verbatim, language: language, accuracyLevel: accuracyLevel)
            mono.metadata.diarizationRun = false

            let mergedChannelsIssue = TranscriptValidationIssue(
                kind: .mergedChannelsDetected, start: nil, end: nil,
                detail: "Begge lydkanaler inneholder identisk lyd — RØDE-appen er trolig satt til "
                    + "\"slå sammen\" i stedet for \"del opp\" kanaler. Talerutskilling er ikke mulig "
                    + "for dette opptaket; sjekk kanalinnstillingen før neste opptak.")
            let issues = [mergedChannelsIssue] + (mono.validation?.issues ?? [])
            mono.validation = TranscriptValidation.summarize(issues: issues)

            DispatchQueue.main.async {
                self.progress = 1.0
                self.stage = .complete
            }
            return mono
        }

        // Step 2: transcribe each channel (raw, no repair yet — see the
        // ordering note above Step 2d for why repair must come after
        // tightening/dedup, not before). Both calls target the same
        // WhisperCppEngine actor, so they naturally serialize on the
        // underlying GPU/Metal model instance — matches the GPU-bound
        // serialization behavior of the old subprocess path.
        async let leftRaw = transcribeChannelRaw(
            audioFile: leftURL, speakerLabel: meta.resolvedLeft,
            model: model, verbatim: verbatim, language: language, accuracyLevel: accuracyLevel)
        async let rightRaw = transcribeChannelRaw(
            audioFile: rightURL, speakerLabel: meta.resolvedRight,
            model: model, verbatim: verbatim, language: language, accuracyLevel: accuracyLevel)

        var (left, right): (TranscriptionResult, TranscriptionResult)
        let (leftWavURL, rightWavURL): (URL, URL)
        do {
            let (l, r) = try await (leftRaw, rightRaw)
            (left, leftWavURL) = l
            (right, rightWavURL) = r
        } catch {
            AuditLogger.shared.log(.transcriptionStereoSplitFailed, payload: [
                "errorType":    .string("transcription"),
                "errorMessage": .string(error.localizedDescription),
            ])
            throw error
        }
        defer {
            try? FileManager.default.removeItem(at: leftWavURL)
            try? FileManager.default.removeItem(at: rightWavURL)
        }

        // Main decode pass (both channels) is the single most time-consuming
        // step for a real, full-length interview — jump progress forward
        // substantially here so the indicator visibly moves once it lands,
        // rather than sitting at 0.1 for the whole multi-minute decode.
        DispatchQueue.main.async { self.progress = 0.6 }

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
                        words: seg.words,
                        lowConfidence: seg.lowConfidence)
                }
            }

            left.segments = tighten(left.segments, side: .left)
            right.segments = tighten(right.segments, side: .right)

            AuditLogger.shared.log(.transcriptionStereoSplitCompleted, payload: [
                "stage":           .string("crossTalkFilter"),
                "leftDropped":     .int(leftBefore - left.segments.count),
                "rightDropped":    .int(rightBefore - right.segments.count),
            ])

            // Step 2c: cross-channel deduplication. Per-channel dominance
            // (above) only checks each segment against its OWN channel's
            // nominal span — it does not stop the same real utterance
            // from independently passing on BOTH channels when the RØDE
            // transmitters pick it up at comparable volume, which shows
            // up as the same line duplicated under both speaker labels.
            // This asks the direct question instead: for any pair of
            // segments (one per channel) that still overlap after
            // tightening, which channel was actually louder over that
            // specific overlap, and does either side's text turn out to
            // be a hallucinated placeholder the other channel actually
            // transcribed? See `StereoSplitter.deduplicateCrossTalk`.
            let dedupBeforeLeft = left.segments.count
            let dedupBeforeRight = right.segments.count
            let deduped = StereoSplitter.deduplicateCrossTalk(
                left: left.segments, right: right.segments, energy: energy)
            left.segments = deduped.left
            right.segments = deduped.right

            AuditLogger.shared.log(.transcriptionStereoSplitCompleted, payload: [
                "stage":           .string("crossChannelDedup"),
                "leftDropped":     .int(dedupBeforeLeft - left.segments.count),
                "rightDropped":    .int(dedupBeforeRight - right.segments.count),
            ])
        }

        // Step 2d: repair gaps and unclear placeholders — deliberately AFTER
        // tightening/dedup above, not before (this was a real bug found and
        // fixed the same day it was introduced): both `dominantRange`
        // tightening and `deduplicateCrossTalk` can legitimately discard a
        // segment for a span where energy is quiet/ambiguous on both
        // channels — which is exactly the kind of audio that caused
        // WhisperKit's own no-speech skip to produce an empty gap in the
        // first place. Running repair *before* those steps meant a segment
        // this code had just gone out of its way to recover could be
        // deleted right back out by the very next stage, silently
        // reproducing the original gap. Running repair last means recovered
        // content is never re-litigated by cross-talk logic afterward.
        // Uses `repairMutualTimelineGaps` (only spans missing from BOTH
        // channels at once), not independent per-channel gap fill — see its
        // own doc comment for why a one-sided gap must be left alone.
        DispatchQueue.main.async {
            self.stage = .diarizing
            self.progress = 0.7
        }
        await repairMutualTimelineGaps(
            left: &left, right: &right,
            leftWavURL: leftWavURL, rightWavURL: rightWavURL,
            leftLabel: meta.resolvedLeft, rightLabel: meta.resolvedRight,
            language: language, verbatim: verbatim)
        DispatchQueue.main.async { self.progress = 0.8 }
        left.segments = await repairUnclearSegments(
            left.segments, wavURL: leftWavURL, speakerLabel: meta.resolvedLeft,
            language: language, verbatim: verbatim, forceAll: accuracyLevel.proactiveConsensusRepair)
        DispatchQueue.main.async { self.progress = 0.9 }
        right.segments = await repairUnclearSegments(
            right.segments, wavURL: rightWavURL, speakerLabel: meta.resolvedRight,
            language: language, verbatim: verbatim, forceAll: accuracyLevel.proactiveConsensusRepair)
        DispatchQueue.main.async { self.progress = 0.95 }
        applyValidation(to: &left, wavURL: leftWavURL)
        applyValidation(to: &right, wavURL: rightWavURL)
        left.metadata.diarizationRun = true
        right.metadata.diarizationRun = true

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

        DispatchQueue.main.async {
            self.progress = 1.0
            self.stage = .complete
        }

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
                    words: seg.words,
                    lowConfidence: seg.lowConfidence)
            }

        // Build combined metadata from the left result (representative)
        var metadata = left.metadata
        metadata.diarizationRun = true

        // Each channel was validated independently in `runNativeMono` (its
        // own audio energy, its own segments) — combine both issue lists
        // and re-derive score/summary over the union, rather than reusing
        // either channel's score/summary in isolation, so a problem
        // confined to just one RØDE transmitter's channel still shows up
        // in the merged transcript's overall validation.
        let validation: TranscriptValidationSummary? = {
            switch (left.validation, right.validation) {
            case (nil, nil): return nil
            case (let l?, nil): return l
            case (nil, let r?): return r
            case (let l?, let r?): return TranscriptValidation.summarize(issues: l.issues + r.issues)
            }
        }()

        return TranscriptionResult(
            version: left.version,
            model: left.model,
            language: left.language,
            durationSeconds: max(left.durationSeconds, right.durationSeconds),
            numSpeakers: 2,
            segments: segments,
            metadata: metadata,
            validation: validation)
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

    /// True if the bundled whisper.cpp GGML model is present in the app bundle.
    /// With the native pipeline there is nothing to install or download —
    /// the model ships inside the app — so this simply reflects bundle
    /// presence rather than a pip/venv installation state.
    private func isModelCached(_ model: TranscriptionModel) -> Bool {
        WhisperCppEngine.isBundled
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
