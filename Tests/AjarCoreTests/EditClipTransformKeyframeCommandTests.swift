// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditClipTransformAnimationTests: XCTestCase {
    func testFRKEY001FRXFORM008AnimatableClipTransformEvaluatesEachParameter() throws {
        let value = try makeEveryParameterAnimation().value(at: editTime(5))

        XCTAssertEqual(value.position, CanvasPoint(x: RationalValue(5), y: RationalValue(10)))
        XCTAssertEqual(value.scale, ClipScale(x: RationalValue(2), y: RationalValue(3)))
        XCTAssertEqual(value.anchorPoint, .zero)
        XCTAssertEqual(value.rotation, ClipRotation(degrees: RationalValue(90)))
        XCTAssertEqual(value.opacity, try RationalValue(numerator: 1, denominator: 2))
        XCTAssertEqual(value.crop, ClipCropInsets(left: 5, top: 10, right: 15, bottom: 20))
        XCTAssertEqual(value.blendMode, .screen)
        XCTAssertEqual(value.flip, ClipFlip(horizontal: true, vertical: false))
    }
}

final class EditClipTransformKeyframeCommandTests: XCTestCase {
    func testFRKEY002TransformKeyframeCommandsAreUndoableAndKeepKeyframesSorted() throws {
        let fixture = try makeEditFixture(seed: 915)
        var history = EditHistory(project: fixture.project)
        let withTwoKeyframes = try addOutOfOrderPositionKeyframes(to: &history, fixture: fixture)
        let editedClip = try requiredClip(fixture.clipID, in: withTwoKeyframes, fixture: fixture)

        try assertPositionKeyframeTimes(editedClip, frames: [2, 6])

        let moved = try movePositionKeyframe(in: &history, fixture: fixture)
        let movedClip = try requiredClip(fixture.clipID, in: moved, fixture: fixture)

        try assertPositionKeyframeTimes(movedClip, frames: [2, 4])

        let deleted = try deletePositionKeyframe(in: &history, fixture: fixture)
        let deletedClip = try requiredClip(fixture.clipID, in: deleted, fixture: fixture)

        try assertPositionKeyframeTimes(deletedClip, frames: [4])
        XCTAssertEqual(history.undo(), moved)
        XCTAssertEqual(try history.redo(), deleted)
    }

