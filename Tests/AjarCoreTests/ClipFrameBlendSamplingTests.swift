// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-004 frame-blend sampling math: fractional-position pairs and weights, integer-position
/// and end-of-span degeneracy, the direction-agnostic reverse convention, and the explicit
/// freeze-frame degeneracy to nearest sampling.
final class ClipFrameBlendSamplingTests: XCTestCase {
    private let frameRate24 = try? FrameRate(frames: 24)

    func testFRSPD004HalfSpeedOddFrameProducesHalfFrameBlendWeight() throws {
        // Constant 1/2x: timeline frame 3 maps to source frame 1.5.
        let clip = try makeSamplingClip(seed: 4_500, speed: try halfSpeed())
        let sourceTime = try clip.sourceTime(at: try editTime(3))
        XCTAssertEqual(sourceTime, try RationalTime(value: 3, timescale: 48))

        let pair = try XCTUnwrap(
            try FrameBlendSampling.blendPair(
                forSourceTime: sourceTime,
                frameRate: try frameRate(),
                sourceEnd: try clip.sourceRange.end()
            )
        )

        XCTAssertEqual(pair.earlierFrameTime, try editTime(1))
        XCTAssertEqual(pair.laterFrameTime, try editTime(2))
        XCTAssertEqual(pair.laterWeight, try RationalValue(numerator: 1, denominator: 2))
    }

    func testFRSPD004QuarterFramePositionProducesQuarterWeight() throws {
        // Source position 1.25 frames at 24 fps: weight 1/4 toward the later frame.
        let pair = try XCTUnwrap(
            try FrameBlendSampling.blendPair(
                forSourceTime: try RationalTime(value: 5, timescale: 96),
                frameRate: try frameRate(),
                sourceEnd: try editTime(10)
            )
        )

        XCTAssertEqual(pair.earlierFrameTime, try editTime(1))
        XCTAssertEqual(pair.laterFrameTime, try editTime(2))
        XCTAssertEqual(pair.laterWeight, try RationalValue(numerator: 1, denominator: 4))
    }

    func testFRSPD004IntegerFramePositionsDegenerateToNearest() throws {
        // Constant 1/2x at an even timeline frame lands exactly on a source frame boundary.
        let clip = try makeSamplingClip(seed: 4_501, speed: try halfSpeed())
        let sourceTime = try clip.sourceTime(at: try editTime(4))
        XCTAssertEqual(sourceTime, try editTime(2))

        XCTAssertNil(
            try FrameBlendSampling.blendPair(
                forSourceTime: sourceTime,
                frameRate: try frameRate(),
                sourceEnd: try clip.sourceRange.end()
            )
        )
    }

