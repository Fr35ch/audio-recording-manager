import Accelerate
import AVFoundation
import Foundation

enum StereoSplitterError: LocalizedError {
    case noAudioTrack
    case setupFailed(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "Lydfilen inneholder ingen lydkanal"
        case .setupFailed(let msg):
            return "Kanalklipping feilet under oppsett: \(msg)"
        case .processingFailed(let msg):
            return "Kanalklipping feilet: \(msg)"
        }
    }
}

enum StereoSplitter {
    /// Splits a stereo M4A into two mono M4A files (one per channel).
    ///
    /// Uses `AVAudioFile`, which reads the source into deinterleaved float32
    /// PCM buffers and handles AAC packetization + container finalization
    /// (the `moov` atom) on close. This avoids the fragile, hand-rolled
    /// `CMSampleBuffer` reconstruction that previously produced empty,
    /// unreadable `.m4a` files.
    ///
    /// The output sample rate follows the source file rather than a hardcoded
    /// value, so 44.1 kHz and 48 kHz recordings are both preserved correctly.
    ///
    /// Each output is a faithful, full-length copy of one source channel — no
    /// silencing or gating is applied here. Cross-talk between the two RØDE
    /// transmitters (both mics pick up both speakers) is suppressed *after*
    /// transcription, at the segment level, by `ChannelEnergy`. Doing it there
    /// rather than by zero-filling the audio avoids feeding long stretches of
    /// digital silence to NB-Whisper, which can otherwise hallucinate/loop
    /// indefinitely on silent input.
    ///
    /// - Returns: `(left, right)` temp URLs. The caller is responsible for
    ///   deleting them.
    static func splitStereoM4A(sourceURL: URL) async throws -> (left: URL, right: URL) {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw StereoSplitterError.setupFailed(error.localizedDescription)
        }

        let sourceFormat = inputFile.processingFormat
        guard sourceFormat.channelCount >= 1 else {
            throw StereoSplitterError.noAudioTrack
        }
        let sampleRate = sourceFormat.sampleRate
        let isStereo = sourceFormat.channelCount > 1

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let tmpDir = FileManager.default.temporaryDirectory
        let leftURL  = tmpDir.appendingPathComponent("\(stem)_left.m4a")
        let rightURL = tmpDir.appendingPathComponent("\(stem)_right.m4a")

        try? FileManager.default.removeItem(at: leftURL)
        try? FileManager.default.removeItem(at: rightURL)

