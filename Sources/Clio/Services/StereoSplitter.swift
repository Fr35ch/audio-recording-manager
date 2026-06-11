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
    /// ## Energy gating (cross-talk suppression)
    /// The two RØDE Wireless Micro transmitters both pick up *both* speakers
    /// when the participants sit close together (acoustic bleed). A naive
    /// per-channel split therefore transcribes every utterance twice — once on
    /// each channel — which surfaces as duplicated lines in the merged
    /// transcript (one labelled INTERVJUER, one INFORMANT).
    ///
    /// To prevent this we apply winner-take-all energy gating: the audio is
    /// processed in short analysis windows, and for each window only the
    /// channel whose own microphone is dominant keeps its audio — the other
    /// channel is silenced for that window. The speaker whose lavalier is
    /// loudest is, by construction, the person actually talking, so this both
    /// removes the duplicates and attributes speech to the correct channel.
    /// Real recordings show ~18 dB separation when one person speaks, so the
    /// decision is unambiguous in practice. Hysteresis avoids flicker at
    /// window boundaries, and an absolute noise floor silences both channels
    /// during pauses.
    ///
    /// Gating is only applied to genuine stereo (≥2 channel) sources. A mono
    /// source is duplicated to both outputs unchanged (legacy behaviour).
    ///
    /// - Parameters:
    ///   - sourceURL: stereo source `.m4a`.
    ///   - gateCrossTalk: when `true` (default), apply the energy gating
    ///     described above. Pass `false` to get a plain channel split.
    /// - Returns: `(left, right)` temp URLs. The caller is responsible for
    ///   deleting them.
    static func splitStereoM4A(
        sourceURL: URL,
        gateCrossTalk: Bool = true
    ) async throws -> (left: URL, right: URL) {
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

        // Process one analysis window at a time so the energy gate can switch
        // ownership on a ~100 ms granularity. A window also spans exactly one
        // read, which keeps the streaming bookkeeping simple.
        let applyGate = gateCrossTalk && isStereo
        let windowFrames = AVAudioFrameCount(max(1, Int((sampleRate * 0.10).rounded())))

        // Gating parameters.
        let floorDB: Float = -50          // below this, both channels are silent (pause)
        let switchMarginDB: Float = 6     // a channel must beat the other by this to take over

        enum Owner { case none, left, right }
        var owner: Owner = .none

        func rms(_ ptr: UnsafePointer<Float>, _ count: AVAudioFrameCount) -> Float {
            var result: Float = 0
            vDSP_rmsqv(ptr, 1, &result, vDSP_Length(count))
            return result
        }

        do {
            while inputFile.framePosition < inputFile.length {
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: windowFrames
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
                let leftDst = leftOut.floatChannelData![0]
                let rightDst = rightOut.floatChannelData![0]

                if applyGate {
                    let rmsL = rms(leftSource, frames)
                    let rmsR = rms(rightSource, frames)
                    let dbL = 20 * log10(max(rmsL, 1e-9))
                    let dbR = 20 * log10(max(rmsR, 1e-9))

                    if max(dbL, dbR) < floorDB {
                        owner = .none
                    } else {
                        let diffDB = dbL - dbR  // positive => left louder
                        switch owner {
                        case .left:
                            if diffDB < -switchMarginDB { owner = .right }
                        case .right:
                            if diffDB > switchMarginDB { owner = .left }
                        case .none:
                            owner = diffDB >= 0 ? .left : .right
                        }
                    }

                    switch owner {
                    case .left:
                        memcpy(leftDst, leftSource, byteCount)
                        memset(rightDst, 0, byteCount)
                    case .right:
                        memset(leftDst, 0, byteCount)
                        memcpy(rightDst, rightSource, byteCount)
                    case .none:
                        memset(leftDst, 0, byteCount)
                        memset(rightDst, 0, byteCount)
                    }
                } else {
                    memcpy(leftDst, leftSource, byteCount)
                    memcpy(rightDst, rightSource, byteCount)
                }

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
}