    func testFRSPD004RampRemapVariesBlendWeightPerFrame() throws {
        // FR-SPD-002 x FR-SPD-004: a 1/3x-slope curve yields weights 1/3, 2/3, then a
        // frame-exact position, per successive timeline frames.
        let curve = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(0)),
            TimeRemapKeyframe(time: try editTime(9), sourceTime: try editTime(3))
        ])
        let clip = try makeSamplingClip(seed: 4_502, timeRemap: curve, timelineDurationFrames: 9)
        var laterWeights: [RationalValue?] = []
        for frame in Int64(1)...3 {
            let sourceTime = try clip.sourceTime(
                at: try clip.timelineRange.start.adding(try editTime(frame))
            )
            let pair = try FrameBlendSampling.blendPair(
                forSourceTime: sourceTime,
                frameRate: try frameRate(),
                sourceEnd: try clip.sourceRange.end()
            )
            laterWeights.append(pair?.laterWeight)
        }

        XCTAssertEqual(
            laterWeights,
            [
                try RationalValue(numerator: 1, denominator: 3),
                try RationalValue(numerator: 2, denominator: 3),
                nil
            ]
        )
    }

    func testFRSPD004ReverseBlendFractionIsMeasuredTowardLaterSourceFrame() throws {
        // Convention: the pair and weight are computed on the resolved source decode-time axis,
        // with the fraction always measured toward the later source frame. Reversed playback
        // through the same fractional source position therefore blends the same two frames with
        // the same weights as forward playback (direction-agnostic).
        let forwardClip = try makeSamplingClip(seed: 4_503, speed: try halfSpeed())
        // Forward timeline frame 15 -> source frame 7.5.
        let forwardSourceTime = try forwardClip.sourceTime(at: try editTime(15))
        XCTAssertEqual(forwardSourceTime, try RationalTime(value: 15, timescale: 48))

        let reverseClip = try makeSamplingClip(seed: 4_504, speed: try halfSpeed(), reverse: true)
        // Reverse timeline frame 3 -> mathematical source time end - 1.5 = frame 8.5; the
        // discrete decode shift (as applied by frame providers) lands on frame 7.5.
        let reverseSourceTime = try reverseClip.sourceTime(at: try editTime(3))
        XCTAssertEqual(reverseSourceTime, try RationalTime(value: 17, timescale: 48))
        let reverseDecodeTime = try reverseDecodeTime(
            for: reverseClip,
            sourceTime: reverseSourceTime
        )
        XCTAssertEqual(reverseDecodeTime, forwardSourceTime)

        let forwardPair = try XCTUnwrap(
            try FrameBlendSampling.blendPair(
                forSourceTime: forwardSourceTime,
                frameRate: try frameRate(),
                sourceEnd: try forwardClip.sourceRange.end()
            )
        )
        let reversePair = try XCTUnwrap(
            try FrameBlendSampling.blendPair(
                forSourceTime: reverseDecodeTime,
                frameRate: try frameRate(),
                sourceEnd: try reverseClip.sourceRange.end()
            )
        )

        XCTAssertEqual(forwardPair, reversePair)
        XCTAssertEqual(forwardPair.earlierFrameTime, try editTime(7))
        XCTAssertEqual(forwardPair.laterFrameTime, try editTime(8))
        XCTAssertEqual(forwardPair.laterWeight, try RationalValue(numerator: 1, denominator: 2))
    }

    func testFRSPD004FreezeFrameResolvesToNearestSampling() throws {
        // Freeze frames hold one decoded frame, so blend explicitly degenerates to nearest.
        let frozen = RenderSourceNode(
            mediaID: try editUUID(4_505),
            clipID: try editUUID(4_506),
            sourceTime: .zero,
            freezeFrame: true,
            frameSampling: .frameBlend
        )
        XCTAssertEqual(frozen.resolvedFrameSampling, .nearest)

        let blended = RenderSourceNode(
            mediaID: try editUUID(4_505),
            clipID: try editUUID(4_506),
            sourceTime: .zero,
            frameSampling: .frameBlend
        )
        XCTAssertEqual(blended.resolvedFrameSampling, .frameBlend)

        let defaulted = RenderSourceNode(
            mediaID: try editUUID(4_505),
            clipID: try editUUID(4_506),
            sourceTime: .zero
        )
        XCTAssertEqual(defaulted.resolvedFrameSampling, .nearest)
    }

    func testFRSPD004MissingLaterFrameAtSourceEndDegeneratesToNearest() throws {
        // Source position 9.5 in a 10-frame span: the later frame would start on the exclusive
        // end, so only one decodable frame exists and the blend degenerates to nearest.
        XCTAssertNil(
            try FrameBlendSampling.blendPair(
                forSourceTime: try RationalTime(value: 19, timescale: 48),
                frameRate: try frameRate(),
                sourceEnd: try editTime(10)
            )
        )
        // Without an end bound the same position blends frames 9 and 10.
        XCTAssertNotNil(
            try FrameBlendSampling.blendPair(
                forSourceTime: try RationalTime(value: 19, timescale: 48),
                frameRate: try frameRate(),
                sourceEnd: nil
            )
        )
    }

    private func frameRate() throws -> FrameRate {
        try XCTUnwrap(frameRate24)
    }

    private func halfSpeed() throws -> RationalValue {
        try RationalValue(numerator: 1, denominator: 2)
    }

    /// Mirrors the discrete reverse decode shift used by frame providers: the mathematical
    /// half-open source time is re-anchored so timeline start decodes the last frame.
    private func reverseDecodeTime(
        for clip: Clip,
        sourceTime: RationalTime
    ) throws -> RationalTime {
        let sourceEnd = try clip.sourceRange.end()
        let offsetFromEnd = try sourceEnd.subtracting(sourceTime)
        let frameDuration = try frameRate().duration(ofFrames: 1)
        let lastFrameTime = max(clip.sourceRange.start, try sourceEnd.subtracting(frameDuration))
        return max(clip.sourceRange.start, try lastFrameTime.subtracting(offsetFromEnd))
    }

    private func makeSamplingClip(
        seed: Int,
        speed: RationalValue = .one,
        reverse: Bool = false,
        timeRemap: ClipTimeRemap? = nil,
        timelineDurationFrames: Int64? = nil
    ) throws -> Clip {
        let sourceDuration = try editTime(10)
        let timelineDuration: RationalTime
        if let timelineDurationFrames {
            timelineDuration = try editTime(timelineDurationFrames)
        } else {
            timelineDuration = try Clip.timelineDuration(
                forSourceDuration: sourceDuration,
                speed: speed
            )
        }
        return Clip(
            id: try editUUID(seed),
            source: .media(id: try editUUID(seed + 1)),
            sourceRange: try TimeRange(start: editTime(0), duration: sourceDuration),
            timelineRange: try TimeRange(start: editTime(0), duration: timelineDuration),
            kind: .video,
            name: "FR-SPD-004 sampling clip \(seed)",
            speed: speed,
            reverse: reverse,
            timeRemap: timeRemap,
            frameSampling: .frameBlend
        )
    }
}
