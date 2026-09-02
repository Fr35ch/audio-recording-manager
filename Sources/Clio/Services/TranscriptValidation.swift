import Accelerate
import AVFoundation
import Foundation

/// Native Swift port of `no-transcribe`'s (`navt.py`) post-decode quality
/// validation — restores the safety net the WhisperKit port dropped
/// entirely when it replaced the Python subprocess bridge. Every detector
/// here mirrors a specific function in `navt.py`, translated as literally
/// as the language difference allows so the scoring behavior researchers
/// are used to doesn't silently change.
///
/// Pure Swift, no WhisperKit dependency — safe to unit-test in any
/// environment, unlike almost everything else touching transcription
/// quality this session.
enum TranscriptValidation {

    // MARK: - Known hallucination phrases

    /// Curated denylist of stock phrases NB-Whisper (like most Whisper-
    /// family models, trained partly on YouTube captions) hallucinates
    /// for silent or unclear audio — ported verbatim from `navt.py`'s
    /// `HALLUCINATION_PHRASES`.
    static let hallucinationPhrases = [
        "takk for at du så på",
        "takk for at du ser på",
        "takk for i dag",
        "husk å abonnere",
        "husk å like",
        "thanks for watching",
        "thank you for watching",
        "subscribe",
        "like and subscribe",
        "undertekster av",
        "subtitles by",
        "teksting av",
    ]

    /// Ports `detect_hallucination_phrases`. Case-insensitive substring
    /// match against each segment's own text; stops at the first phrase
    /// matched per segment (mirrors Python's `break`).
    static func detectHallucinationPhrases(
        segments: [TranscriptionSegment]
    ) -> [TranscriptValidationIssue] {
        var issues: [TranscriptValidationIssue] = []
        for seg in segments {
            let text = seg.text.lowercased()
            for phrase in hallucinationPhrases where text.contains(phrase) {
                issues.append(TranscriptValidationIssue(
                    kind: .hallucinationPhrase,
                    start: seg.start, end: seg.end,
                    detail: phrase))
                break
            }
        }
        return issues
    }

    /// Ports `detect_gaps`. Flags any silence longer than `minGapSeconds`
    /// between consecutive segments — usually audio the model gave up on
    /// entirely rather than transcribing.
    static func detectGaps(
        segments: [TranscriptionSegment], minGapSeconds: Double = 10.0
    ) -> [TranscriptValidationIssue] {
        guard segments.count > 1 else { return [] }
        var issues: [TranscriptValidationIssue] = []
        for i in 1..<segments.count {
            let prevEnd = segments[i - 1].end
            let currStart = segments[i].start
            let gap = currStart - prevEnd
            if gap > minGapSeconds {
                issues.append(TranscriptValidationIssue(
                    kind: .gap, start: prevEnd, end: currStart,
                    detail: String(format: "%.1fs gap", gap)))
            }
        }
        return issues
    }

    /// Ports `detect_low_density_regions`. Sliding 50%-overlapping window
    /// over the transcript's duration; flags windows with suspiciously
    /// few words per minute (usually a sign of dropped or garbled audio
    /// rather than a genuinely quiet stretch).
    static func detectLowDensityRegions(
        segments: [TranscriptionSegment], windowSeconds: Double = 60.0, minWPM: Double = 30.0
    ) -> [TranscriptValidationIssue] {
        guard let duration = segments.last?.end, duration > 0 else { return [] }
        var issues: [TranscriptValidationIssue] = []
        var windowStart = 0.0
        while windowStart < duration {
            let windowEnd = windowStart + windowSeconds
            let wordCount = segments
                .filter { $0.start < windowEnd && $0.end > windowStart }
                .reduce(0) { $0 + $1.text.split(separator: " ").count }
            let wpm = Double(wordCount) / (windowSeconds / 60.0)
            if wpm < minWPM {
                issues.append(TranscriptValidationIssue(
                    kind: .lowDensity, start: windowStart, end: windowEnd,
                    detail: String(format: "%.1f wpm", wpm)))
            }
            windowStart += windowSeconds / 2
        }
        return issues
    }

    /// Ports `detect_repetition_loops`. Detects a phrase (2-8 words)
    /// repeating back-to-back at least `minRepeats` times — a classic
    /// decoder failure mode ("stuck" hallucination loop), independent of
    /// which segment it spans. Matches Python's behavior of not carrying
    /// a timestamp range (whole-transcript check).
    static func detectRepetitionLoops(
        segments: [TranscriptionSegment], minRepeats: Int = 3
    ) -> [TranscriptValidationIssue] {
        let words = segments.map { $0.text }.joined(separator: " ")
            .lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var issues: [TranscriptValidationIssue] = []
        for n in 2...8 where n <= words.count {
            var i = 0
            while i <= words.count - n {
                let ngram = Array(words[i..<(i + n)])
                var count = 1
                var j = i + n
                while j + n <= words.count && Array(words[j..<(j + n)]) == ngram {
                    count += 1
                    j += n
                }
                if count >= minRepeats {
                    issues.append(TranscriptValidationIssue(
                        kind: .repetition, start: nil, end: nil,
                        detail: "\"\(ngram.joined(separator: " "))\" ×\(count)"))
                    i = j
                } else {
                    i += 1
                }
            }
        }
        return issues
    }

    // MARK: - Audio energy (mono RMS)

