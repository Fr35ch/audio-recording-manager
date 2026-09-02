import Foundation

/// "Transkripsjonsnøyaktighet" (transcription accuracy) — a real,
/// honestly-wired speed/accuracy trade-off setting.
///
/// A near-identical control existed before this session under the name
/// `numBeams`, mapped to the old Python `no-transcribe` pipeline's real
/// `num_beams` (beam search width) parameter. It was removed when Clio
/// briefly ran on WhisperKit, whose `TranscribeTask.decodeWithFallback`
/// hardcodes `GreedyTokenSampler` unconditionally — there was no
/// beam-search code path to map the setting to at all. Clio has since
/// switched its transcription engine to whisper.cpp (see
/// `WhisperCppEngine`, matching how VG's "Jojo" app does on-device
/// NB-Whisper transcription), which has a complete, real beam-search
/// implementation — so this setting is restored mapped to the SAME real
/// parameter the original Python pipeline used
/// (`whisper_full_params.beam_search.beam_size`), not a WhisperKit
/// workaround.
///
///   - `beamSize` (`whisper_full_params.beam_search.beam_size`): real beam
///     search width. `nil` = greedy (fastest, single best-token path at
///     each step). NB-Whisper's own model card recommends `5` for best
///     accuracy — used here as the `balanced` (today's default) level.
///   - `proactiveConsensusRepair`: at the two highest levels, this
///     session's own consensus-repair mechanism
///     (`TranscriptionService.retryDecodeEscalating`) — previously only
///     triggered for segments `isSuspectSegment` already flagged as
///     bad — instead runs on *every* segment the main pass produces,
///     trading significant additional decode time for a second, scored
///     opinion on content that already looked fine. Kept as a real,
///     additional safety net even though whisper.cpp's own beam search +
///     threshold gates are far more capable than WhisperKit's ever were.
///
/// Uses a new `@AppStorage` key (`transcription.accuracyLevel`) rather
/// than reusing the old `transcription.numBeams` key — the old key's
/// semantics (a raw `num_beams` integer, 1-4) don't cleanly map onto this
/// enum's five levels, and silently reinterpreting a user's old persisted
/// value under a new parameter shape would be a correctness trap.
enum TranscriptionAccuracyLevel: Int, CaseIterable, Identifiable, Codable {
    case fastest = 0
    case fast = 1
    case balanced = 2
    case accurate = 3
    case mostAccurate = 4

    var id: Int { rawValue }

    static let `default`: TranscriptionAccuracyLevel = .balanced

    /// Norwegian display name shown in the settings picker.
    var displayName: String {
        switch self {
        case .fastest:      return "Raskest – mer manuell retting"
        case .fast:         return "Rask – anbefalt"
        case .balanced:     return "Middels – god balanse"
        case .accurate:     return "Treg – høy nøyaktighet"
        case .mostAccurate: return "Svært treg – best mulig"
        }
    }

    /// Norwegian description shown under the picker — describes the real
    /// beam-search behavior now backing each level.
    var levelDescription: String {
        switch self {
        case .fastest:
            return "Grådig søk (ingen beam search). Raskest, men forvent flere feil du må rette manuelt."
        case .fast:
            return "Beam search med bredde 2. God hastighet, brukbar kvalitet."
        case .balanced:
            return "Beam search med bredde 5 – NB-Whisper sin egen anbefaling for best nøyaktighet. Anbefalt for de fleste intervjuer."
        case .accurate:
            return "Beam search med bredde 5, og alle avsnitt sjekkes på nytt med flere forsøk. Tregere, men fanger opp mer tvetydig tale."
        case .mostAccurate:
            return "Beam search med bredde 8, og alle avsnitt sjekkes grundig på nytt. Svært tregt, brukes når nøyaktighet er viktigere enn ventetid."
        }
    }

    /// `whisper_full_params.beam_search.beam_size` — real beam-search
    /// width. `nil` selects whisper.cpp's greedy strategy instead (no
    /// beam search at all, fastest).
    var beamSize: Int32? {
        switch self {
        case .fastest:      return nil
        case .fast:         return 2
        case .balanced:     return 5  // NB-Whisper's own recommendation
        case .accurate:     return 5
        case .mostAccurate: return 8
        }
    }

    /// Whether every segment the main pass produces should additionally
    /// go through `TranscriptionService`'s consensus-repair mechanism,
    /// not just ones `isSuspectSegment` already flagged as bad.
    var proactiveConsensusRepair: Bool {
        switch self {
        case .fastest, .fast, .balanced: return false
        case .accurate, .mostAccurate:   return true
        }
    }
}
