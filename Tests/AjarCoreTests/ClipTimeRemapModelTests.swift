// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-002 keyframed time-remap model tests: curve validation, piecewise evaluation,
/// exact constant-speed equivalence, composition policy, and codec back-compat.
final class ClipTimeRemapModelTests: XCTestCase {
    func testFRSPD002CurveValidationReturnsTypedErrors() throws {
        XCTAssertEqual(
            ClipTimeRemap.validate(keyframes: []),
            .insufficientKeyframes(count: 0)
        )
        XCTAssertEqual(
            ClipTimeRemap.validate(keyframes: [try remapKeyframe(0, 0)]),
            .insufficientKeyframes(count: 1)
        )
        XCTAssertEqual(
            ClipTimeRemap.validate(keyframes: [
                try remapKeyframe(1, 0),
                try remapKeyframe(12, 6)
            ]),
            .firstKeyframeNotAtZero(try editTime(1))
        )
        XCTAssertEqual(
            ClipTimeRemap.validate(keyframes: [
                try remapKeyframe(0, 0),
                try remapKeyframe(12, 6),
                try remapKeyframe(12, 8)
            ]),
            .keyframesNotSorted(index: 2, previousTime: try editTime(12), time: try editTime(12))
        )

        let expectedDecrease = ClipTimeRemapValidationError.decreasingSourceTime(
            index: 1,
            previousSourceTime: try editTime(12),
            sourceTime: try editTime(6)
        )
        XCTAssertThrowsError(
            try ClipTimeRemap(keyframes: [
                try remapKeyframe(0, 12),
                try remapKeyframe(12, 6)
            ])
        ) { error in
            XCTAssertEqual(error as? ClipTimeRemapValidationError, expectedDecrease)
        }
    }

    func testFRSPD002MonotonicityRejectsDecreasingCurveOnDecode() throws {
        let json = """
            {"keyframes": [
                {"time": {"value": 0, "timescale": 1}, \
            "sourceTime": {"value": 1, "timescale": 2}},
                {"time": {"value": 1, "timescale": 1}, \
            "sourceTime": {"value": 0, "timescale": 1}}
            ]}
            """
        let expected = ClipTimeRemapValidationError.decreasingSourceTime(
            index: 1,
            previousSourceTime: try RationalTime(value: 1, timescale: 2),
            sourceTime: .zero
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClipTimeRemap.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(error as? ClipTimeRemapValidationError, expected)
        }
    }

    func testFRSPD002RampEvaluatesPiecewiseLinearSourceTimesExactly() throws {
        let clip = try makeRampClip(clipSeed: 4_310)

        // Segment one has slope 1x, segment two has slope 2x (a 1x -> 2x ramp).
        XCTAssertEqual(try clip.sourceTime(at: try editTime(10)), try editTime(0))
        XCTAssertEqual(try clip.sourceTime(at: try editTime(16)), try editTime(6))
        XCTAssertEqual(try clip.sourceTime(at: try editTime(22)), try editTime(12))
        XCTAssertEqual(try clip.sourceTime(at: try editTime(28)), try editTime(24))
        XCTAssertEqual(try clip.sourceTime(at: try editTime(33)), try editTime(34))

        // Exact rational evaluation off the frame grid: offset 11/48 s sits in segment one
        // (slope 1x) and offset 25/48 s sits in segment two (slope 2x).
        let segmentOneTime = try clip.timelineRange.start
            .adding(RationalTime(value: 11, timescale: 48))
        XCTAssertEqual(
            try clip.sourceTime(at: segmentOneTime),
            try RationalTime(value: 11, timescale: 48)
        )
        let segmentTwoTime = try clip.timelineRange.start
            .adding(RationalTime(value: 25, timescale: 48))
        XCTAssertEqual(
            try clip.sourceTime(at: segmentTwoTime),
            try RationalTime(value: 13, timescale: 24)
        )
    }

