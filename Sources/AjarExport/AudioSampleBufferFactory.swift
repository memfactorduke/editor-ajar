// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AudioToolbox
import CoreMedia
import Foundation

final class AudioSampleBufferFactory {
    private let sampleRate: Int
    private let channelCount: Int
    private let bytesPerFrame: Int
    private let formatDescription: CMAudioFormatDescription

    init(sampleRate: Int, channelCount: Int) throws {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        bytesPerFrame = channelCount * MemoryLayout<Float>.size

        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var created: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &created
        )
        guard status == noErr, let created else {
            throw ExportError.audioSampleBufferFailed(status)
        }
        formatDescription = created
    }

    func makeSampleBuffer(
        from buffer: RenderedAudioBuffer,
        frames: Range<Int>
    ) throws -> CMSampleBuffer {
        guard
            buffer.format.sampleRate == sampleRate,
            buffer.format.channelCount == channelCount,
            frames.lowerBound >= 0,
            frames.upperBound <= buffer.frameCount,
            !frames.isEmpty
        else {
            throw ExportError.audioMixFailed("audio append range or format is inconsistent")
        }

        let blockBuffer = try makeBlockBuffer(from: buffer, frames: frames)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(
                value: Int64(frames.lowerBound),
                timescale: Int32(sampleRate)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frames.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw ExportError.audioSampleBufferFailed(status)
        }
        return sampleBuffer
    }

    private func makeBlockBuffer(
        from buffer: RenderedAudioBuffer,
        frames: Range<Int>
    ) throws -> CMBlockBuffer {
        let byteCount = frames.count * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw ExportError.audioSampleBufferFailed(status)
        }

        let sampleStart = frames.lowerBound * channelCount
        status = buffer.samples.withUnsafeBytes { sampleBytes in
            guard let baseAddress = sampleBytes.baseAddress else {
                return OSStatus(kCMBlockBufferBadLengthParameterErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress.advanced(by: sampleStart * MemoryLayout<Float>.size),
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw ExportError.audioSampleBufferFailed(status)
        }
        return blockBuffer
    }
}
