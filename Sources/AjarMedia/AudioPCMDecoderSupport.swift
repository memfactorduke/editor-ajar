// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

// swiftlint:disable sorted_imports
@preconcurrency import AVFoundation
import AjarCore
import AudioToolbox
import CoreMedia
import Foundation

// swiftlint:enable sorted_imports

extension AudioPCMDecoder {
    static func validate(
        sourceURL: URL,
        sourceRange: TimeRange,
        leadingFrameCount: Int,
        trailingFrameCount: Int
    ) throws {
        guard sourceURL.isFileURL else {
            throw AudioPCMDecodeError.sourceMustBeFileURL(sourceURL)
        }
        guard sourceRange.start >= .zero else {
            throw AudioPCMDecodeError.invalidSourceRange(sourceRange)
        }
        guard leadingFrameCount >= 0, trailingFrameCount >= 0 else {
            throw AudioPCMDecodeError.invalidFramePadding(
                leading: leadingFrameCount,
                trailing: trailingFrameCount
            )
        }
    }

    static func loadAudioTrack(
        asset: AVURLAsset,
        sourceURL: URL
    ) async throws -> AVAssetTrack {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try requireAvailableSource(sourceURL)
            throw AudioPCMDecodeError.unsupportedSource(sourceURL)
        }
        guard !tracks.isEmpty else {
            try requireAvailableSource(sourceURL)
            throw AudioPCMDecodeError.unsupportedSource(sourceURL)
        }
        guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
            throw AudioPCMDecodeError.missingAudioTrack(sourceURL)
        }
        return audioTrack
    }

    static func loadNativeFormat(
        track: AVAssetTrack,
        sourceURL: URL
    ) async throws -> AudioPCMNativeFormat {
        let descriptions: [CMFormatDescription]
        do {
            descriptions = try await track.load(.formatDescriptions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try requireAvailableSource(sourceURL)
            throw AudioPCMDecodeError.unsupportedSource(sourceURL)
        }
        guard let description = descriptions.first,
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else {
            throw AudioPCMDecodeError.invalidFormat(sampleRate: 0, channelCount: 0)
        }
        let nativeRate = stream.pointee.mSampleRate
        let nativeChannels = Int(stream.pointee.mChannelsPerFrame)
        guard nativeRate.isFinite,
            nativeRate > 0,
            nativeRate <= Double(Int32.max),
            nativeRate.rounded() == nativeRate,
            nativeChannels > 0
        else {
            throw AudioPCMDecodeError.invalidFormat(
                sampleRate: nativeRate,
                channelCount: nativeChannels
            )
        }
        return AudioPCMNativeFormat(
            sampleRate: Int(nativeRate),
            channelCount: nativeChannels
        )
    }

    static func loadSourceTimeline(
        asset: AVURLAsset,
        track: AVAssetTrack,
        format: AudioPCMNativeFormat,
        sourceURL: URL
    ) async throws -> AudioPCMSourceTimeline {
        let assetDuration: CMTime
        let trackTimeRange: CMTimeRange
        let trackSegments: [AVAssetTrackSegment]
        do {
            assetDuration = try await asset.load(.duration)
            trackTimeRange = try await track.load(.timeRange)
            trackSegments = try await track.load(.segments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try requireAvailableSource(sourceURL)
            throw AudioPCMDecodeError.unsupportedSource(sourceURL)
        }

        let assetFrameRange = try nativeFrameRange(
            for: CMTimeRange(start: .zero, duration: assetDuration),
            sampleRate: format.sampleRate
        )
        let declaredAudioFrameRange = try nativeFrameRange(
            for: trackTimeRange,
            sampleRate: format.sampleRate
        )
        let audioFrameRange = try audioContentFrameRange(
            segments: trackSegments,
            declaredFrameRange: declaredAudioFrameRange,
            sampleRate: format.sampleRate
        )
        return AudioPCMSourceTimeline(
            assetFrameRange: assetFrameRange,
            audioFrameRange: clampedIntersection(audioFrameRange, to: assetFrameRange)
        )
    }

    static func audioContentFrameRange(
        segments: [AVAssetTrackSegment],
        declaredFrameRange: Range<Int>,
        sampleRate: Int
    ) throws -> Range<Int> {
        guard !segments.isEmpty else {
            return declaredFrameRange
        }
        let contentRanges = try segments.compactMap { segment -> Range<Int>? in
            guard !segment.isEmpty else {
                return nil
            }
            return try nativeFrameRange(
                for: segment.timeMapping.target,
                sampleRate: sampleRate
            )
        }
        guard let firstRange = contentRanges.first else {
            return declaredFrameRange.lowerBound..<declaredFrameRange.lowerBound
        }
        let contentFrameRange = contentRanges.dropFirst().reduce(firstRange) { result, range in
            min(result.lowerBound, range.lowerBound)..<max(result.upperBound, range.upperBound)
        }
        return clampedIntersection(contentFrameRange, to: declaredFrameRange)
    }

    static func nativeFrameRange(
        for sourceRange: TimeRange,
        sampleRate: Int,
        leadingFrameCount: Int,
        trailingFrameCount: Int
    ) throws -> Range<Int> {
        let end: RationalTime
        let rate: FrameRate
        do {
            end = try sourceRange.end()
            rate = try FrameRate(frames: Int64(sampleRate))
        } catch {
            throw AudioPCMDecodeError.invalidTime(sourceRange.start)
        }

        let unpaddedStart: Int64
        let unpaddedEnd: Int64
        do {
            unpaddedStart = try sourceRange.start.frameIndex(at: rate, rounding: .down)
            unpaddedEnd = try end.frameIndex(at: rate, rounding: .up)
        } catch {
            throw AudioPCMDecodeError.invalidTime(sourceRange.start)
        }
        guard unpaddedStart >= 0,
            unpaddedEnd >= unpaddedStart,
            let start = Int(exactly: unpaddedStart),
            let end = Int(exactly: unpaddedEnd)
        else {
            throw AudioPCMDecodeError.invalidTime(sourceRange.start)
        }
        let paddedEnd = end.addingReportingOverflow(trailingFrameCount)
        guard !paddedEnd.overflow else {
            throw AudioPCMDecodeError.invalidTime(sourceRange.start)
        }
        let paddedStart = leadingFrameCount > start ? 0 : start - leadingFrameCount
        return paddedStart..<paddedEnd.partialValue
    }

    static func clampedIntersection(
        _ frameRange: Range<Int>,
        to bounds: Range<Int>
    ) -> Range<Int> {
        let lowerBound = min(max(frameRange.lowerBound, bounds.lowerBound), bounds.upperBound)
        let upperBound = max(lowerBound, min(frameRange.upperBound, bounds.upperBound))
        return lowerBound..<upperBound
    }

    static func emptyWindow(
        frameRange: Range<Int>,
        format: AudioPCMNativeFormat
    ) throws -> DecodedAudioWindow {
        DecodedAudioWindow(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            presentationTime: try time(
                forFrame: frameRange.lowerBound,
                sampleRate: format.sampleRate
            ),
            frameOffset: frameRange.lowerBound,
            frameCount: 0,
            samples: []
        )
    }

    static func validateWindowAllocation(
        sourceURL: URL,
        frameRange: Range<Int>,
        channelCount: Int
    ) throws {
        let sampleCount = frameRange.count.multipliedReportingOverflow(by: channelCount)
        let byteCount = sampleCount.partialValue.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size
        )
        guard !sampleCount.overflow,
            !byteCount.overflow,
            byteCount.partialValue <= maximumWindowSampleBytes
        else {
            throw AudioPCMDecodeError.windowTooLarge(
                sourceURL,
                frameCount: frameRange.count,
                channelCount: channelCount,
                maximumSampleBytes: maximumWindowSampleBytes
            )
        }
    }

    static func readWindow(_ context: AudioPCMDecodeContext) throws -> DecodedAudioWindow {
        try context.cancellation.check()
        guard !context.decodeFrameRange.isEmpty else {
            var accumulator = AudioPCMWindowAccumulator(context: context)
            return try accumulator.makeWindow()
        }
        let components = try makeReader(context)
        defer {
            if components.reader.status == .reading {
                components.reader.cancelReading()
            }
        }

        // Check again before reserving storage proportional to the requested window. Once a
        // sample-copy call begins, its owning worker reaches the next boundary before teardown.
        try context.cancellation.check()
        var accumulator = AudioPCMWindowAccumulator(context: context)
        while let sampleBuffer = components.output.copyNextSampleBuffer() {
            try context.cancellation.check()
            if try append(sampleBuffer, context: context, to: &accumulator) {
                break
            }
        }
        try context.cancellation.check()
        if components.reader.status == .failed {
            try requireAvailableSource(context.sourceURL)
            throw AudioPCMDecodeError.readerFailed(components.reader.audioErrorDescription)
        }
        return try accumulator.makeWindow()
    }

    static func requireAvailableSource(_ sourceURL: URL) throws {
        if !FileManager.default.isReadableFile(atPath: sourceURL.path) {
            throw AudioPCMDecodeError.missingSource(sourceURL)
        }
    }
}