    func testFRKEY002DuplicateTransformKeyframeReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 916)
        let keyframe = try positionKeyframe(frame: 2)
        let projectWithKeyframe = try addPositionKeyframe(
            keyframe,
            to: fixture.project,
            fixture: fixture
        )

        try assertTransformKeyframeError(
            addPositionKeyframeCommand(keyframe, fixture: fixture),
            project: projectWithKeyframe,
            expected: .duplicateTransformKeyframeTime(
                clipID: fixture.clipID,
                parameter: .position,
                time: try editTime(2)
            )
        )
    }

    func testFRKEY002OutOfRangeTransformKeyframeReturnsTypedError() throws {
        // The clip covers [0, 10); frame 11 is past even the closed keyframe range
        // [start, end] (an exact-end keyframe is allowed as a blade boundary, FR-XFORM-008).
        let fixture = try makeEditFixture(seed: 917)
        let keyframe = try transformKeyframe(
            frame: 11,
            value: .position(.zero),
            interpolation: .linear
        )

        try assertTransformKeyframeError(
            addPositionKeyframeCommand(keyframe, fixture: fixture),
            project: fixture.project,
            expected: .transformKeyframeTimeOutsideClip(
                clipID: fixture.clipID,
                parameter: .position,
                time: try editTime(11),
                clipRange: try editRange(startFrame: 0, durationFrames: 10)
            )
        )
    }

    func testFRXFORM008TransformKeyframeAtExactClipEndIsAllowed() throws {
        // The timeline end is exclusive and never sampled, but an end keyframe shapes the
        // approach into the cut — blade boundary keyframes land there (FR-XFORM-008).
        let fixture = try makeEditFixture(seed: 922)
        let keyframe = try positionKeyframe(frame: 10)

        let edited = try apply(
            addPositionKeyframeCommand(keyframe, fixture: fixture),
            to: fixture.project
        )

        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        XCTAssertEqual(
            editedClip.transformAnimation.position.keyframes.map(\.time),
            [try editTime(10)]
        )
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testFRKEY002MismatchedTransformKeyframeValueReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 918)
        let keyframe = try transformKeyframe(
            frame: 2,
            value: .opacity(.one),
            interpolation: .linear
        )

        try assertTransformKeyframeError(
            addPositionKeyframeCommand(keyframe, fixture: fixture),
            project: fixture.project,
            expected: .transformKeyframeValueMismatch(
                clipID: fixture.clipID,
                parameter: .position,
                value: .opacity(.one)
            )
        )
    }

    func testFRKEY002MissingTransformKeyframeDeleteReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 919)

        try assertTransformKeyframeError(
            .deleteClipTransformKeyframe(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                parameter: .scale,
                time: try editTime(2)
            ),
            project: fixture.project,
            expected: .transformKeyframeNotFound(
                clipID: fixture.clipID,
                parameter: .scale,
                time: try editTime(2)
            )
        )
    }

    func testFRKEY002InvalidOpacityKeyframeReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 920)
        let opacity = try RationalValue(numerator: 3, denominator: 2)
        let keyframe = try transformKeyframe(
            frame: 2,
            value: .opacity(opacity),
            interpolation: .linear
        )

        try assertTransformKeyframeError(
            .addClipTransformKeyframe(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                parameter: .opacity,
                keyframe: keyframe
            ),
            project: fixture.project,
            expected: .invalidClipTransformKeyframe(
                clipID: fixture.clipID,
                parameter: .opacity,
                time: try editTime(2),
                error: .opacityOutOfRange(opacity)
            )
        )
    }

    func testFRKEY002ProjectValidationRejectsStoredOutOfRangeTransformKeyframe() throws {
        let fixture = try makeEditFixture(seed: 921)
        let invalidClip = try makeClipWithOutOfRangeOpacityKeyframe(fixture: fixture)
        let project = try replacingVideoItems([.clip(invalidClip)], in: fixture)

        guard case .invalid(let errors) = project.validate() else {
            XCTFail("Expected invalid project")
            return
        }

        XCTAssertTrue(
            errors.contains(
                .transformKeyframeTimeOutsideClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: invalidClip.id,
                    parameter: .opacity,
                    time: try editTime(11),
                    clipRange: invalidClip.timelineRange
                )
            )
        )
    }
}

private func makeEveryParameterAnimation() throws -> AnimatableClipTransform {
    try AnimatableClipTransform(
        position: makePositionAnimation(),
        scale: makeScaleAnimation(),
        anchorPoint: makeAnchorPointAnimation(),
        rotation: makeRotationAnimation(),
        opacity: makeOpacityAnimation(),
        crop: makeCropAnimation(),
        blendMode: .screen,
        flip: ClipFlip(horizontal: true, vertical: false)
    )
}

private func makePositionAnimation() throws -> Animatable<CanvasPoint> {
    try Animatable(
        base: .zero,
        keyframes: [
            Keyframe(time: editTime(0), value: .zero, interpolation: .easeInOut),
            Keyframe(
                time: editTime(10),
                value: CanvasPoint(x: RationalValue(10), y: RationalValue(20)),
                interpolation: .hold
            )
        ]
    )
}

private func makeScaleAnimation() throws -> Animatable<ClipScale> {
    try Animatable(
        base: .identity,
        keyframes: [
            Keyframe(time: editTime(0), value: .identity, interpolation: .linear),
            Keyframe(
                time: editTime(10),
                value: ClipScale(x: RationalValue(3), y: RationalValue(5)),
                interpolation: .hold
            )
        ]
    )
}

private func makeAnchorPointAnimation() throws -> Animatable<CanvasPoint> {
    try Animatable(
        base: .zero,
        keyframes: [
            Keyframe(time: editTime(0), value: .zero, interpolation: .hold),
            Keyframe(
                time: editTime(10),
                value: CanvasPoint(x: RationalValue(100), y: RationalValue(200)),
                interpolation: .hold
            )
        ]
    )
}

private func makeRotationAnimation() throws -> Animatable<ClipRotation> {
    try Animatable(
        base: .zero,
        keyframes: [
            Keyframe(time: editTime(0), value: .zero, interpolation: .linear),
            Keyframe(
                time: editTime(10),
                value: ClipRotation(degrees: RationalValue(180)),
                interpolation: .hold
            )
        ]
    )
}