    func testFRSPD002ZeroSlopeSegmentFreezesWithinRamp() throws {
        let curve = try ClipTimeRemap(keyframes: [
            try remapKeyframe(0, 0),
            try remapKeyframe(6, 6),
            try remapKeyframe(18, 6),
            try remapKeyframe(24, 12)
        ])
        let clip = try makeRemapClip(clipSeed: 4_320, curve: curve, sourceDurationFrames: 12)

        XCTAssertEqual(try clip.sourceTime(at: try editTime(13)), try editTime(3))
        for frame in Int64(16)...28 {
            XCTAssertEqual(try clip.sourceTime(at: try editTime(frame)), try editTime(6))
        }
        XCTAssertEqual(try clip.sourceTime(at: try editTime(31)), try editTime(9))
    }

    func testFRSPD002TwoKeyframeLinearCurveEqualsConstantSpeedExactly() throws {
        let speeds = [
            RationalValue.one,
            RationalValue(2),
            try RationalValue(numerator: 1, denominator: 2),
            try RationalValue(numerator: 3, denominator: 2),
            try RationalValue(numerator: 7, denominator: 5)
        ]

        for (speedIndex, speed) in speeds.enumerated() {
            let constantClip = try makeEditClip(
                id: try editUUID(4_330_000 + speedIndex),
                mediaID: try editUUID(4_330_900),
                startFrame: 10,
                durationFrames: 42,
                speed: speed
            )
            let timelineDuration = constantClip.timelineRange.duration
            let curve = try ClipTimeRemap(keyframes: [
                TimeRemapKeyframe(time: .zero, sourceTime: constantClip.sourceRange.start),
                TimeRemapKeyframe(
                    time: timelineDuration,
                    sourceTime: try constantClip.sourceRange.end()
                )
            ])
            let remapClip = Clip(
                id: constantClip.id,
                source: constantClip.source,
                sourceRange: constantClip.sourceRange,
                timelineRange: constantClip.timelineRange,
                kind: .video,
                name: "FR-SPD-002 equivalence clip",
                timeRemap: curve
            )

            // Sample the shared timeline domain on an odd 97-step grid so common
            // timescales never divide evenly; equality must still be RationalTime-exact.
            for step in Int64(0)...97 {
                let offset = try timelineDuration.multiplied(by: step).divided(by: 97)
                let sampleTime = try constantClip.timelineRange.start.adding(offset)
                XCTAssertEqual(
                    try remapClip.sourceTime(at: sampleTime),
                    try constantClip.sourceTime(at: sampleTime),
                    "speed \(speed.numerator)/\(speed.denominator) diverged at step \(step)"
                )
            }
        }
    }

    private struct RetimeCombination {
        let reverse: Bool
        let freezeFrame: Bool
        let speed: RationalValue
    }

    func testFRSPD002ConflictingRetimeCombinationsThrowTypedErrors() throws {
        let curve = try rampCurve()
        let combinations = [
            RetimeCombination(reverse: true, freezeFrame: false, speed: .one),
            RetimeCombination(reverse: false, freezeFrame: true, speed: .one),
            RetimeCombination(reverse: false, freezeFrame: false, speed: RationalValue(2))
        ]

        for combination in combinations {
            let clip = try makeRemapClip(
                clipSeed: 4_340,
                curve: curve,
                sourceDurationFrames: 36,
                speed: combination.speed,
                reverse: combination.reverse,
                freezeFrame: combination.freezeFrame
            )
            let expected = ClipTimeRemapValidationError.conflictingRetime(
                reverse: combination.reverse,
                freezeFrame: combination.freezeFrame,
                speed: combination.speed
            )

            XCTAssertEqual(clip.validateTimeRemap(), expected)
            XCTAssertThrowsError(try clip.sourceTime(at: try editTime(12))) { error in
                XCTAssertEqual(
                    error as? ClipSpeedMappingError,
                    .invalidTimeRemap(expected)
                )
            }
        }
    }