    /// Ports `compute_audio_energy`. Fixed, non-overlapping RMS windows
    /// over a mono WAV — reuses the same `vDSP_rmsqv` streaming-read
    /// approach as `StereoSplitter.analyzeChannelEnergy`, just for a
    /// single channel and returning `(start, end, rms)` chunk tuples
    /// instead of raw per-window arrays.
    static func computeAudioEnergy(
        wavURL: URL, chunkSeconds: Double = 5.0
    ) throws -> [(start: Double, end: Double, rms: Float)] {
        let inputFile = try AVAudioFile(forReading: wavURL)
        let format = inputFile.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return [] }

        let chunkFrames = AVAudioFrameCount(max(1, Int((sampleRate * chunkSeconds).rounded())))
        var results: [(start: Double, end: Double, rms: Float)] = []
        var chunkIndex = 0

        while inputFile.framePosition < inputFile.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw TranscriptionError.processFailed("Kan ikke allokere analysebuffer for validering")
            }
            try inputFile.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channel = buffer.floatChannelData?[0] else { break }

            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frames))

            let start = Double(chunkIndex) * chunkSeconds
            let end = start + Double(frames) / sampleRate
            results.append((start: start, end: end, rms: rms))
            chunkIndex += 1
        }
        return results
    }

    /// Ports `detect_energy_mismatch`. Cross-references decoded text
    /// against the audio's own loudness: loud audio with no transcribed
    /// words is likely missed speech; near-silent audio with a lot of
    /// transcribed words is likely a hallucination.
    static func detectEnergyMismatch(
        segments: [TranscriptionSegment],
        audioEnergies: [(start: Double, end: Double, rms: Float)],
        energyThreshold: Float = 0.01
    ) -> [TranscriptValidationIssue] {
        var issues: [TranscriptValidationIssue] = []
        for (start, end, rms) in audioEnergies {
            let wordCount = segments
                .filter { $0.start < end && $0.end > start }
                .reduce(0) { $0 + $1.text.split(separator: " ").count }
            if rms > energyThreshold * 3 && wordCount == 0 {
                issues.append(TranscriptValidationIssue(
                    kind: .energyMismatchMissed, start: start, end: end,
                    detail: "høy lyd, ingen tekst"))
            } else if rms < energyThreshold && wordCount > 10 {
                issues.append(TranscriptValidationIssue(
                    kind: .energyMismatchHallucination, start: start, end: end,
                    detail: "stille lyd, mye tekst (\(wordCount) ord)"))
            }
        }
        return issues
    }

    // MARK: - Orchestration

    /// Ports `validate_transcript` + its scoring weights. `wavURL` is
    /// optional — pass `nil` (or leave energy analysis to fail silently)
    /// to skip `detectEnergyMismatch` if the source WAV is unavailable;
    /// every other detector needs only the segments themselves.
    static func validate(
        segments: [TranscriptionSegment], wavURL: URL?
    ) -> TranscriptValidationSummary {
        var issues: [TranscriptValidationIssue] = []
        issues += detectGaps(segments: segments)
        issues += detectLowDensityRegions(segments: segments)
        issues += detectRepetitionLoops(segments: segments)
        issues += detectHallucinationPhrases(segments: segments)

        if let wavURL, let energies = try? computeAudioEnergy(wavURL: wavURL) {
            issues += detectEnergyMismatch(segments: segments, audioEnergies: energies)
        }

        return summarize(issues: issues)
    }

    /// Computes score/summary from an arbitrary issue list — factored out
    /// of `validate` so the stereo pipeline can combine two independently
    /// computed per-channel issue lists (left/right) into one summary for
    /// the final merged transcript without re-deriving the scoring
    /// weights in two places.
    static func summarize(issues: [TranscriptValidationIssue]) -> TranscriptValidationSummary {
        var score = 100
        for issue in issues {
            switch issue.kind {
            case .gap:
                let gapSeconds = (issue.end ?? 0) - (issue.start ?? 0)
                score -= min(20, Int(gapSeconds))
            case .lowDensity:
                score -= 5
            case .repetition:
                // Python: `count * 2`. `detail` carries "×N" — recover N.
                let count = issue.detail
                    .split(separator: "×").last
                    .flatMap { Int($0) } ?? 1
                score -= count * 2
            case .hallucinationPhrase:
                score -= 10
            case .energyMismatchMissed, .energyMismatchHallucination:
                score -= 8
            case .mergedChannelsDetected:
                // Diarization is fundamentally impossible on this
                // recording, not merely degraded — score it as the
                // single dominant issue rather than a small deduction.
                score -= 100
            }
        }
        score = max(0, score)

        let typeCounts = Dictionary(grouping: issues, by: { $0.kind })
            .mapValues(\.count)
        let summaryText = typeCounts.isEmpty
            ? "ingen problemer funnet"
            : typeCounts.map { "\($0.value) \($0.key.rawValue)" }.joined(separator: ", ")

        return TranscriptValidationSummary(
            issues: issues, summary: summaryText, score: score, issueCount: issues.count)
    }

    /// Ports `flag_low_confidence_segments`. Marks every segment that
    /// overlaps an issue carrying a real timestamp range (i.e. not
    /// `.repetition`, which has none — matching Python, where only
    /// issues with "start"/"end" keys can flag a segment).
    static func flagLowConfidenceSegments(
        segments: [TranscriptionSegment], summary: TranscriptValidationSummary
    ) -> [TranscriptionSegment] {
        let flagged = summary.issues.compactMap { issue -> (Double, Double)? in
            guard let start = issue.start, let end = issue.end else { return nil }
            return (start, end)
        }
        guard !flagged.isEmpty else { return segments }
        return segments.map { seg in
            var seg = seg
            seg.lowConfidence = flagged.contains { fs, fe in seg.start < fe && seg.end > fs }
            return seg
        }
    }
}
