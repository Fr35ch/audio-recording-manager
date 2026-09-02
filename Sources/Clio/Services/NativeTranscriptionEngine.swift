import Foundation
import WhisperKit

/// Wraps WhisperKit (on-device CoreML speech-to-text) as a drop-in
/// replacement for the `no-transcribe` Python subprocess bridge.
///
/// Runs fully in-process via CoreML/ANE — no child executable, no sandbox
/// entitlement conflict. Two model variants can be bundled:
///   - `NbAiLab_nb-whisper-large` ("clean"): the official main checkpoint,
///     which corrects grammar and omits filler words/hesitations.
///   - `NbAiLab_nb-whisper-large-verbatim` ("verbatim"): a separate
///     checkpoint (fine-tuned 200-250 further steps by NB AI-Lab
///     specifically to preserve fillers, hesitations, and false starts
///     literally, lower-cased, without punctuation correction) — this is
///     a genuinely different set of model weights, not a decode-time flag.
/// Converted via `whisperkittools` (see `docs/MODEL_SETUP.md` for the
/// conversion recipe for both variants). Only the clean model has been
/// converted/bundled so far; `ensureLoaded(variant:)` falls back to it
/// with a clear error surfaced via `verbatimModelMissing` if verbatim is
/// requested but not bundled, rather than silently ignoring the setting
/// or crashing.
actor NativeTranscriptionEngine {
    static let shared = NativeTranscriptionEngine()

    /// Which NB-Whisper checkpoint to transcribe with. See type-level doc
    /// for why this is a model swap, not a decode option.
    enum ModelVariant: String {
        case clean
        case verbatim

        var folderName: String {
            switch self {
            case .clean:    return "NbAiLab_nb-whisper-large"
            case .verbatim: return "NbAiLab_nb-whisper-large-verbatim"
            }
        }

        var modelIdentifier: String {
            switch self {
            case .clean:    return "NbAiLab/nb-whisper-large"
            case .verbatim: return "NbAiLab/nb-whisper-large-verbatim"
            }
        }
    }

    private var pipes: [ModelVariant: WhisperKit] = [:]
    private var loadErrors: [ModelVariant: Error] = [:]

    private init() {}

    private static func modelFolderURL(for variant: ModelVariant) -> URL? {
        Bundle.main.url(forResource: variant.folderName, withExtension: nil, subdirectory: "WhisperKitModels")
    }

    private static func tokenizerFolderURL(for variant: ModelVariant) -> URL? {
        modelFolderURL(for: variant)?.appendingPathComponent("tokenizer")
    }

    /// True once the bundled *clean* model folder is present in the app
    /// bundle (Clio's minimum requirement — transcription is unavailable
    /// at all without at least this one). Does not guarantee the model
    /// has loaded successfully yet — call `ensureLoaded()` for that.
    static var isBundled: Bool {
        modelFolderURL(for: .clean) != nil
    }

    /// True once the bundled *verbatim* model folder is present. Until
    /// someone runs the conversion recipe in `docs/MODEL_SETUP.md` for
    /// this variant, this is `false` and verbatim mode transparently
    /// falls back to the clean model.
    static var isVerbatimBundled: Bool {
        modelFolderURL(for: .verbatim) != nil
    }

    private func ensureLoaded(variant requestedVariant: ModelVariant) async throws -> (WhisperKit, ModelVariant) {
        // Fall back to the clean model if verbatim was requested but was
        // never bundled — logged (not a real failure, transcription still
        // succeeds) rather than either crashing or silently pretending
        // verbatim ran.
        let variant: ModelVariant = (requestedVariant == .verbatim && !Self.isVerbatimBundled)
            ? .clean : requestedVariant
        if requestedVariant == .verbatim && variant == .clean {
            print("⚠️ NativeTranscriptionEngine: verbatim model not bundled, falling back to clean model — see docs/MODEL_SETUP.md")
        }

        if let pipe = pipes[variant] { return (pipe, variant) }
        if let loadError = loadErrors[variant] { throw loadError }

        guard let modelFolder = Self.modelFolderURL(for: variant) else {
            let error = TranscriptionError.processFailed("Innebygd NB-Whisper-modell mangler i appbunten.")
            self.loadErrors[variant] = error
            throw error
        }

        do {
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: Self.tokenizerFolderURL(for: variant),
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let newPipe = try await WhisperKit(config)
            self.pipes[variant] = newPipe
            return (newPipe, variant)
        } catch {
            self.loadErrors[variant] = error
            throw TranscriptionError.processFailed("Kunne ikke laste NB-Whisper-modell: \(error.localizedDescription)")
        }
    }

    /// Transcribes a 16kHz mono WAV file and returns Clio's own
    /// `TranscriptionResult` model (same contract the Python `no-transcribe`
    /// bridge used to produce), with every segment's speaker set to
    /// `speakerLabel` (diarization, when it runs, overwrites this afterward
    /// — same convention as the old subprocess path).
    ///
    /// `language` is normally a fixed code ("no"/"nn") — Clio's primary use
    /// case is single-language Norwegian interviews, and forcing the
    /// language generally improves accuracy for that case. Pass the
    /// sentinel value `"auto"` (surfaced in Settings as "Auto / blandet
    /// språk") to instead let WhisperKit detect the language per segment —
    /// needed for genuinely mixed-language recordings, where forcing one
    /// language causes the model to garble or give up on segments spoken
    /// in the other language (observed as literal, non-special-token
    /// placeholder text like "<|nocaptions|>" leaking into the output —
    /// a known Whisper-family hallucination pattern for audio that
    /// doesn't match the forced language, not a bug in this decode path).
    ///
    /// `verbatim` selects the fine-tuned verbatim checkpoint (see type-level
    /// doc) instead of the default clean one — falls back to the clean
    /// model if the verbatim variant hasn't been bundled yet.
    func transcribe(
        wavPath: String, language: String, speakerLabel: String, durationSeconds: Double,
        verbatim: Bool = false, disableNoSpeechSkip: Bool = false, forcedTemperature: Float? = nil,
        temperatureFallbackCount: Int? = nil
    ) async throws -> TranscriptionResult {
        let (whisperKit, variantUsed) = try await ensureLoaded(variant: verbatim ? .verbatim : .clean)

        var options = DecodingOptions()
        if language == "auto" {
            options.language = nil
            options.detectLanguage = true
        } else {
            options.language = language
            options.detectLanguage = false
        }
        // Deliberately OFF. The old Python `no-transcribe` pipeline
        // (navt.py) never produced word-level timestamps at all — its
        // own comments record that HuggingFace's word-level extraction
        // was "very experimental" and caused hallucinated filler words
        // ("Ok.", "Så") spanning 5-22s at chunk boundaries, so it stuck
        // to sentence-level timestamps for the main pass. WhisperKit's
        // word-timestamp path is architecturally different (DTW-style
        // alignment, not a post-hoc heuristic) but has a similar sharp
        // edge that's worse than a plain accuracy trade-off: per
        // `TranscribeTask.swift`, when `wordTimestamps` is on, the seek
        // position for the *next* decode window is recomputed from the
        // last aligned word's end time instead of the raw segment
        // timestamp token. If that alignment is off for noisy/cross-talk
        // audio (exactly the RØDE two-transmitter case), the next
        // window can start in the wrong place — skipped or duplicated
        // audio, matching exactly what was reported. Leaving this off
        // restores the old pipeline's behavior exactly: `segment.words`
        // is always empty, which `TranscriptEditorView`'s word-flow
        // rendering already treats as the normal case (single hit
        // target per segment) — nothing regresses, since the karaoke
        // word-highlight UI was never exercised end-to-end before the
        // WhisperKit port anyway.
        options.wordTimestamps = false
        options.task = .transcribe
        options.usePrefillPrompt = true
        // Without this, per-segment `text` includes raw special tokens
        // (<|startoftranscript|>, <|no|>, <|transcribe|>, timestamp tokens,
        // <|endoftext|>) that would otherwise leak into the transcript
        // shown to researchers. Confirmed via a real end-to-end smoke test.
        options.skipSpecialTokens = true
        // `chunkingStrategy` deliberately left at its default (`nil` / fixed
        // seek-loop windowing), NOT `.vad`. `.vad` was tried and reverted the
        // same day: it looked like the officially-supported answer to
        // boundary-cut hallucinations, but tracing `VADAudioChunker
        // .chunkAll` + `TranscribeTask.run` shows each VAD chunk gets
        // re-transcribed via a fully separate, recursive
        // `self.transcribe(audioArray:...)` call — which applies
        // `TranscribeTask`'s own `windowClipTime`-based end-of-clip
        // trimming (see `windowPadding` in `TranscribeTask.run`) *per
        // chunk*, not once per file. A 14-minute recording split into
        // dozens of VAD chunks therefore silently drops up to ~1s at
        // *every* chunk boundary instead of just once at the very end —
        // and each chunk restarts the decoder's prompt/KV-cache from
        // scratch, multiplying exactly the kind of context-free boundary
        // hallucination risk `no-transcribe` fought hard to minimize with
        // large, overlapping (not silence-cut) windows. Reported symptoms
        // after enabling `.vad` (several new precise-timestamp skips
        // scattered through a recording, plus a new hallucinated
        // interjection) match this mechanism far better than they match
        // a single global setting. The plain fixed-window seek loop only
        // has one such boundary per ~30s of audio and only trims once at
        // the true end of the file; `repairTimelineGaps` (below) is the
        // safety net for whatever it still misses, without multiplying
        // the number of fresh-start decode boundaries in the first place.
        // `disableNoSpeechSkip`: used only by the repair/retry paths
        // (`TranscriptionService.repairUnclearSegments`,
        // `.repairTimelineGaps`) re-decoding a short, isolated clip a human
        // has already confirmed contains real speech. Originally reasoned
        // (from source alone) that WhisperKit's own quality gates
        // (`noSpeechThreshold`, `compressionRatioThreshold`,
        // `logProbThreshold`) were rejecting good decodes and forcing
        // pointless re-rolls. **Empirically falsified**: rebuilt with that
        // exact fix in place (confirmed via build timestamp — binary newer
        // than the source edit) and re-ran the exact real recording that
        // exposed the bug. Output was byte-for-byte identical, placeholder
        // included. If any of those gates had actually been the blocker,
        // disabling them would have changed *something* about the decode
        // that was taken. It changed nothing, which only makes sense if
        // `DecodingFallback.init(...)` never flagged `needsFallback` in the
        // first place for this clip — i.e. the model wasn't rejected by a
        // threshold, it was *confidently wrong*: high enough avgLogProb,
        // low enough compressionRatio and noSpeechProb, while still
        // decoding hallucinated/empty content at temperature 0 (greedy).
        // None of these gates catch that failure mode by design — they all
        // assume the model "knows" when it's struggling, which a
        // confidently-wrong decode contradicts outright. Kept these three
        // relaxed anyway (harmless, occasionally still relevant for a
        // *genuinely* low-confidence case), but no longer relied upon alone.
        if disableNoSpeechSkip {
            options.noSpeechThreshold = nil
            options.compressionRatioThreshold = nil
            options.logProbThreshold = nil
        }
        // `forcedTemperature`: the actual fix for a confidently-wrong
        // greedy decode. Greedy (temperature 0) always walks the single
        // highest-probability token at each step — deterministic, and if
        // that path leads to a hallucination/empty output the model is
        // "confident" in, no quality gate above will ever second-guess it,
        // and WhisperKit's own fallback ladder never even starts (no
        // `needsFallback`, so temperatures 0.2-1.0 in the ladder are never
        // tried). Retry callers that already got an empty/placeholder
        // result back once can call again with a nonzero starting
        // temperature to force genuine sampling diversity from the first
        // attempt, instead of hoping a fallback ladder that never triggers
        // will eventually kick in on its own.
        if let forcedTemperature {
            options.temperature = forcedTemperature
        }
        // `temperatureFallbackCount`: the real, honestly-wired lever
        // behind the restored "Transkripsjonsnøyaktighet" setting (see
        // `TranscriptionAccuracyLevel`) — how many times a single decode
        // window retries at a higher temperature when its own quality
        // gates trip. `nil` leaves WhisperKit's own default (`5`)
        // untouched. Confirmed real via `Configurations.swift`, unlike
        // the old `numBeams`/beam-search setting this replaces, which
        // WhisperKit has no code path for at all.
        if let temperatureFallbackCount {
            options.temperatureFallbackCount = temperatureFallbackCount
        }

        let segments: [TranscriptionSegment]
        do {
            segments = try await self.transcribeAndConvert(
                whisperKit: whisperKit, wavPath: wavPath, options: options, speakerLabel: speakerLabel)
        } catch {
            throw TranscriptionError.processFailed("WhisperKit-transkripsjon feilet: \(error.localizedDescription)")
        }

        return TranscriptionResult(
            version: "1.0", model: "\(variantUsed.modelIdentifier) (native WhisperKit)",
            language: language, durationSeconds: durationSeconds, numSpeakers: 1,
            segments: segments,
            metadata: TranscriptionResultMetadata(
                inputFile: (wavPath as NSString).lastPathComponent,
                processingTimeSeconds: 0,
                modelVariant: "nb-whisper-large", computeType: "coreml-ane", device: "ane",
                diarizationRun: false))
    }

    /// Runs WhisperKit's own `transcribe(audioPath:decodeOptions:)` and
    /// converts its result segments to Clio's `TranscriptionSegment` model.
    ///
    /// Kept as a separate method (rather than inlined in `transcribe(wavPath:...)`)
    /// so WhisperKit's own `TranscriptionResult` type never needs to be
    /// spelled out explicitly — it's ambiguous with Clio's own
    /// `TranscriptionResult` struct (the WhisperKit *module* shares its name
    /// with the `WhisperKit` class, which breaks `WhisperKit.TranscriptionResult`
    /// module-qualified lookup). Returning `[TranscriptionSegment]`
    /// (unambiguous) lets Swift fully infer the intermediate WhisperKit type.
    private func transcribeAndConvert(
        whisperKit: WhisperKit, wavPath: String, options: DecodingOptions, speakerLabel: String
    ) async throws -> [TranscriptionSegment] {
        let results = try await whisperKit.transcribe(audioPath: wavPath, decodeOptions: options)

        var segments: [TranscriptionSegment] = []
        var segId = 0
        for result in results {
            for seg in result.segments {
                var words: [TranscriptionWord] = []
                for w in seg.words ?? [] {
                    let word = TranscriptionWord(
                        word: w.word,
                        start: Double(w.start),
                        end: Double(w.end),
                        confidence: Double(w.probability))
                    words.append(word)
                }
                let trimmedText = Self.sanitize(seg.text)
                let confidence: Double = max(0, min(1, 1.0 + Double(seg.avgLogprob)))
                let segment = TranscriptionSegment(
                    id: segId,
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: trimmedText,
                    speaker: speakerLabel,
                    confidence: confidence,
                    words: words)
                segments.append(segment)
                segId += 1
            }
        }
        return segments
    }

    /// Known NB-Whisper hallucination artifact: literal placeholder text
    /// the model sometimes predicts for audio it can't confidently
    /// transcribe (mismatched/forced language, heavy accent, cross-talk).
    /// This is not a special/control token — `skipSpecialTokens` cannot
    /// filter it, since it doesn't exist as a discrete token in the
    /// bundled tokenizer at all (confirmed by inspecting tokenizer.json);
    /// it's ordinary vocabulary the model was trained to emit for
    /// caption-less segments in its training data. Strip it outright
    /// rather than show it to researchers as if it were real transcript
    /// content. If nothing legible remains, mark the gap explicitly so
    /// it's clear (with real timing) that something is missing, rather
    /// than silently disappearing.
    ///
    /// Matched case-insensitively against several observed spellings —
    /// the model doesn't reliably emit the same bracket/casing every
    /// time ("<|nocaptions|>" is the Whisper-family token-syntax form,
    /// but "<no captions>", "[no captions]", "(no captions)" have all
    /// been observed in real output). Shared with `WhisperCppEngine
    /// .sanitize` — this is a property of the NB-Whisper model's own
    /// training data, not this specific runtime, so both engines need the
    /// identical marker list (confirmed via a real user report: whisper.cpp
    /// output showed a literal, un-stripped "<|nocaptions|>" on a short
    /// test recording after this list was accidentally left out of that
    /// engine's own sanitize implementation).
    static let knownHallucinationMarkers = [
        "<|nocaptions|>",
        "<no captions>",
        "[no captions]",
        "(no captions)",
        "<no caption>",
        "[no caption]",
        "(no caption)",
    ]

    /// Placeholder shown in place of a segment whose entire decoded text
    /// was a known hallucination marker (see `knownHallucinationMarkers`)
    /// with nothing legible left after stripping it. Exposed so
    /// `TranscriptionService`'s cross-channel deduplication can recognize
    /// and prefer a real transcription from the other RØDE channel over
    /// this placeholder when both channels produced overlapping segments
    /// for the same moment — a hallucinated placeholder on one channel
    /// does not mean the *other* channel's mic, which may have picked up
    /// the same speech more clearly, also failed.
    static let unclearAudioPlaceholder = "[uklart lydavsnitt]"

    private static func sanitize(_ rawText: String) -> String {
        var text = rawText
        for marker in knownHallucinationMarkers {
            text = text.replacingOccurrences(
                of: marker, with: "", options: [.caseInsensitive])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unclearAudioPlaceholder }
        // A decoded segment with no letters at all — just stray
        // punctuation/symbols, e.g. a lone ">" observed in real output —
        // is a tokenizer/decode artifact, not real speech content. No
        // transcribable Norwegian utterance is ever letter-free. Treat it
        // the same as an empty decode so it reads as an explicit gap
        // rather than meaningless symbols shown as if they were real
        // transcript content, and so `TranscriptionService`'s repair
        // mechanisms (which specifically target this placeholder) get a
        // chance to recover it, exactly like a fully-empty decode.
        guard trimmed.contains(where: { $0.isLetter }) else {
            return unclearAudioPlaceholder
        }
        return trimmed
    }
}
