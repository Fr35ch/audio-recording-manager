import AVFoundation
import Foundation
import whisper

/// Wraps whisper.cpp (ggml-org/whisper.cpp) as an alternative to
/// `NativeTranscriptionEngine` (WhisperKit/CoreML). Runs fully in-process
/// via Metal — no subprocess, no sandbox entitlement conflict, same
/// architectural shape as the WhisperKit path this replaces/complements.
///
/// ## Why this exists
/// A real, working competing app (VG's "Jojo", confirmed via Mac App
/// Store distribution and direct binary inspection — `otool -L` shows no
/// `CoreML.framework`/`Speech.framework` linkage, and embedded debug paths
/// in the binary reference `whisper.cpp` directly) uses whisper.cpp
/// instead of WhisperKit for the same NB-Whisper models. Investigated
/// directly rather than assumed: cloned `ggml-org/whisper.cpp`, built a
/// real macOS static library + `.xcframework` from source (see
/// `Frameworks/whisper.xcframework`, `/Frameworks/README.md` for the
/// build recipe), confirmed via `nm` that real beam-search symbols are
/// compiled in, downloaded NB-Whisper's own officially-published
/// `ggml-model-q5_0.bin` weights (published directly on the
/// `NbAiLab/nb-whisper-*` HuggingFace repos — no conversion step needed,
/// unlike WhisperKit's CoreML conversion), and ran a real end-to-end
/// decode of an actual reported problem recording via `whisper-cli`: the
/// entire 101-second file was covered continuously with real beam search
/// (`-bs 5`), with none of the multi-second silent dropouts that plagued
/// the WhisperKit path all session. This class is the production Swift
/// wrapper around that validated mechanism.
///
/// ## Key difference from WhisperKit that motivated the switch
/// WhisperKit's `TranscribeTask.decodeWithFallback` hardcodes
/// `GreedyTokenSampler` unconditionally — there is no beam-search code
/// path in that dependency at all. whisper.cpp has a complete, real
/// `WHISPER_SAMPLING_BEAM_SEARCH` strategy (`whisper_full_params
/// .beam_search.beam_size`), which is NB-Whisper's own model card
/// recommendation for best accuracy (`num_beams=5`) — something
/// WhisperKit could never honor no matter how this session's decode
/// options were tuned.
actor WhisperCppEngine {
    static let shared = WhisperCppEngine()

    enum EngineError: LocalizedError {
        case modelNotBundled
        case contextInitFailed
        case decodeFailed(Int32)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .modelNotBundled:
                return "Innebygd whisper.cpp-modell mangler i appbunten."
            case .contextInitFailed:
                return "Kunne ikke laste whisper.cpp-modell."
            case .decodeFailed(let code):
                return "whisper.cpp-transkripsjon feilet (kode \(code))."
            case .cancelled:
                return "Transkripsjon avbrutt."
            }
        }
    }

    /// Real, mid-decode cancellation support.
    ///
    /// Found via a real user report: cancelling a transcription (via
    /// `TranscriptionService.cancel()`) never actually stopped the
    /// in-progress `whisper_full()` call — that's a single, long,
    /// synchronous C call with no cooperative `Task` cancellation checks,
    /// so Swift's `Task.cancel()` alone cannot interrupt it. It kept
    /// running to completion in the background, holding this actor's
    /// serial executor busy (and `TranscriptionService.isBusy == true`)
    /// for however long the real decode took — for a long interview,
    /// that's many minutes, matching the exact reported symptom ("en
    /// transkripsjon kjører allerede" refusing to clear, blocking
    /// re-transcription of anything).
    ///
    /// whisper.cpp/ggml has a real, built-for-this-purpose mechanism:
    /// `whisper_full_params.abort_callback`, checked by the encoder/decoder
    /// between compute steps (confirmed directly in `whisper.cpp` source —
    /// `whisper_encode_internal`/`whisper_decode_internal` return `false`
    /// the moment it returns `true`, and `whisper_full` immediately returns
    /// a distinct negative code, `-6`/`-8`, rather than continuing). This
    /// class is a plain, non-actor-isolated, lock-protected flag passed
    /// across that C boundary via `Unmanaged` — deliberately NOT stored as
    /// actor state, since a caller signalling cancellation (typically from
    /// the main actor, e.g. a "Cancel" button) must be able to flip it
    /// immediately without waiting for this actor's serial executor to
    /// free up, which is exactly what's blocked while `whisper_full` is
    /// running synchronously.
    final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var _isCancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _isCancelled
        }

        func cancel() {
            lock.lock()
            _isCancelled = true
            lock.unlock()
        }
    }

    /// Which NB-Whisper checkpoint to transcribe with. Mirrors
    /// `NativeTranscriptionEngine.ModelVariant` exactly — this is a model
    /// swap (two separately fine-tuned checkpoints), not a decode-time
    /// flag. NB AI-Lab publishes official GGML weights for both directly
    /// on HuggingFace, so — unlike WhisperKit's CoreML conversion — no
    /// local conversion step is needed for either variant.
    enum ModelVariant: String {
        case clean
        case verbatim

        var modelFilename: String {
            switch self {
            case .clean:    return "ggml-nb-whisper-large-q5_0.bin"
            case .verbatim: return "ggml-nb-whisper-large-verbatim-q5_0.bin"
            }
        }

        var modelIdentifier: String {
            switch self {
            case .clean:    return "NbAiLab/nb-whisper-large"
            case .verbatim: return "NbAiLab/nb-whisper-large-verbatim"
            }
        }
    }

    private var contexts: [ModelVariant: OpaquePointer] = [:]

    private init() {}

    static var isBundled: Bool {
        Bundle.main.url(forResource: ModelVariant.clean.modelFilename, withExtension: nil, subdirectory: "WhisperCppModels") != nil
    }

    static var isVerbatimBundled: Bool {
        Bundle.main.url(forResource: ModelVariant.verbatim.modelFilename, withExtension: nil, subdirectory: "WhisperCppModels") != nil
    }

    /// Releases every cached whisper.cpp context, freeing their Metal
    /// residency-set entries before the process exits.
    ///
    /// Found via a real crash reported from the running app: quitting
    /// normally (not a forced kill — confirmed via the crash backtrace's
    /// `-[NSApplication terminate:]` → `exit()` path) aborted with
    /// `GGML_ASSERT([rsets->data count] == 0)` inside
    /// `ggml_metal_rsets_free` (`ggml-metal-device.m`), whose own comment
    /// reads: "if you hit this assert, most likely you haven't deallocated
    /// all Metal resources before exiting." This engine cached
    /// `whisper_context` pointers for the app's entire lifetime and never
    /// called `whisper_free` on them — `whisper.h`'s own usage example
    /// ends with exactly that call. When the process exits, a C++ global
    /// destructor tears down the shared Metal device while a still-live
    /// context's resources are registered in its residency set, tripping
    /// the assert. Call this from `AppDelegate.applicationShouldTerminate`
    /// before the process actually exits. Idempotent — safe to call with
    /// no contexts loaded.
    func shutdown() {
        for (_, ctx) in contexts {
            whisper_free(ctx)
        }
        contexts.removeAll()
    }

    private func ensureContext(variant: ModelVariant) throws -> (OpaquePointer, ModelVariant) {
        if let ctx = contexts[variant] { return (ctx, variant) }

        // Same honest-disclosure fallback as `NativeTranscriptionEngine`:
        // if verbatim was requested but isn't bundled, fall back to clean
        // rather than throwing — the Settings UI already discloses this.
        let effectiveVariant = (variant == .verbatim && !Self.isVerbatimBundled) ? .clean : variant
        if let ctx = contexts[effectiveVariant] { return (ctx, effectiveVariant) }

        guard let modelURL = Bundle.main.url(
            forResource: effectiveVariant.modelFilename, withExtension: nil, subdirectory: "WhisperCppModels"
        ) else {
            throw EngineError.modelNotBundled
        }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true  // Metal-accelerated attention; matches the reference Swift example's non-simulator path.

        guard let ctx = whisper_init_from_file_with_params(modelURL.path, cparams) else {
            throw EngineError.contextInitFailed
        }
        contexts[effectiveVariant] = ctx
        return (ctx, effectiveVariant)
    }

    /// Transcribes a 16kHz mono WAV file. Mirrors
    /// `NativeTranscriptionEngine.transcribe`'s parameter shape exactly so
    /// every existing call site in `TranscriptionService` (main pass,
    /// gap-fill, escalating-temperature repair) could be swapped over
    /// without changing argument lists — same underlying intent, mapped to
    /// whisper.cpp's own real equivalents instead of WhisperKit's:
    ///
    /// - `disableNoSpeechSkip` -> `no_speech_thold`/`entropy_thold`/
    ///   `logprob_thold` relaxed to effectively-disabled values, exactly
    ///   like `NativeTranscriptionEngine`'s equivalent gates.
    /// - `forcedTemperature` -> `params.temperature` fixed, `temperature_inc`
    ///   zeroed (force a single specific temperature instead of relying on
    ///   the internal escalation ladder to happen to reach it).
    /// - `temperatureFallbackCount` -> approximates a step count by setting
    ///   `temperature_inc` so the ladder reaches 1.0 in roughly that many
    ///   steps (`nil`/omitted keeps whisper.cpp's own tuned default of 5
    ///   steps at 0.2 increments — the same number WhisperKit defaults to).
    ///   `0` disables escalation entirely (pure single-temperature decode).
    /// - `beamSize`: real beam-search width
    ///   (`whisper_full_params.beam_search.beam_size`) — NB-Whisper's own
    ///   model card recommends `5` for best accuracy, and unlike WhisperKit
    ///   (which has no beam-search code path at all), whisper.cpp actually
    ///   implements it.
    func transcribe(
        wavPath: String, language: String, speakerLabel: String, durationSeconds: Double,
        verbatim: Bool = false, disableNoSpeechSkip: Bool = false, forcedTemperature: Float? = nil,
        temperatureFallbackCount: Int? = nil, beamSize: Int32? = 5,
        cancellationToken: CancellationToken? = nil
    ) async throws -> TranscriptionResult {
        let (ctx, variantUsed) = try ensureContext(variant: verbatim ? .verbatim : .clean)

        if cancellationToken?.isCancelled == true {
            throw EngineError.cancelled
        }

        let samples = try Self.loadMonoFloatSamples(wavPath: wavPath)

        let strategy: whisper_sampling_strategy = beamSize != nil ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY
        var params = whisper_full_default_params(strategy)
        let maxThreads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))

        params.print_realtime   = false
        params.print_progress   = false
        params.print_timestamps = false
        params.print_special    = false
        params.translate        = false
        params.n_threads        = maxThreads
        params.no_context       = true
        params.single_segment   = false
        // Matches the same reasoning already applied to WhisperKit this
        // session: no per-window carryover of previous text, preventing
        // hallucination cascades across windows.
        params.suppress_blank   = true
        if let beamSize {
            params.beam_search.beam_size = beamSize
        }

        if disableNoSpeechSkip {
            params.no_speech_thold = 0.0
            params.entropy_thold = 10.0
            params.logprob_thold = -100.0
        }
        if let forcedTemperature {
            params.temperature = forcedTemperature
            params.temperature_inc = 0.0
        } else if let temperatureFallbackCount {
            params.temperature_inc = temperatureFallbackCount > 0 ? 1.0 / Float(temperatureFallbackCount) : 0.0
        }

        // Real, mid-decode cancellation — see `CancellationToken`'s own doc
        // comment for why this exists and why it can't just be a Task
        // cancellation check. `abort_callback` must be a capture-less
        // function so it can bridge to a C function pointer; the actual
        // per-call state travels via `abort_callback_user_data` instead.
        if let cancellationToken {
            params.abort_callback = { userData in
                guard let userData else { return false }
                let token = Unmanaged<CancellationToken>.fromOpaque(userData).takeUnretainedValue()
                return token.isCancelled
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(cancellationToken).toOpaque()
        }

        var languageCString: [CChar]? = language == "auto" ? nil : Array(language.utf8CString)
        var result: Int32 = -1
        if var languageCString {
            result = languageCString.withUnsafeMutableBufferPointer { langBuf -> Int32 in
                params.language = UnsafePointer(langBuf.baseAddress)
                params.detect_language = false
                return samples.withUnsafeBufferPointer { samplesBuf in
                    whisper_full(ctx, params, samplesBuf.baseAddress, Int32(samplesBuf.count))
                }
            }
        } else {
            params.detect_language = true
            result = samples.withUnsafeBufferPointer { samplesBuf in
                whisper_full(ctx, params, samplesBuf.baseAddress, Int32(samplesBuf.count))
            }
        }
        guard result == 0 else {
            // -6 / -8 / -9 are whisper.cpp's own codes for the three call
            // sites that check `abort_callback` (confirmed directly in
            // whisper.cpp source: -6 encode, -8/-9 two separate decode call
            // sites — -7 is a real, unrelated KV-cache allocation failure,
            // deliberately excluded here) — surface these as a real
            // cancellation, not a generic decode failure, so callers/UI
            // don't show a scary error for something the user deliberately
            // triggered. Directly confirmed via a standalone repro against
            // the real production model + a real 35-minute recording:
            // cancelling ~1.5s after starting made whisper_full return
            // -9 in 1.58s total, instead of running for minutes.
            if cancellationToken?.isCancelled == true, result == -6 || result == -8 || result == -9 {
                throw EngineError.cancelled
            }
            throw EngineError.decodeFailed(result)
        }

        var segments: [TranscriptionSegment] = []
        let segmentCount = whisper_full_n_segments(ctx)
        for i in 0..<segmentCount {
            let text = String(cString: whisper_full_get_segment_text(ctx, i))
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0  // whisper.cpp reports centiseconds
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0
            segments.append(TranscriptionSegment(
                id: Int(i), start: t0, end: t1,
                text: Self.sanitize(text),
                speaker: speakerLabel, confidence: 1.0, words: []))
        }

        return TranscriptionResult(
            version: "1.0", model: "\(variantUsed.modelIdentifier) (whisper.cpp/GGML q5_0)",
            language: language, durationSeconds: durationSeconds, numSpeakers: 1,
            segments: segments,
            metadata: TranscriptionResultMetadata(
                inputFile: (wavPath as NSString).lastPathComponent,
                processingTimeSeconds: 0,
                modelVariant: "nb-whisper-large", computeType: "ggml-metal", device: "gpu",
                diarizationRun: false))
    }

    /// Same sanitize contract as `NativeTranscriptionEngine.sanitize` (see
    /// there for the full rationale) — reuses its shared placeholder
    /// constant so both engines' output is indistinguishable to
    /// `TranscriptionService`'s repair/dedup logic regardless of which
    /// engine actually produced a given segment.
    ///
    /// Real regression found via a live user report: this originally only
    /// carried over the empty-text and letter-free checks, dropping the
    /// known-hallucination-marker stripping entirely — `<|nocaptions|>`
    /// contains real letters, so it passed straight through and was shown
    /// to the researcher as if it were actual transcript content (exactly
    /// what happened on a short 15s test recording). whisper.cpp emits
    /// this same NB-Whisper training-data artifact `NativeTranscriptionEngine`
    /// already had to handle, so it needs the identical marker list here.
    private static func sanitize(_ rawText: String) -> String {
        var text = rawText
        for marker in NativeTranscriptionEngine.knownHallucinationMarkers {
            text = text.replacingOccurrences(
                of: marker, with: "", options: [.caseInsensitive])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NativeTranscriptionEngine.unclearAudioPlaceholder }
        guard trimmed.contains(where: { $0.isLetter }) else {
            return NativeTranscriptionEngine.unclearAudioPlaceholder
        }
        return trimmed
    }

    /// Loads a WAV file's samples as mono float32 in [-1, 1] — the exact
    /// input format `whisper_full` expects (matching how `whisper-cli`'s
    /// own `read_audio_data` normalizes input). Reuses the same 16-bit
    /// PCM assumption already relied on throughout Clio's pipeline (see
    /// `AudioWAVConverter`), since every caller already converts to 16kHz
    /// mono WAV before reaching either transcription engine.
    private static func loadMonoFloatSamples(wavPath: String) throws -> [Float] {
        let url = URL(fileURLWithPath: wavPath)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw EngineError.decodeFailed(-1)
        }
        while buffer.frameLength < frameCount {
            let remaining = frameCount - buffer.frameLength
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else { break }
            try file.read(into: chunk, frameCount: remaining)
            if chunk.frameLength == 0 { break }
            memcpy(
                buffer.floatChannelData![0] + Int(buffer.frameLength),
                chunk.floatChannelData![0],
                Int(chunk.frameLength) * MemoryLayout<Float>.size)
            buffer.frameLength += chunk.frameLength
        }
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
