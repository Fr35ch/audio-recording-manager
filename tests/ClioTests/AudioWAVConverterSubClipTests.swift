import XCTest
import AVFoundation
@testable import Clio

final class AudioWAVConverterSubClipTests: XCTestCase {

    /// Writes a synthetic 16-bit mono PCM WAV of `seconds` length where
    /// sample `i` encodes its own index — lets tests verify exactly which
    /// source samples land in an extracted sub-clip, not just its length.
    private func makeSyntheticWAV(seconds: Double, sampleRate: Double = 16_000) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let ptr = buffer.int16ChannelData![0]
        for i in 0..<Int(frameCount) {
            ptr[i] = Int16(truncatingIfNeeded: i)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-test-synthetic-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file?.write(from: buffer)
        file = nil  // force finalization (moov/header) before any test reads it back
        return url
    }

    /// Reads every sample back out, looping until EOF — `AVAudioFile.read`
    /// is not guaranteed to fill an arbitrarily large request in one call
    /// (confirmed empirically while writing these tests), so a single
    /// unlooped read call under-reads for anything but very short clips.
    private func readSamples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        while buffer.frameLength < total {
            let remaining = total - buffer.frameLength
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining)!
            try file.read(into: chunk, frameCount: remaining)
            if chunk.frameLength == 0 { break }
            memcpy(
                buffer.int16ChannelData![0] + Int(buffer.frameLength),
                chunk.int16ChannelData![0],
                Int(chunk.frameLength) * MemoryLayout<Int16>.size)
            buffer.frameLength += chunk.frameLength
        }
        let ptr = buffer.int16ChannelData![0]
        return (0..<Int(buffer.frameLength)).map { ptr[$0] }
    }

    func testExtractsExactRequestedRangeWithPadding() throws {
        let sourceURL = try makeSyntheticWAV(seconds: 10.0)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let clipURL = try AudioWAVConverter.extractSubClip(
            wavURL: sourceURL, start: 4.0, end: 5.0, padding: 2.0)
        defer { try? FileManager.default.removeItem(at: clipURL) }
        let samples = try readSamples(clipURL)

        // Requested [start-2, end+2] = [2.0, 7.0] -> 5.0s of audio.
        let expectedCount = Int(5.0 * 16_000)
        XCTAssertEqual(samples.count, expectedCount)
        XCTAssertEqual(samples.first, Int16(truncatingIfNeeded: Int(2.0 * 16_000)))
        XCTAssertEqual(samples.last, Int16(truncatingIfNeeded: Int(2.0 * 16_000) + expectedCount - 1))
    }

    func testPaddingClampsToFileBoundsRatherThanGoingOutOfRange() throws {
        let sourceURL = try makeSyntheticWAV(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        // Requested [start-2, end+2] = [-1.5, 4.5], must clamp to [0.0, 3.0].
        let clipURL = try AudioWAVConverter.extractSubClip(
            wavURL: sourceURL, start: 0.5, end: 2.5, padding: 2.0)
        defer { try? FileManager.default.removeItem(at: clipURL) }
        let samples = try readSamples(clipURL)

        XCTAssertEqual(samples.count, Int(3.0 * 16_000))
        XCTAssertEqual(samples.first, 0)
    }

    func testOutOfBoundsRangeThrowsRatherThanProducingGarbage() throws {
        let sourceURL = try makeSyntheticWAV(seconds: 5.0)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        XCTAssertThrowsError(
            try AudioWAVConverter.extractSubClip(
                wavURL: sourceURL, start: 10.0, end: 10.0, padding: 0.0))
    }

    func testZeroPaddingExtractsExactSegmentRange() throws {
        let sourceURL = try makeSyntheticWAV(seconds: 6.0)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let clipURL = try AudioWAVConverter.extractSubClip(
            wavURL: sourceURL, start: 1.0, end: 2.0, padding: 0.0)
        defer { try? FileManager.default.removeItem(at: clipURL) }
        let samples = try readSamples(clipURL)

        XCTAssertEqual(samples.count, Int(1.0 * 16_000))
        XCTAssertEqual(samples.first, Int16(truncatingIfNeeded: Int(1.0 * 16_000)))
    }
}
