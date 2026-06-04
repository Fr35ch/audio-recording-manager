// SpeakerAlignment.swift
// Clio
//
// Pure helper that pairs an NB-Whisper transcript with a FluidAudio
// diarization result by maximum temporal overlap. Each transcript
// segment receives the `speakerId` of the diarization segment that
// covers the largest fraction of its duration. Segments with no
// overlap (rare — usually pauses between turns the model didn't
// score as speech) keep their existing `speaker` label.
//
// O(n × m) — for typical interviews n ≈ 300 transcript segments and
// m ≈ 50 speaker segments. A 15 000-comparison loop costs microseconds
// on Apple Silicon; the linear scan is more readable than a sorted
// binary-search index and the tradeoff isn't worth chasing.

import Foundation

enum SpeakerAlignment {

    /// Attaches diarization-derived speaker IDs to every transcript
    /// segment. Returns a new array; the input segments are untouched.
    ///
    /// - Parameters:
    ///   - transcript: NB-Whisper segments (with start/end seconds)
    ///   - diarization: FluidAudio's speaker timeline
    /// - Returns: copies of the transcript segments with `speaker`
    ///   stamped from the dominant overlapping diarization segment.
    static func attachSpeakers(
        to transcript: [TranscriptionSegment],
        using diarization: [FluidDiarizationService.DiarizationSegment]
    ) -> [TranscriptionSegment] {
        guard !diarization.isEmpty else { return transcript }

        return transcript.map { seg in
            var updated = seg
            if let speakerId = dominantSpeaker(
                forSegmentStart: seg.start,
                segmentEnd: seg.end,
                in: diarization
            ) {
                updated.speaker = speakerId
            }
            return updated
        }
    }

    /// Returns the `speakerId` whose diarization segment overlaps the
    /// most with `[segmentStart, segmentEnd]`. Returns nil when no
    /// diarization segment overlaps at all.
    static func dominantSpeaker(
        forSegmentStart start: Double,
        segmentEnd end: Double,
        in diarization: [FluidDiarizationService.DiarizationSegment]
    ) -> String? {
        var bestOverlap: Double = 0
        var bestSpeaker: String?

        for ds in diarization {
            let overlap = min(end, ds.endSeconds) - max(start, ds.startSeconds)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = ds.speakerId
            }
        }
        return bestSpeaker
    }
}