    func testFRSPD002ProjectValidationRejectsDomainAndSourceBoundViolations() throws {
        let fixture = try makeEditFixture(seed: 4_350)

        // Curve domain (12 frames) shorter than the clip's timeline duration (24 frames).
        let shortCurve = try ClipTimeRemap(keyframes: [
            try remapKeyframe(0, 0),
            try remapKeyframe(12, 12)
        ])
        let mismatchedClip = try makeRemapClip(
            clipSeed: 4_351,
            curve: shortCurve,
            sourceDurationFrames: 36,
            timelineDurationFrames: 24,
            mediaID: fixture.mediaID
        )
        try assertValidationError(
            replacingVideoItems([.clip(mismatchedClip)], in: fixture),
            fixture: fixture,
            clipID: mismatchedClip.id,
            expected: .curveDurationMismatch(
                curveDuration: try editTime(12),
                timelineDuration: try editTime(24)
            )
        )

        // Curve maps past the end of the source range: no read past source bounds.
        let overrunCurve = try ClipTimeRemap(keyframes: [
            try remapKeyframe(0, 0),
            try remapKeyframe(24, 48)
        ])
        let overrunClip = try makeRemapClip(
            clipSeed: 4_352,
            curve: overrunCurve,
            sourceDurationFrames: 36,
            timelineDurationFrames: 24,
            mediaID: fixture.mediaID
        )
        try assertValidationError(
            replacingVideoItems([.clip(overrunClip)], in: fixture),
            fixture: fixture,
            clipID: overrunClip.id,
            expected: .sourceTimeOutOfBounds(
                sourceTime: try editTime(48),
                sourceRange: overrunClip.sourceRange
            )
        )
    }

    func testFRSPD002EvaluationClampsOutsideCurveDomainToEndpointSourceTimes() throws {
        let curve = try rampCurve()

        XCTAssertEqual(
            try curve.sourceTime(atOffset: try RationalTime(value: -1, timescale: 24)),
            try editTime(0)
        )
        XCTAssertEqual(try curve.sourceTime(atOffset: try editTime(99)), try editTime(36))
    }

    private func assertValidationError(
        _ project: Project,
        fixture: EditFixture,
        clipID: UUID,
        expected: ClipTimeRemapValidationError
    ) throws {
        guard case .invalid(let errors) = project.validate() else {
            return XCTFail("Expected invalid FR-SPD-002 project for \(expected)")
        }
        XCTAssertTrue(
            errors.contains(
                .invalidClipTimeRemap(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: clipID,
                    error: expected
                )
            ),
            "missing \(expected) in \(errors)"
        )
    }
}

/// Builds a two-segment 1x -> 2x ramp: 12 timeline frames at 1x, then 12 frames at 2x.
func rampCurve() throws -> ClipTimeRemap {
    try ClipTimeRemap(keyframes: [
        try remapKeyframe(0, 0),
        try remapKeyframe(12, 12),
        try remapKeyframe(24, 36)
    ])
}

func remapKeyframe(_ offsetFrames: Int64, _ sourceFrames: Int64) throws -> TimeRemapKeyframe {
    TimeRemapKeyframe(
        time: try editTime(offsetFrames),
        sourceTime: try editTime(sourceFrames)
    )
}

/// Builds a remapped clip starting at timeline frame 10 with source range starting at zero.
func makeRemapClip(
    clipSeed: Int,
    curve: ClipTimeRemap,
    sourceDurationFrames: Int64,
    timelineDurationFrames: Int64? = nil,
    mediaID: UUID? = nil,
    speed: RationalValue = .one,
    reverse: Bool = false,
    freezeFrame: Bool = false
) throws -> Clip {
    let timelineDuration: RationalTime
    if let timelineDurationFrames {
        timelineDuration = try editTime(timelineDurationFrames)
    } else {
        timelineDuration = curve.duration
    }
    return Clip(
        id: try editUUID(clipSeed),
        source: .media(id: try mediaID ?? editUUID(clipSeed + 1)),
        sourceRange: try TimeRange(start: editTime(0), duration: editTime(sourceDurationFrames)),
        timelineRange: try TimeRange(start: editTime(10), duration: timelineDuration),
        kind: .video,
        name: "FR-SPD-002 remap clip \(clipSeed)",
        speed: speed,
        reverse: reverse,
        freezeFrame: freezeFrame,
        timeRemap: curve
    )
}

/// Builds the shared 1x -> 2x ramp clip used by evaluation tests.
func makeRampClip(clipSeed: Int) throws -> Clip {
    try makeRemapClip(clipSeed: clipSeed, curve: rampCurve(), sourceDurationFrames: 36)
}
