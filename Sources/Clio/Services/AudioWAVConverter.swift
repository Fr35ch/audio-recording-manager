import AVFoundation
import Foundation

// MARK: - AudioWAVConverter
//
// no-transcribe (navt.py) converts non-WAV inputs (.m4a, .mp4, .aac, .ogg,
// .ds2) to 16 kHz mono WAV via a bare `ffmpeg` subprocess call, resolved
// via PATH. That works in an interactive shell with Homebrew on PATH, but
// GUI apps launched by launchd (and especially sandboxed/TestFlight builds)
// have no such PATH entry and no ffmpeg binary bundled — every transcription
// silently failed with `FileNotFoundError: ffmpeg`.
//
// This converts audio to 16 kHz mono 16-bit PCM WAV entirely in-process via
// AVFoundation (the same approach already used by `StereoSplitter`), so the
// app has zero external-binary dependency. navt.py's own `to_wav()` skips
// conversion entirely for `.wav` inputs, so passing the converted path via
// `--input` bypasses its ffmpeg call completely.

enum AudioWAVConverterError: LocalizedError {
    case noAudioTrack
    case setupFailed(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "Lydfilen inneholder ingen lydkanal"
        case .setupFailed(let msg):
            return "WAV-konvertering feilet under oppsett: \(msg)"
        case .processingFailed(let msg):
            return "WAV-konvertering feilet: \(msg)"
        }
    }
}

enum AudioWAVConverter {
    /// Converts any AVFoundation-readable audio file to a 16 kHz mono
    /// 16-bit PCM WAV file in a temp directory. The caller owns the
    /// returned URL and is responsible for deleting it.
    static func convertToWAV(sourceURL: URL) throws -> URL {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw AudioWAVConverterError.setupFailed(error.localizedDescription)
        }

        let sourceFormat = inputFile.processingFormat
        guard sourceFormat.channelCount >= 1 else {
            throw AudioWAVConverterError.noAudioTrack
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioWAVConverterError.setupFailed("Kan ikke opprette mål-lydformat")
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioWAVConverterError.setupFailed("Kan ikke opprette lydkonverterer")
        }

        let tmpDir = FileManager.default.temporaryDirectory
        let outURL = tmpDir.appendingPathComponent("clio-wav-\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: outURL)

        let outSettings: [String: Any] = [
            AVFormatIDKey:            kAudioFormatLinearPCM,
            AVSampleRateKey:          16_000,
            AVNumberOfChannelsKey:    1,
            AVLinearPCMBitDepthKey:   16,
            AVLinearPCMIsFloatKey:    false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        var outputFile: AVAudioFile?
        do {
            // Explicitly pin the processing format to `targetFormat` (Int16,
            // interleaved). Without this, AVAudioFile derives its own
            // processing format from `settings`, which is not guaranteed to
            // match the buffer format passed to `write(from:)` — a mismatch
            // there raises an uncatchable Objective-C exception (not a Swift
            // `Error`), crashing the process instead of throwing.
            outputFile = try AVAudioFile(
                forWriting: outURL,
                settings: outSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw AudioWAVConverterError.setupFailed(error.localizedDescription)
        }

        let chunkFrames: AVAudioFrameCount = 16_384

        do {
            var reachedEnd = false
            while !reachedEnd {
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    guard let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: sourceFormat,
                        frameCapacity: chunkFrames
                    ) else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    do {
                        try inputFile.read(into: inputBuffer)
                    } catch {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    if inputBuffer.frameLength == 0 {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return inputBuffer
                }

                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: chunkFrames
                ) else {
                    throw AudioWAVConverterError.processingFailed("Kan ikke allokere skrivebuffer")
                }

                var conversionError: NSError?
                let status = converter.convert(
                    to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

                if let conversionError {
                    throw AudioWAVConverterError.processingFailed(conversionError.localizedDescription)
                }

                if outputBuffer.frameLength > 0 {
                    try outputFile?.write(from: outputBuffer)
                }

                if status == .endOfStream || status == .error {
                    reachedEnd = true
                }
            }
        } catch let error as AudioWAVConverterError {
            outputFile = nil
            try? FileManager.default.removeItem(at: outURL)
            throw error
        } catch {
            outputFile = nil
            try? FileManager.default.removeItem(at: outURL)
            throw AudioWAVConverterError.processingFailed(error.localizedDescription)
        }

        // Release the writer so AVAudioFile finalizes the WAV header/data size.
        outputFile = nil
        return outURL
    }
}
