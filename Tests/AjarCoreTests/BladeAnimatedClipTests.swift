// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Blade fidelity for keyframe-animated clips (FR-XFORM-008, FR-TL-004): each half keeps
/// the keyframes inside its own range plus a boundary keyframe evaluated at the cut, the
/// segment crossing the cut has its easing subdivided, and the rendered animation is
/// unchanged by the blade at probe times spanning both halves.
final class BladeAnimatedClipTests: XCTestCase {
    func testFRXFORM008BladeSplitsTransformKeyframesWithBoundaryAtCut() throws {
        let fixture = try makeEditFixture(seed: 975)
        let project = try makeAnimatedProject(fixture: fixture)
        let cut = try editTime(4)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 4), to: project)

        let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
        let leftTimes = left.transformAnimation.position.keyframes.map(\.time)
        let rightTimes = right.transformAnimation.position.keyframes.map(\.time)
        XCTAssertEqual(leftTimes, [try editTime(2), cut])
        XCTAssertEqual(rightTimes, [cut, try editTime(6), try editTime(9)])
        // The shared boundary keyframe carries the value evaluated at the cut.
        XCTAssertEqual(
            left.transformAnimation.position.keyframes.last?.value,
            right.transformAnimation.position.keyframes.first?.value
        )
        // No out-of-range keyframes: the left boundary sits on its exclusive end, which
        // project validation accepts (the end is never sampled).
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testFRXFORM008BladeInsideLinearSegmentReproducesAnimation() throws {
        // The cut at 4 lands inside the linear position segment 2 → 6 and inside the
        // hold opacity segment 1 → 7.
        let fixture = try makeEditFixture(seed: 976)
        let project = try makeAnimatedProject(fixture: fixture)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 4), to: project)

        try assertBladedAnimationMatches(
            edited: edited,
            fixture: fixture,
            cutFrame: 4
        )
    }

    func testFRXFORM008BladeInsideEaseSegmentSubdividesTiming() throws {
        // The cut at 7 lands inside the easeInOut position segment 6 → 9: both halves
        // must retrace the original easing through subdivided Bezier timing curves.
        let fixture = try makeEditFixture(seed: 977)
        let project = try makeAnimatedProject(fixture: fixture)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 7), to: project)

        let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
        // The crossing segment's halves become custom Bezier modes.
        guard
            case .bezier = left.transformAnimation.position.keyframes.last?.interpolation,
            case .bezier = right.transformAnimation.position.keyframes.first?.interpolation
        else {
            XCTFail("Expected subdivided Bezier timing on the boundary keyframes")
            return
        }
        try assertBladedAnimationMatches(
            edited: edited,
            fixture: fixture,
            cutFrame: 7
        )
    }

    func testFRXFORM008BladeExactlyOnKeyframeKeepsAnimation() throws {
        let fixture = try makeEditFixture(seed: 978)
        let project = try makeAnimatedProject(fixture: fixture)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 6), to: project)

        let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
        // The keyframe at the cut starts the right half; the left half ends with a copy.
        XCTAssertEqual(
            left.transformAnimation.position.keyframes.map(\.time),
            [try editTime(2), try editTime(6)]
        )
        XCTAssertEqual(
            right.transformAnimation.position.keyframes.map(\.time),
            [try editTime(6), try editTime(9)]
        )
        try assertBladedAnimationMatches(
            edited: edited,
            fixture: fixture,
            cutFrame: 6
        )
    }

    func testFRXFORM008BladeSplitsEffectsAnimationAcrossHalves() throws {
        let fixture = try makeEditFixture(seed: 979)
        let project = try makeAnimatedProject(fixture: fixture)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 5), to: project)

        let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
        let leftTimes = left.effectsAnimation.colorCorrection.saturation.keyframes.map(\.time)
        let rightTimes = right.effectsAnimation.colorCorrection.saturation.keyframes.map(\.time)
        XCTAssertEqual(leftTimes, [try editTime(2), try editTime(5)])
        XCTAssertEqual(rightTimes, [try editTime(5), try editTime(8)])
        try assertBladedAnimationMatches(
            edited: edited,
            fixture: fixture,
            cutFrame: 5
        )
    }

    func testFRXFORM008BladeAnimatedClipUndoRedoIdentity() throws {
        let fixture = try makeEditFixture(seed: 980)
        let project = try makeAnimatedProject(fixture: fixture)

        try assertUndoRedoIdentity(
            project: project,
            command: bladeCommand(fixture: fixture, atFrame: 7)
        )
    }

    func testFRXFORM008BezierSubdivisionReconstructsOriginalTimingCurve() throws {
        let custom = CubicBezierTimingCurve(
            controlPoint1: CubicBezierTimingControlPoint(
                x: RationalValue.approximating(0.3),
                y: RationalValue.approximating(0.1)
            ),
            controlPoint2: CubicBezierTimingControlPoint(
                x: RationalValue.approximating(0.7),
                y: RationalValue.approximating(1.0)
            )
        )
        let curves: [CubicBezierTimingCurve] = [.easeIn, .easeOut, .easeInOut, custom]
        for (curveIndex, curve) in curves.enumerated() {
            for fractionStep in [Int64(13), 49, 71] {
                let fraction = Double(fractionStep) / 97
                let halves = curve.subdivided(atFraction: fraction)
                let left = try XCTUnwrap(halves.left)
                let right = try XCTUnwrap(halves.right)
                let splitY = curve.value(at: fraction)
                for step in Int64(0)...97 {
                    let x = Double(step) / 97
                    let reconstructed: Double =
                        x <= fraction
                        ? splitY * left.value(at: x / fraction)
                        : splitY + ((1 - splitY) * right.value(
                            at: (x - fraction) / (1 - fraction)
                        ))
                    XCTAssertEqual(
                        reconstructed,
                        curve.value(at: x),
                        accuracy: 1e-4,
                        "curve \(curveIndex) split \(fractionStep)/97 diverged at \(step)/97"
                    )
                }
            }
        }
    }

    func testFRXFORM008BladeOvershootEaseSegmentReproducesAnimation() throws {
        // The custom easing overshoots progress above 1 and below 0 mid-segment. Blading
        // at frame 4 (progress ≈ 1.07) and frame 6 (progress ≈ −0.07) renormalizes with
        // the split progress outside [0, 1] — exact, not degenerate, never curve reuse.
        let fixture = try makeEditFixture(seed: 981)
        let clip = try makeOvershootClip(fixture: fixture, curve: overshootCurve())
        let project = try replacingVideoItems([.clip(clip)], in: fixture)

        for cutFrame in [Int64(4), 6] {
            let edited = try apply(bladeCommand(fixture: fixture, atFrame: cutFrame), to: project)
            try assertBladedPositionMatches(
                original: clip,
                edited: edited,
                fixture: fixture,
                cutFrame: cutFrame
            )
            XCTAssertEqual(edited.validate(), .valid)
        }
    }

    func testFRXFORM008BladeAtOvershootExtremumBakesExactInteriorKeyframe() throws {
        // This curve's progress returns to exactly 1 at the segment midpoint (x controls
        // 2/5 and 3/5 with y controls 2 and 1/3 give f(1/2) = 1 to Double precision), so
        // a blade at frame 5 makes the right half's renormalization denominator vanish.
        // The split stays exact by baking an interior keyframe on the right half.
        let extremumCurve = CubicBezierTimingCurve(
            controlPoint1: CubicBezierTimingControlPoint(
                x: try RationalValue(numerator: 2, denominator: 5),
                y: RationalValue(2)
            ),
            controlPoint2: CubicBezierTimingControlPoint(
                x: try RationalValue(numerator: 3, denominator: 5),
                y: try RationalValue(numerator: 1, denominator: 3)
            )
        )
        let fixture = try makeEditFixture(seed: 982)
        let clip = try makeOvershootClip(fixture: fixture, curve: extremumCurve)
        let project = try replacingVideoItems([.clip(clip)], in: fixture)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 5), to: project)

        let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
        let rightKeyframes = right.transformAnimation.position.keyframes
        // Boundary at the cut, one baked interior keyframe, and the original end keyframe.
        XCTAssertEqual(rightKeyframes.count, 3)
        let interiorTime = try XCTUnwrap(rightKeyframes.dropFirst().first).time
        XCTAssertGreaterThan(interiorTime, try editTime(5))
        XCTAssertLessThan(interiorTime, try editTime(8))
        try assertBladedPositionMatches(
            original: clip,
            edited: edited,
            fixture: fixture,
            cutFrame: 5
        )
        XCTAssertEqual(edited.validate(), .valid)
    }
}