private func makeOpacityAnimation() throws -> Animatable<RationalValue> {
    try Animatable(
        base: .one,
        keyframes: [
            Keyframe(time: editTime(0), value: .one, interpolation: .linear),
            Keyframe(time: editTime(10), value: .zero, interpolation: .hold)
        ]
    )
}

private func makeCropAnimation() throws -> Animatable<ClipCropInsets> {
    try Animatable(
        base: .zero,
        keyframes: [
            Keyframe(time: editTime(0), value: .zero, interpolation: .linear),
            Keyframe(
                time: editTime(10),
                value: ClipCropInsets(left: 10, top: 20, right: 30, bottom: 40),
                interpolation: .hold
            )
        ]
    )
}

private func addOutOfOrderPositionKeyframes(
    to history: inout EditHistory,
    fixture: EditFixture
) throws -> Project {
    try history.apply(addPositionKeyframeCommand(try positionKeyframe(frame: 6), fixture: fixture))
    return try history.apply(
        addPositionKeyframeCommand(
            try positionKeyframe(frame: 2, interpolation: .easeOut),
            fixture: fixture
        )
    )
}

private func movePositionKeyframe(
    in history: inout EditHistory,
    fixture: EditFixture
) throws -> Project {
    let movedKeyframe = try positionKeyframe(frame: 4)
    return try history.apply(
        .moveClipTransformKeyframe(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            parameter: .position,
            fromTime: editTime(6),
            keyframe: movedKeyframe
        )
    )
}

private func deletePositionKeyframe(
    in history: inout EditHistory,
    fixture: EditFixture
) throws -> Project {
    try history.apply(
        .deleteClipTransformKeyframe(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            parameter: .position,
            time: editTime(2)
        )
    )
}

private func makeClipWithOutOfRangeOpacityKeyframe(fixture: EditFixture) throws -> Clip {
    // Frame 11 is past the clip's closed keyframe range [0, 10] — an exact-end keyframe is
    // allowed as a blade boundary (FR-XFORM-008), so out-of-range means strictly beyond it.
    let animation = try AnimatableClipTransform(
        opacity: Animatable(
            base: .one,
            keyframes: [
                Keyframe(time: editTime(11), value: .one, interpolation: .linear)
            ]
        )
    )
    return try makeEditClip(
        id: editUUID(921_100),
        mediaID: fixture.mediaID,
        startFrame: 0,
        transformAnimation: animation
    )
}

private func positionKeyframe(
    frame: Int64,
    interpolation: InterpolationMode = .linear
) throws -> ClipTransformKeyframe {
    try transformKeyframe(
        frame: frame,
        value: .position(CanvasPoint(x: RationalValue(frame), y: RationalValue(frame * 2))),
        interpolation: interpolation
    )
}

private func transformKeyframe(
    frame: Int64,
    value: ClipTransformKeyframeValue,
    interpolation: InterpolationMode
) throws -> ClipTransformKeyframe {
    ClipTransformKeyframe(time: try editTime(frame), value: value, interpolation: interpolation)
}

private func addPositionKeyframe(
    _ keyframe: ClipTransformKeyframe,
    to project: Project,
    fixture: EditFixture
) throws -> Project {
    try apply(addPositionKeyframeCommand(keyframe, fixture: fixture), to: project)
}

private func addPositionKeyframeCommand(
    _ keyframe: ClipTransformKeyframe,
    fixture: EditFixture
) -> EditCommand {
    .addClipTransformKeyframe(
        sequenceID: fixture.sequenceID,
        trackID: fixture.videoTrackID,
        clipID: fixture.clipID,
        parameter: .position,
        keyframe: keyframe
    )
}

private func assertPositionKeyframeTimes(
    _ clip: Clip,
    frames: [Int64],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(
        clip.transformAnimation.position.keyframes.map(\.time),
        try frames.map { try editTime($0) },
        file: file,
        line: line
    )
}

private func assertTransformKeyframeError(
    _ command: EditCommand,
    project: Project,
    expected: EditCommandValidationError,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertThrowsError(try apply(command, to: project), file: file, line: line) { error in
        XCTAssertEqual(
            error as? EditReducerError,
            .invalidEdit(expected),
            file: file,
            line: line
        )
    }
}
