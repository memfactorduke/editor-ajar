// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

struct EditorAjarPlaybackController {
    private(set) var playheadFrame: Int64
    private let frameRate: FrameRate
    private let durationFrames: Int64
    private var accumulatedSeconds: Double = 0
    private(set) var playbackRate: Int = 0
    private var loopRange: ClosedRange<Int64>?

    init(frameRate: FrameRate, durationFrames: Int64, playheadFrame: Int64 = 0) {
        self.frameRate = frameRate
        self.durationFrames = max(1, durationFrames)
        self.playheadFrame = max(0, min(playheadFrame, self.durationFrames - 1))
    }

    var frameRateDescription: String {
        frameRate.description
    }

    mutating func stepBackward() {
        playbackRate = 0
        accumulatedSeconds = 0
        playheadFrame = max(0, playheadFrame - 1)
    }

    mutating func stepForward() {
        playbackRate = 0
        accumulatedSeconds = 0
        playheadFrame = nextFrame(after: playheadFrame)
    }

    mutating func scrub(to frame: Int64) {
        playbackRate = 0
        accumulatedSeconds = 0
        playheadFrame = max(0, min(frame, durationFrames - 1))
    }

    mutating func shuttleBackward() {
        playbackRate = playbackRate < 0 ? max(-4, playbackRate * 2) : -1
    }

    mutating func shuttlePause() {
        playbackRate = 0
        accumulatedSeconds = 0
    }

    mutating func shuttleForward() {
        playbackRate = playbackRate > 0 ? min(4, playbackRate * 2) : 1
    }

    mutating func setLoopRange(_ range: ClosedRange<Int64>?) {
        loopRange = range.map {
            let lo = max(0, min($0.lowerBound, durationFrames - 1))
            let hi = max(lo, min($0.upperBound, durationFrames - 1))
            return lo...hi
        }
    }

    mutating func advance(by displayDeltaSeconds: Double) -> Bool {
        guard displayDeltaSeconds > 0 else {
            return false
        }

        // An active loop range plays forward at 1x even when the transport rate is
        // neutral; pausing is gated by the app model's `isPlaying` before `advance`.
        let effectiveRate = playbackRate != 0 ? playbackRate : (loopRange == nil ? 0 : 1)
        guard effectiveRate != 0 else {
            return false
        }
        accumulatedSeconds += displayDeltaSeconds * Double(abs(effectiveRate))
        let secondsPerFrame = Double(frameRate.seconds) / Double(frameRate.frames)
        var didAdvance = false

        while accumulatedSeconds >= secondsPerFrame {
            accumulatedSeconds -= secondsPerFrame
            playheadFrame = effectiveRate > 0
                ? nextFrame(after: playheadFrame)
                : previousFrame(before: playheadFrame)
            didAdvance = true
        }

        return didAdvance
    }

    func timeForCurrentFrame() throws -> RationalTime {
        try RationalTime.atFrame(playheadFrame, frameRate: frameRate)
    }

    private func nextFrame(after frame: Int64) -> Int64 {
        if let loopRange, frame >= loopRange.upperBound {
            return loopRange.lowerBound
        }
        let nextFrame = frame + 1
        if nextFrame >= durationFrames {
            return 0
        }
        return nextFrame
    }

    private func previousFrame(before frame: Int64) -> Int64 {
        if let loopRange, frame <= loopRange.lowerBound {
            return loopRange.upperBound
        }
        return frame > 0 ? frame - 1 : max(0, durationFrames - 1)
    }
}
