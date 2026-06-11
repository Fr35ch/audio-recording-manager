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
                let rightSource = inputBuffer.format.channelCount > 1 ? channels[1] : channels[0]

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
}
