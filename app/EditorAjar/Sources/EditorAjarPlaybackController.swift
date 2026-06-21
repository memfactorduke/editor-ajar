// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

struct EditorAjarPlaybackController {
    private(set) var playheadFrame: Int64
    private let frameRate: FrameRate
    private let durationFrames: Int64
    private var accumulatedSeconds: Double = 0

    init(frameRate: FrameRate, durationFrames: Int64, playheadFrame: Int64 = 0) {
        self.frameRate = frameRate
        self.durationFrames = max(1, durationFrames)
        self.playheadFrame = max(0, min(playheadFrame, self.durationFrames - 1))
    }

    var frameRateDescription: String {
        frameRate.description
    }

    mutating func stepBackward() {
        accumulatedSeconds = 0
        playheadFrame = max(0, playheadFrame - 1)
    }

    mutating func stepForward() {
        accumulatedSeconds = 0
        playheadFrame = nextFrame(after: playheadFrame)
    }

    mutating func scrub(to frame: Int64) {
        accumulatedSeconds = 0
        playheadFrame = max(0, min(frame, durationFrames - 1))
    }

    mutating func advance(by displayDeltaSeconds: Double) -> Bool {
        guard displayDeltaSeconds > 0 else {
            return false
        }

        accumulatedSeconds += displayDeltaSeconds
        let secondsPerFrame = Double(frameRate.seconds) / Double(frameRate.frames)
        var didAdvance = false

        while accumulatedSeconds >= secondsPerFrame {
            accumulatedSeconds -= secondsPerFrame
            playheadFrame = nextFrame(after: playheadFrame)
            didAdvance = true
        }

        return didAdvance
    }

    func timeForCurrentFrame() throws -> RationalTime {
        try RationalTime.atFrame(playheadFrame, frameRate: frameRate)
    }

    private func nextFrame(after frame: Int64) -> Int64 {
        let nextFrame = frame + 1
        if nextFrame >= durationFrames {
            return 0
        }
        return nextFrame
    }
}
