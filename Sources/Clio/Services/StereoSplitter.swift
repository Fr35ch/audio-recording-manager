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
        let windowSeconds: Double
        let left: [Float]
        let right: [Float]

        private func meanRMS(_ values: [Float], start: Double, end: Double) -> Float {
            guard !values.isEmpty, windowSeconds > 0 else { return 0 }
            let lo = max(0, Int((start / windowSeconds).rounded(.down)))
            var hi = Int((end / windowSeconds).rounded(.up))
            hi = min(values.count, max(hi, lo + 1))
            guard lo < hi else { return values[min(lo, values.count - 1)] }
            var sum: Float = 0
            for i in lo..<hi { sum += values[i] }
            return sum / Float(hi - lo)
        }

        /// `true` if the left channel is at least as loud as the right over
        /// `[start, end]`. Ties resolve to the left channel so that exactly one
        /// copy of a duplicated utterance survives (left keeps on `>=`, right
        /// keeps on strict `>`).
        func leftDominates(start: Double, end: Double) -> Bool {
            meanRMS(left, start: start, end: end) >= meanRMS(right, start: start, end: end)
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
}