        let monoSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey:   256_000,
        ]

        // Mono float32 PCM format for the buffers handed to the writers.
        guard let monoPCMFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw StereoSplitterError.setupFailed("Kan ikke opprette mono lydformat")
        }

        // Writers are optional so we can deterministically finalize (write the
        // `moov` atom) by releasing them before returning.
        var leftFile: AVAudioFile?
        var rightFile: AVAudioFile?
        do {
            leftFile  = try AVAudioFile(forWriting: leftURL,  settings: monoSettings)
            rightFile = try AVAudioFile(forWriting: rightURL, settings: monoSettings)
        } catch {
            throw StereoSplitterError.setupFailed(error.localizedDescription)
        }

        let frameCapacity: AVAudioFrameCount = 16_384

        do {
            while inputFile.framePosition < inputFile.length {
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: frameCapacity
                ) else {
                    throw StereoSplitterError.processingFailed("Kan ikke allokere lesebuffer")
                }

                try inputFile.read(into: inputBuffer)
                let frames = inputBuffer.frameLength
                if frames == 0 { break }

                guard let channels = inputBuffer.floatChannelData else {
                    throw StereoSplitterError.processingFailed("Mangler PCM-data i lesebuffer")
                }

                let leftSource = channels[0]
                // Mono source: feed the single channel to both outputs.
                let rightSource = isStereo ? channels[1] : channels[0]

                guard let leftOut = AVAudioPCMBuffer(pcmFormat: monoPCMFormat, frameCapacity: frames),
                      let rightOut = AVAudioPCMBuffer(pcmFormat: monoPCMFormat, frameCapacity: frames) else {
                    throw StereoSplitterError.processingFailed("Kan ikke allokere skrivebuffer")
                }
                leftOut.frameLength = frames
                rightOut.frameLength = frames

                let byteCount = Int(frames) * MemoryLayout<Float>.size
                memcpy(leftOut.floatChannelData![0], leftSource, byteCount)
                memcpy(rightOut.floatChannelData![0], rightSource, byteCount)

                try leftFile?.write(from: leftOut)
                try rightFile?.write(from: rightOut)
            }
        } catch let error as StereoSplitterError {
            leftFile = nil
            rightFile = nil
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
            throw error
        } catch {
            leftFile = nil
            rightFile = nil
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
            throw StereoSplitterError.processingFailed(error.localizedDescription)
        }

        // Release the writers so AVAudioFile finalizes each container (writes
        // the `moov` atom). Without this the files are unreadable by ffmpeg.
        leftFile = nil
        rightFile = nil

        return (leftURL, rightURL)
    }

    // MARK: - Cross-talk suppression (segment-level)

    /// Per-window RMS energy of both channels of a stereo recording.
    ///
    /// Both RØDE Wireless Micro transmitters pick up *both* speakers when the
    /// participants sit close together (acoustic bleed), so transcribing each
    /// channel separately yields the same utterance on both channels. This
    /// type lets the merge step decide, for any time span, which channel's
    /// microphone was dominant — i.e. who was actually speaking — so the
    /// bleed copy can be dropped without ever silencing the audio handed to
    /// the transcriber.
    struct ChannelEnergy {
        enum Side { case left, right }

        let windowSeconds: Double
        let left: [Float]
        let right: [Float]
        /// Absolute RMS floor (linear). Windows below this on both channels are
        /// treated as silence and never count as anyone's speech.
        var floorRMS: Float = 0.00316  // ≈ -50 dBFS

        /// Determines whether a transcribed segment really belongs to `side`,
        /// and if so the tightened time range where that side is actually the
        /// dominant, active speaker within the segment's nominal `[start, end]`.
        ///
        /// NB-Whisper segment boundaries are loose: a segment's start often
        /// reaches back into the *other* speaker's audio (e.g. an informant
        /// line tagged 18.18–22.86 when the informant only speaks from ~21 s,
        /// overlapping the interviewer's 18–20 s speech). Averaging energy over
        /// the whole nominal span therefore misattributes such segments — it
        /// previously caused real lines to be dropped as if they were cross-talk
        /// duplicates.
        ///
        /// Instead we look window-by-window. A window counts for `side` only
        /// when that channel is both active (above `floorRMS`) and louder than
        /// the other (left wins ties, right needs a strict lead, so exactly one
        /// copy of a duplicated utterance survives). If `side` is dominant for
        /// at least `minDominantSeconds`, the segment is genuine and we return
        /// the span from its first to last dominant window — tightening the
        /// timestamp to the real speech onset. If `side` is never meaningfully
        /// dominant, the segment is bleed from the other microphone and we
        /// return `nil` (drop it).
        func dominantRange(
            start: Double,
            end: Double,
            side: Side,
            minDominantSeconds: Double = 0.30
        ) -> ClosedRange<Double>? {
            guard windowSeconds > 0, !left.isEmpty, left.count == right.count else {
                // Without analysis data, keep the segment unchanged.
                return start...max(end, start)
            }
            let count = left.count
            func widx(_ t: Double) -> Int {
                let raw = Int((t / windowSeconds).rounded())
                return min(max(raw, 0), count - 1)
            }
            let lo = widx(start)
            let hi = max(widx(end), lo)

            var firstDom = -1
            var lastDom = -1
            var domWindows = 0
            for w in lo...hi {
                let lv = left[w]
                let rv = right[w]
                guard max(lv, rv) > floorRMS else { continue }
                let dominant = (side == .left) ? (lv >= rv) : (rv > lv)
                if dominant {
                    if firstDom < 0 { firstDom = w }
                    lastDom = w
                    domWindows += 1
                }
            }

            guard firstDom >= 0,
                  Double(domWindows) * windowSeconds >= minDominantSeconds else {
                return nil
            }
            let tightStart = Double(firstDom) * windowSeconds
            let tightEnd = Double(lastDom + 1) * windowSeconds
            return tightStart...tightEnd
        }

        /// Sums each channel's RMS across the windows spanning `[start, end)`
        /// — used by `deduplicateCrossTalk` to decide which channel was
        /// actually louder over a specific overlap range shared by two
        /// candidate duplicate segments, rather than each segment's own
        /// (looser) nominal span.
        func summedEnergy(from start: Double, to end: Double) -> (left: Float, right: Float) {
            guard windowSeconds > 0, !left.isEmpty, left.count == right.count, end > start else {
                return (0, 0)
            }
            let count = left.count
            func widx(_ t: Double) -> Int {
                let raw = Int((t / windowSeconds).rounded())
                return min(max(raw, 0), count - 1)
            }
            let lo = widx(start)
            let hi = max(widx(end), lo)
            var l: Float = 0
            var r: Float = 0
            for w in lo...hi {
                l += left[w]
                r += right[w]
            }
            return (l, r)
        }
    }

    /// Computes `ChannelEnergy` for a stereo source by reading it once and
    /// taking the RMS of each channel over fixed windows.
    ///
    /// Cheap: a single streaming pass storing a few floats per second. Returns
    /// `nil` for non-stereo sources (nothing to disambiguate).
    static func analyzeChannelEnergy(
        sourceURL: URL,
        windowSeconds: Double = 0.05
    ) throws -> ChannelEnergy? {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let format = inputFile.processingFormat
        guard format.channelCount >= 2 else { return nil }

        let sampleRate = format.sampleRate
        let windowFrames = max(1, Int((sampleRate * windowSeconds).rounded()))
        // Read several windows per buffer to keep allocation count low.
        let chunkWindows = 20
        let chunkFrames = AVAudioFrameCount(windowFrames * chunkWindows)

        var leftRMS: [Float] = []
        var rightRMS: [Float] = []

        while inputFile.framePosition < inputFile.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw StereoSplitterError.processingFailed("Kan ikke allokere analysebuffer")
            }
            try inputFile.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            let l = channels[0]
            let r = channels[1]

            var offset = 0
            while offset < frames {
                let n = min(windowFrames, frames - offset)
                var rmsL: Float = 0
                var rmsR: Float = 0
                vDSP_rmsqv(l + offset, 1, &rmsL, vDSP_Length(n))
                vDSP_rmsqv(r + offset, 1, &rmsR, vDSP_Length(n))
                leftRMS.append(rmsL)
                rightRMS.append(rmsR)
                offset += n
            }
        }

        return ChannelEnergy(windowSeconds: windowSeconds, left: leftRMS, right: rightRMS)
    }

    // MARK: - Merged-channel hardware misconfiguration detection

    /// Detects a real, discovered-in-the-field failure mode: the RØDE
    /// capture app itself set to "merge" instead of "split" channel mode,
    /// which sums both wireless mics into a single mono signal duplicated
    /// onto both stereo channels *before Clio ever sees the file* — no
    /// software-side energy analysis or dedup logic can recover per-speaker
    /// separation once this has happened, because there genuinely is
    /// nothing left to separate. This was the actual root cause behind a
    /// long stretch of "diarization is broken" reports this session that
    /// had nothing to do with any of the transcription-pipeline changes
    /// under suspicion at the time.
    ///
    /// Genuinely independent RØDE mics show large per-window asymmetry
    /// whenever one person is speaking — the original cross-talk gating
    /// design (see `splitStereoM4A`'s history) measured ~18 dB separation
    /// on a real recording, i.e. one channel's RMS roughly 8x the other's.
    /// A merged/duplicated signal shows none: both channels carry the same
    /// audio, so their RMS tracks together almost exactly even while
    /// someone is actively speaking. Compares the windowed RMS energy
    /// `analyzeChannelEnergy` already computed rather than re-reading the
    /// file, and only judges windows with real signal (above `floorRMS`)
    /// so silence/pauses can't dilute the result either way.
    ///
    /// - Parameter minActiveWindows: minimum number of above-floor windows
    ///   required before making a judgment at all — a very short or mostly
    ///   silent recording doesn't have enough evidence either way.
    /// - Parameter minRatioForMerge: the median (across active windows) of
    ///   `min(left, right) / max(left, right)` above which channels are
    ///   judged merged. 0.9 means the quieter channel is, typically, within
    ///   about 1 dB of the louder one — far tighter than genuine acoustic
    ///   bleed between two separate lavalier mics ever produces.
    static func isLikelyMergedChannels(
        _ energy: ChannelEnergy,
        minActiveWindows: Int = 20,
        minRatioForMerge: Float = 0.9
    ) -> Bool {
        var activeRatios: [Float] = []
        for (l, r) in zip(energy.left, energy.right) {
            let hi = max(l, r)
            guard hi > energy.floorRMS else { continue }  // skip silence/pauses
            activeRatios.append(min(l, r) / hi)
        }
        guard activeRatios.count >= minActiveWindows else { return false }
        let median = activeRatios.sorted()[activeRatios.count / 2]
        return median >= minRatioForMerge
    }

    // MARK: - Cross-channel deduplication (post-tightening)

    /// Cross-channel deduplication pass, run after each channel's own
    /// `ChannelEnergy.dominantRange` tightening and before merging left +
    /// right into one transcript.
    ///
    /// `dominantRange` only asks "was *this* channel dominant for at
    /// least 0.3s within *this* segment's own nominal span?" — it never
    /// compares against what the other channel produced for the same
    /// moment. When the two RØDE Wireless Micro transmitters are close
    /// enough that a speaker's voice registers at comparable volume on
    /// both mics, each channel can independently pass its own dominance
    /// check for the very same utterance, producing the same line twice
    /// under both speaker labels — a real, observed failure mode, not
    /// hypothetical (duplicate near-identical lines at the same
    /// timestamp under both speaker labels).
    ///
    /// For every pair of segments (one per channel) whose tightened time
    /// ranges overlap by at least `minOverlapFraction` of the shorter
    /// segment's duration **and** whose text is similar enough to
    /// plausibly be the same utterance (`minWordSimilarity`, skipped
    /// when either side is the unclear-audio placeholder — see below),
    /// keeps only one:
    ///   1. If exactly one side's text is
    ///      `NativeTranscriptionEngine.unclearAudioPlaceholder` and the
    ///      other has real text, the real one always wins — a
    ///      hallucinated placeholder on one mic (heard as "unclear" by
    ///      the model) never outranks an actual transcription of the
    ///      same moment picked up more clearly by the other mic.
    ///   2. Otherwise, whichever channel had the greater total RMS
    ///      energy summed over the overlapping windows wins — a more
    ///      direct, moment-specific measure of who was actually speaking
    ///      than either segment's own (looser) nominal span.
    ///   3. Ties keep the left segment, matching
    ///      `TranscriptionService.mergeTranscriptionResults`'s existing
    ///      "left wins ties" convention.
    ///
    /// The word-similarity gate exists because time overlap alone is not
    /// sufficient: comparing overlap against the *shorter* segment's own
    /// duration means a short, real, distinct utterance (a brief
    /// interjection, or simply a second segment that happens to be much
    /// shorter than a long one elsewhere) nested anywhere inside a much
    /// longer segment's span on the other channel would always measure
    /// as ~100% "overlap" regardless of what it actually says — a real
    /// regression found and fixed the same day this function shipped: it
    /// caused widespread, incorrect deletion of genuinely distinct,
    /// merely time-overlapping speech (ordinary conversational overlap,
    /// or just two channels segmenting the same stretch at different
    /// granularities) throughout a transcript, not just true duplicates.
    static func deduplicateCrossTalk(
        left: [TranscriptionSegment],
        right: [TranscriptionSegment],
        energy: ChannelEnergy,
        minOverlapFraction: Double = 0.5,
        minWordSimilarity: Double = 0.3
    ) -> (left: [TranscriptionSegment], right: [TranscriptionSegment]) {
        guard !left.isEmpty, !right.isEmpty else { return (left, right) }

        var droppedLeftIds = Set<Int>()
        var droppedRightIds = Set<Int>()

        for l in left {
            guard !droppedLeftIds.contains(l.id) else { continue }
            for r in right {
                guard !droppedRightIds.contains(r.id) else { continue }

                let overlapStart = max(l.start, r.start)
                let overlapEnd = min(l.end, r.end)
                let overlap = overlapEnd - overlapStart
                guard overlap > 0 else { continue }
                let shorterDuration = min(l.end - l.start, r.end - r.start)
                guard shorterDuration > 0, overlap / shorterDuration >= minOverlapFraction else {
                    continue
                }

                let lIsPlaceholder = l.text == NativeTranscriptionEngine.unclearAudioPlaceholder
                let rIsPlaceholder = r.text == NativeTranscriptionEngine.unclearAudioPlaceholder

                if lIsPlaceholder && !rIsPlaceholder {
                    droppedLeftIds.insert(l.id)
                    break  // this l is gone — stop checking it against other r's
                } else if rIsPlaceholder && !lIsPlaceholder {
                    droppedRightIds.insert(r.id)
                    continue  // l survives this pair — keep checking it against other r's
                } else if !lIsPlaceholder && !rIsPlaceholder {
                    // Neither side is a placeholder — only treat this as a
                    // genuine duplicate (not ordinary conversational
                    // overlap or two independently-segmented moments) if
                    // the actual words are similar enough to plausibly be
                    // the same utterance transcribed twice.
                    guard wordSimilarity(l.text, r.text) >= minWordSimilarity else { continue }
                    let (leftEnergy, rightEnergy) = energy.summedEnergy(from: overlapStart, to: overlapEnd)
                    if rightEnergy > leftEnergy {
                        droppedLeftIds.insert(l.id)
                        break
                    } else {
                        droppedRightIds.insert(r.id)
                    }
                }
                // Both placeholders: time overlap alone is a weak signal
                // and neither has real content to compare — leave both in
                // place rather than guess.
            }
        }

        return (
            left.filter { !droppedLeftIds.contains($0.id) },
            right.filter { !droppedRightIds.contains($0.id) }
        )
    }

    /// Case-insensitive word-level Jaccard similarity (intersection over
    /// union of each text's word set) — a simple, dependency-free measure
    /// of "do these two segments plausibly say the same thing," used to
    /// gate `deduplicateCrossTalk`'s real-text-vs-real-text branch. Ties
    /// (e.g. two empty strings) return 0, never treated as similar.
    private static func wordSimilarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let wordsA = words(a)
        let wordsB = words(b)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }
}
