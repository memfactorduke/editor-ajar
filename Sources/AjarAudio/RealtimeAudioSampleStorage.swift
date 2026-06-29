// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio

final class RealtimeAudioSampleStorage: @unchecked Sendable {
    let kind = RealtimeAudioStorageKind.ownedPointer

    private let pointer: UnsafeMutablePointer<Float>
    private let sampleCount: Int

    init(samples: [Float]) {
        sampleCount = samples.count
        pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(sampleCount, 1))
        guard sampleCount > 0 else {
            return
        }

        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else {
                return
            }
            pointer.initialize(from: baseAddress, count: source.count)
        }
    }

    deinit {
        pointer.deinitialize(count: sampleCount)
        pointer.deallocate()
    }

    func copySamples(
        startingAt sourceOffset: Int,
        count: Int,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let sourceBase = pointer.advanced(by: sourceOffset)
        for sampleIndex in 0..<count {
            output[sampleIndex] = sourceBase[sampleIndex]
        }
    }

    func copyNonInterleavedFrames(
        startingAt sourceFrame: Int,
        frameCount: Int,
        channelCount: Int,
        into buffers: UnsafeMutableAudioBufferListPointer
    ) {
        for channelIndex in 0..<channelCount {
            guard let data = buffers[channelIndex].mData else {
                continue
            }
            let output = data.assumingMemoryBound(to: Float.self)
            let sourceOffset = sourceFrame * channelCount + channelIndex
            for frameIndex in 0..<frameCount {
                output[frameIndex] = pointer[sourceOffset + frameIndex * channelCount]
            }
        }
    }
}