// MARK: - Fixture

/// The right-half clip ID used by every blade in this file.
private func bladeRightID() throws -> UUID {
    try editUUID(975_500)
}

private func bladeCommand(fixture: EditFixture, atFrame frame: Int64) throws -> EditCommand {
    .bladeClip(
        sequenceID: fixture.sequenceID,
        trackID: fixture.videoTrackID,
        clipID: fixture.clipID,
        atTime: try editTime(frame),
        rightClipID: try bladeRightID()
    )
}

/// A clip on `[0, 10)` with keyframed position (linear then easeInOut segments), a hold
/// opacity span, and a keyframed color-correction saturation ramp.
private func makeAnimatedClip(fixture: EditFixture) throws -> Clip {
    let transformAnimation = try AnimatableClipTransform(
        position: Animatable(
            base: .zero,
            keyframes: [
                Keyframe(
                    time: try editTime(2),
                    value: CanvasPoint(x: .zero, y: .zero),
                    interpolation: .linear
                ),
                Keyframe(
                    time: try editTime(6),
                    value: CanvasPoint(x: RationalValue(48), y: RationalValue(24)),
                    interpolation: .easeInOut
                ),
                Keyframe(
                    time: try editTime(9),
                    value: CanvasPoint(x: RationalValue(96), y: RationalValue(12)),
                    interpolation: .linear
                )
            ]
        ),
        opacity: Animatable(
            base: .one,
            keyframes: [
                Keyframe(time: try editTime(1), value: .one, interpolation: .hold),
                Keyframe(
                    time: try editTime(7),
                    value: try RationalValue(numerator: 1, denominator: 2),
                    interpolation: .linear
                )
            ]
        )
    )
    let effectsAnimation = AnimatableClipEffects(
        colorCorrection: AnimatableClipColorCorrection(
            saturation: try Animatable(
                base: .one,
                keyframes: [
                    Keyframe(time: try editTime(2), value: .one, interpolation: .linear),
                    Keyframe(
                        time: try editTime(8),
                        value: try RationalValue(numerator: 1, denominator: 2),
                        interpolation: .easeOut
                    )
                ]
            )
        )
    )
    return try makeEditClip(
        id: fixture.clipID,
        mediaID: fixture.mediaID,
        startFrame: 0,
        transformAnimation: transformAnimation,
        effectsAnimation: effectsAnimation
    )
}