private extension AudioPCMDecoder {
    static func makeReader(_ context: AudioPCMDecodeContext) throws -> AudioPCMReaderComponents {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: context.asset)
        } catch {
            try requireAvailableSource(context.sourceURL)
            throw AudioPCMDecodeError.readerSetupFailed(String(describing: error))
        }

        let output = AVAssetReaderTrackOutput(
            track: context.track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            try requireAvailableSource(context.sourceURL)
            throw AudioPCMDecodeError.readerSetupFailed("asset reader cannot add audio output")
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: cmTime(
                forFrame: context.decodeFrameRange.lowerBound,
                sampleRate: context.format.sampleRate
            ),
            duration: cmTime(
                forFrame: context.decodeFrameRange.count,
                sampleRate: context.format.sampleRate
            )
        )
        guard reader.startReading() else {
            try requireAvailableSource(context.sourceURL)
            throw AudioPCMDecodeError.readerSetupFailed(reader.audioErrorDescription)
        }
        return AudioPCMReaderComponents(reader: reader, output: output)
    }

    /// Returns true once timestamps have moved beyond the requested window.
    static func append(
        _ sampleBuffer: CMSampleBuffer,
        context: AudioPCMDecodeContext,
        to accumulator: inout AudioPCMWindowAccumulator
    ) throws -> Bool {
        let sampleFrameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleFrameCount >= 0 else {
            throw AudioPCMDecodeError.invalidSampleData("negative frame count")
        }
        guard sampleFrameCount > 0 else {
            return false
        }

        let descriptor = try sampleDescriptor(
            sampleBuffer,
            frameCount: sampleFrameCount,
            format: context.format
        )
        if descriptor.startFrame >= context.decodeFrameRange.upperBound {
            return true
        }
        guard descriptor.endFrame > context.decodeFrameRange.lowerBound else {
            return false
        }

        let slice = try sampleSlice(descriptor, frameRange: context.decodeFrameRange)
        try accumulator.append(slice)
        return slice.endFrame >= context.decodeFrameRange.upperBound
    }

    static func sampleDescriptor(
        _ sampleBuffer: CMSampleBuffer,
        frameCount: Int,
        format: AudioPCMNativeFormat
    ) throws -> AudioPCMSampleDescriptor {
        let presentationTime = try rationalTime(
            from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
        let startFrame = try sourceFrame(
            for: presentationTime,
            sampleRate: format.sampleRate
        )
        let endFrame = startFrame.addingReportingOverflow(frameCount)
        guard !endFrame.overflow else {
            throw AudioPCMDecodeError.invalidPresentationTime
        }
        return AudioPCMSampleDescriptor(
            presentationTime: presentationTime,
            startFrame: startFrame,
            endFrame: endFrame.partialValue,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            samples: try interleavedSamples(
                from: sampleBuffer,
                frameCount: frameCount,
                channelCount: format.channelCount
            )
        )
    }

    static func sampleSlice(
        _ descriptor: AudioPCMSampleDescriptor,
        frameRange: Range<Int>
    ) throws -> AudioPCMFrameSlice {
        let startFrame = max(descriptor.startFrame, frameRange.lowerBound)
        let endFrame = min(descriptor.endFrame, frameRange.upperBound)
        let localStartFrame = startFrame - descriptor.startFrame
        let copiedFrameCount = endFrame - startFrame
        let firstSample = try sampleIndex(
            frame: localStartFrame,
            channelCount: descriptor.channelCount
        )
        let sampleCount = try sampleIndex(
            frame: copiedFrameCount,
            channelCount: descriptor.channelCount
        )
        let endSample = firstSample.addingReportingOverflow(sampleCount)
        guard !endSample.overflow, endSample.partialValue <= descriptor.samples.count else {
            throw AudioPCMDecodeError.invalidSampleData("PCM sample range overflow")
        }
        let presentationTime = try descriptor.presentationTime.adding(
            time(forFrame: localStartFrame, sampleRate: descriptor.sampleRate)
        )
        return AudioPCMFrameSlice(
            presentationTime: presentationTime,
            startFrame: startFrame,
            endFrame: endFrame,
            samples: Array(descriptor.samples[firstSample..<endSample.partialValue])
        )
    }

    static func sourceFrame(for time: RationalTime, sampleRate: Int) throws -> Int {
        do {
            let rate = try FrameRate(frames: Int64(sampleRate))
            let value = try time.frameIndex(at: rate, rounding: .nearestOrAwayFromZero)
            guard let frame = Int(exactly: value) else {
                throw AudioPCMDecodeError.invalidPresentationTime
            }
            return frame
        } catch let error as AudioPCMDecodeError {
            throw error
        } catch {
            throw AudioPCMDecodeError.invalidPresentationTime
        }
    }

    static func nativeFrameRange(
        for timeRange: CMTimeRange,
        sampleRate: Int
    ) throws -> Range<Int> {
        guard timeRange.isValid,
            timeRange.start.isNumeric,
            timeRange.duration.isNumeric,
            timeRange.duration >= .zero
        else {
            throw AudioPCMDecodeError.invalidPresentationTime
        }
        let start = try rationalTime(from: timeRange.start)
        let end = try rationalTime(from: CMTimeRangeGetEnd(timeRange))
        let rate: FrameRate
        let startFrame: Int64
        let endFrame: Int64
        do {
            rate = try FrameRate(frames: Int64(sampleRate))
            startFrame = try start.frameIndex(at: rate, rounding: .down)
            endFrame = try end.frameIndex(at: rate, rounding: .up)
        } catch {
            throw AudioPCMDecodeError.invalidPresentationTime
        }
        guard endFrame >= startFrame,
            let lowerBound = Int(exactly: startFrame),
            let upperBound = Int(exactly: endFrame)
        else {
            throw AudioPCMDecodeError.invalidPresentationTime
        }
        return lowerBound..<upperBound
    }

    static func rationalTime(from time: CMTime) throws -> RationalTime {
        guard time.isValid, time.isNumeric, time.timescale > 0 else {
            throw AudioPCMDecodeError.invalidPresentationTime
        }
        do {
            return try RationalTime(value: time.value, timescale: Int64(time.timescale))
        } catch {
            throw AudioPCMDecodeError.invalidPresentationTime
        }
    }

    static func interleavedSamples(
        from sampleBuffer: CMSampleBuffer,
        frameCount: Int,
        channelCount: Int
    ) throws -> [Float] {
        let expectedSampleCount = try sampleIndex(
            frame: frameCount,
            channelCount: channelCount
        )
        let expectedByteCount = expectedSampleCount.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size
        )
        guard !expectedByteCount.overflow else {
            throw AudioPCMDecodeError.invalidSampleData("PCM byte count overflow")
        }

        let requiredListSize = try audioBufferListSize(for: sampleBuffer)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredListSize,
            alignment: 16
        )
        defer { storage.deallocate() }
        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        let retainedBlockBuffer = try populateAudioBufferList(
            bufferList,
            byteCount: requiredListSize,
            from: sampleBuffer
        )
        return try withExtendedLifetime(retainedBlockBuffer) {
            try copyInterleavedSamples(
                from: bufferList,
                expectedSampleCount: expectedSampleCount,
                expectedByteCount: expectedByteCount.partialValue,
                channelCount: channelCount
            )
        }
    }

    static func copyInterleavedSamples(
        from bufferList: UnsafeMutablePointer<AudioBufferList>,
        expectedSampleCount: Int,
        expectedByteCount: Int,
        channelCount: Int
    ) throws -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count == 1 else {
            throw AudioPCMDecodeError.invalidSampleData("decoder returned planar PCM")
        }
        let buffer = buffers[0]
        guard Int(buffer.mNumberChannels) == channelCount,
            Int(buffer.mDataByteSize) >= expectedByteCount,
            let data = buffer.mData
        else {
            throw AudioPCMDecodeError.invalidSampleData("interleaved PCM format mismatch")
        }
        let values = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: values, count: expectedSampleCount))
    }

    static func audioBufferListSize(for sampleBuffer: CMSampleBuffer) throws -> Int {
        var requiredListSize = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, requiredListSize >= MemoryLayout<AudioBufferList>.size else {
            throw AudioPCMDecodeError.invalidSampleData(
                "could not size AudioBufferList (\(status))"
            )
        }
        return requiredListSize
    }

    static func populateAudioBufferList(
        _ bufferList: UnsafeMutablePointer<AudioBufferList>,
        byteCount: Int,
        from sampleBuffer: CMSampleBuffer
    ) throws -> CMBlockBuffer? {
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: byteCount,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw AudioPCMDecodeError.invalidSampleData(
                "could not read AudioBufferList (\(status))"
            )
        }
        return retainedBlockBuffer
    }

    static func sampleIndex(frame: Int, channelCount: Int) throws -> Int {
        let result = frame.multipliedReportingOverflow(by: channelCount)
        guard frame >= 0, channelCount > 0, !result.overflow else {
            throw AudioPCMDecodeError.invalidSampleData("PCM sample count overflow")
        }
        return result.partialValue
    }

    static func cmTime(forFrame frame: Int, sampleRate: Int) -> CMTime {
        CMTime(value: Int64(frame), timescale: CMTimeScale(sampleRate))
    }

    static func time(forFrame frame: Int, sampleRate: Int) throws -> RationalTime {
        do {
            return try RationalTime(value: Int64(frame), timescale: Int64(sampleRate))
        } catch {
            throw AudioPCMDecodeError.invalidTime(.zero)
        }
    }

    static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
}
