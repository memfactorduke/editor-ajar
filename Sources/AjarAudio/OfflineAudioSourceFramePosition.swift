// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore

extension OfflineAudioMixer {
    static func sourceFramePosition(
        clip: Clip,
        source: AudioSourceBuffer,
        sourceTime: RationalTime
    ) throws -> Double {
        let framePosition = sourceTime.seconds * Double(source.format.sampleRate)
        guard clip.reverse && !clip.freezeFrame else {
            return framePosition
        }

        let sourceEnd = try end(of: clip.sourceRange)
        let sourceOffsetFromEnd = try subtract(sourceEnd, sourceTime)
        let endFrame = try sampleIndex(
            for: sourceEnd,
            sampleRate: source.format.sampleRate,
            rounding: .nearestOrAwayFromZero
        )
        let startFrame = try sampleIndex(
            for: clip.sourceRange.start,
            sampleRate: source.format.sampleRate,
            rounding: .nearestOrAwayFromZero
        )
        let offsetFrames = sourceOffsetFromEnd.seconds * Double(source.format.sampleRate)
        return max(Double(startFrame), Double(max(0, endFrame - 1)) - offsetFrames)
    }
}