private func makeAnimatedProject(fixture: EditFixture) throws -> Project {
    try replacingVideoItems([.clip(try makeAnimatedClip(fixture: fixture))], in: fixture)
}

/// A storable easing that overshoots progress above 1 and below 0 mid-segment.
private func overshootCurve() -> CubicBezierTimingCurve {
    CubicBezierTimingCurve(
        controlPoint1: CubicBezierTimingControlPoint(
            x: RationalValue.approximating(0.2),
            y: RationalValue(4)
        ),
        controlPoint2: CubicBezierTimingControlPoint(
            x: RationalValue.approximating(0.8),
            y: RationalValue(-3)
        )
    )
}

/// A clip on `[0, 10)` with one position segment `2 → 8` eased by `curve`.
private func makeOvershootClip(
    fixture: EditFixture,
    curve: CubicBezierTimingCurve
) throws -> Clip {
    let transformAnimation = try AnimatableClipTransform(
        position: Animatable(
            base: .zero,
            keyframes: [
                Keyframe(
                    time: try editTime(2),
                    value: CanvasPoint(x: .zero, y: .zero),
                    interpolation: .bezier(curve)
                ),
                Keyframe(
                    time: try editTime(8),
                    value: CanvasPoint(x: RationalValue(96), y: RationalValue(48)),
                    interpolation: .linear
                )
            ]
        )
    )
    return try makeEditClip(
        id: fixture.clipID,
        mediaID: fixture.mediaID,
        startFrame: 0,
        transformAnimation: transformAnimation
    )
}

// MARK: - Probe assertions

/// Asserts the bladed halves reproduce the unbladed animation on a 97-step probe grid
/// spanning both halves: exact for hold spans, within a tight tolerance where boundary
/// values pass through the rational micro-unit grid.
private func assertBladedAnimationMatches(
    edited: Project,
    fixture: EditFixture,
    cutFrame: Int64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let original = try makeAnimatedClip(fixture: fixture)
    let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
    let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
    let cut = try editTime(cutFrame)
    for step in Int64(0)...96 {
        let probe = try original.timelineRange.start.adding(
            original.timelineRange.duration.multiplied(by: step).divided(by: 97)
        )
        let half = probe < cut ? left : right
        let expected = original.transformAnimation.value(at: probe)
        let actual = half.transformAnimation.value(at: probe)
        assertClose(
            actual.position,
            expected.position,
            "position diverged at probe step \(step)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.opacity.doubleValue,
            expected.opacity.doubleValue,
            accuracy: 1e-3,
            "opacity diverged at probe step \(step)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            half.effectsAnimation.value(at: probe).colorCorrection.saturation.doubleValue,
            original.effectsAnimation.value(at: probe).colorCorrection.saturation.doubleValue,
            accuracy: 1e-3,
            "saturation diverged at probe step \(step)",
            file: file,
            line: line
        )
    }
}

/// Asserts the bladed halves reproduce the unbladed position animation on a dense
/// 97-step probe grid spanning both halves (used by the overshoot-easing cases).
private func assertBladedPositionMatches(
    original: Clip,
    edited: Project,
    fixture: EditFixture,
    cutFrame: Int64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
    let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
    let cut = try editTime(cutFrame)
    for step in Int64(0)...96 {
        let probe = try original.timelineRange.start.adding(
            original.timelineRange.duration.multiplied(by: step).divided(by: 97)
        )
        let half = probe < cut ? left : right
        assertClose(
            half.transformAnimation.value(at: probe).position,
            original.transformAnimation.value(at: probe).position,
            "overshoot position diverged at probe step \(step) (cut \(cutFrame))",
            accuracy: 5e-3,
            file: file,
            line: line
        )
    }
}

private func assertClose(
    _ actual: CanvasPoint,
    _ expected: CanvasPoint,
    _ message: String,
    accuracy: Double = 1e-3,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        actual.x.doubleValue,
        expected.x.doubleValue,
        accuracy: accuracy,
        message,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.y.doubleValue,
        expected.y.doubleValue,
        accuracy: accuracy,
        message,
        file: file,
        line: line
    )
}
