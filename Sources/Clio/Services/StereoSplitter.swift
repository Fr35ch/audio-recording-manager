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
    /// Splits a stereo M4A into two mono M4A files.
    /// Returns (left, right) temp URLs. Caller is responsible for deleting them.
    static func splitStereoM4A(sourceURL: URL) async throws -> (left: URL, right: URL) {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw StereoSplitterError.noAudioTrack
        }

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let tmpDir = FileManager.default.temporaryDirectory
        let leftURL  = tmpDir.appendingPathComponent("\(stem)_left.m4a")
        let rightURL = tmpDir.appendingPathComponent("\(stem)_right.m4a")

        // Remove stale temp files
        try? FileManager.default.removeItem(at: leftURL)
        try? FileManager.default.removeItem(at: rightURL)

        // --- Reader: stereo interleaved float32 PCM ---
        let readerSettings: [String: Any] = [
            AVFormatIDKey:                kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:       32,
            AVLinearPCMIsFloatKey:        true,
            AVLinearPCMIsNonInterleaved:  false,
            AVLinearPCMIsBigEndianKey:    false,
            AVSampleRateKey:              44100.0,
            AVNumberOfChannelsKey:        2,
        ]
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack,
                                                    outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        // --- Writers: mono AAC 256 kbps ---
        let monoOutputSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey:   256_000,
        ]
        let leftWriter  = try AVAssetWriter(outputURL: leftURL,  fileType: .m4a)
        let rightWriter = try AVAssetWriter(outputURL: rightURL, fileType: .m4a)

        // AVAssetWriterInput for audio: PCM input → AAC output
        // The input format must match the PCM we feed it (mono float32).
        let leftInput  = AVAssetWriterInput(mediaType: .audio,
                                            outputSettings: monoOutputSettings,
                                            sourceFormatHint: nil)
        let rightInput = AVAssetWriterInput(mediaType: .audio,
                                            outputSettings: monoOutputSettings,
                                            sourceFormatHint: nil)
        leftInput.expectsMediaDataInRealTime  = false
        rightInput.expectsMediaDataInRealTime = false

        guard leftWriter.canAdd(leftInput) && rightWriter.canAdd(rightInput) else {
            throw StereoSplitterError.setupFailed("Kan ikke legge til lydkanal i skriver")
        }
        leftWriter.add(leftInput)
        rightWriter.add(rightInput)

        guard reader.startReading() else {
            throw StereoSplitterError.setupFailed(
                reader.error?.localizedDescription ?? "reader startet ikke")
        }
        guard leftWriter.startWriting() else {
            throw StereoSplitterError.setupFailed(
                leftWriter.error?.localizedDescription ?? "venstre skriver startet ikke")
        }
        guard rightWriter.startWriting() else {
            throw StereoSplitterError.setupFailed(
                rightWriter.error?.localizedDescription ?? "høyre skriver startet ikke")
        }
        leftWriter.startSession(atSourceTime: .zero)
        rightWriter.startSession(atSourceTime: .zero)

        // Build mono CMAudioFormatDescription once and reuse
        var monoASBD = AudioStreamBasicDescription(
            mSampleRate:       44100.0,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   4,
            mFramesPerPacket:  1,
            mBytesPerFrame:    4,
            mChannelsPerFrame: 1,
            mBitsPerChannel:   32,
            mReserved:         0
        )
        var monoFormatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &monoASBD,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &monoFormatDesc)
        guard let monoFmt = monoFormatDesc else {
            throw StereoSplitterError.setupFailed("Kan ikke opprette lydformatbeskrivelse")
        }

        // --- Process sample buffers ---
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { continue }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Extract interleaved float32 PCM from the sample buffer
            let ablSize = MemoryLayout<AudioBufferList>.size
                + MemoryLayout<AudioBuffer>.size  // extra buffer slot
            let ablPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { ablPtr.deallocate() }
            var blockRef: CMBlockBuffer?

            let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPtr,
                bufferListSize: ablSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockRef)

            guard listStatus == noErr,
                  ablPtr.pointee.mNumberBuffers >= 1 else { continue }

            let audioBuffer = ablPtr.pointee.mBuffers
            guard let rawData = audioBuffer.mData else { continue }
            let stereoPtr = rawData.bindMemory(to: Float.self,
                                               capacity: numSamples * 2)

            // Deinterleave into two mono Float arrays
            var leftSamples  = [Float](repeating: 0, count: numSamples)
            var rightSamples = [Float](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                leftSamples[i]  = stereoPtr[i * 2]
                rightSamples[i] = stereoPtr[i * 2 + 1]
            }

            // Helper: wrap Float array in a CMSampleBuffer with the mono format desc
            func makeSampleBuffer(_ samples: [Float]) -> CMSampleBuffer? {
                let byteCount = samples.count * MemoryLayout<Float>.size
                var blockBuf: CMBlockBuffer?
                var status = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: byteCount,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: byteCount,
                    flags: 0,
                    blockBufferOut: &blockBuf)
                guard status == kCMBlockBufferNoErr, let bb = blockBuf else { return nil }
                status = samples.withUnsafeBytes { ptr in
                    CMBlockBufferReplaceDataBytes(
                        with: ptr.baseAddress!,
                        blockBuffer: bb,
                        offsetIntoDestination: 0,
                        dataLength: byteCount)
                }
                guard status == kCMBlockBufferNoErr else { return nil }

                var timingInfo = CMSampleTimingInfo(
                    duration:               CMTime(value: 1,
                                                   timescale: CMTimeScale(44100)),
                    presentationTimeStamp:  pts,
                    decodeTimeStamp:        .invalid)
                var outBuf: CMSampleBuffer?
                CMSampleBufferCreate(
                    allocator: nil,
                    dataBuffer: bb,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: monoFmt,
                    sampleCount: samples.count,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timingInfo,
                    sampleSizeEntryCount: 0,
                    sampleSizeArray: nil,
                    sampleBufferOut: &outBuf)
                return outBuf
            }

            if leftInput.isReadyForMoreMediaData,
               let lBuf = makeSampleBuffer(leftSamples) {
                leftInput.append(lBuf)
            }
            if rightInput.isReadyForMoreMediaData,
               let rBuf = makeSampleBuffer(rightSamples) {
                rightInput.append(rBuf)
            }
        }

        leftInput.markAsFinished()
        rightInput.markAsFinished()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            leftWriter.finishWriting { cont.resume() }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            rightWriter.finishWriting { cont.resume() }
        }

        if let err = leftWriter.error {
            throw StereoSplitterError.processingFailed(err.localizedDescription)
        }
        if let err = rightWriter.error {
            throw StereoSplitterError.processingFailed(err.localizedDescription)
        }

        return (leftURL, rightURL)
    }
}
