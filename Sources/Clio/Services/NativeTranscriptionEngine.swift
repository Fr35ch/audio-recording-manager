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
        verbatim: Bool = false
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
        options.wordTimestamps = true
        options.task = .transcribe
        options.usePrefillPrompt = true
        // Without this, per-segment `text` includes raw special tokens
        // (<|startoftranscript|>, <|no|>, <|transcribe|>, timestamp tokens,
        // <|endoftext|>) that would otherwise leak into the transcript
        // shown to researchers. Confirmed via a real end-to-end smoke test.
        options.skipSpecialTokens = true

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
    private static let knownHallucinationMarkers = ["<|nocaptions|>"]

    private static func sanitize(_ rawText: String) -> String {
        var text = rawText
        for marker in knownHallucinationMarkers {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "[uklart lydavsnitt]" : trimmed
    }
}
