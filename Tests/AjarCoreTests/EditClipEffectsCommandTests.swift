// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditClipEffectsCommandTests: XCTestCase {
    func testFRCOMP001ChromaKeySettingsHaveDisabledDefaults() throws {
        let fixture = try makeEditFixture(seed: 1_100)
        let clip = try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)

        XCTAssertEqual(clip.effects, .none)
        XCTAssertEqual(clip.effects.chromaKey, .disabled)
        XCTAssertEqual(clip.effects.lumaKey, .disabled)
        XCTAssertEqual(clip.effects.colorCorrection, .identity)
    }

    func testFRCOMP001SetClipChromaKeyRoutesThroughUndoableHistory() throws {
        let fixture = try makeEditFixture(seed: 1_110)
        let settings = try makeChromaKeySettings()
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            .setClipChromaKey(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                settings: settings
            )
        )
        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(editedClip.effects.chromaKey, settings)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRCOMP001InvalidChromaKeySettingsReturnTypedErrors() throws {
        let fixture = try makeEditFixture(seed: 1_120)
        let lowTolerance = try RationalValue(numerator: -1, denominator: 10)
        let highSoftness = try RationalValue(numerator: 11, denominator: 10)
        let highSpill = try RationalValue(numerator: 3, denominator: 2)
        let highRed = try RationalValue(numerator: 2, denominator: 1)
        let invalidCases: [(ClipChromaKeySettings, ClipEffectsValidationError)] = [
            (
                try makeChromaKeySettings(tolerance: lowTolerance),
                .chromaKeyToleranceOutOfRange(lowTolerance)
            ),
            (
                try makeChromaKeySettings(edgeSoftness: highSoftness),
                .chromaKeyEdgeSoftnessOutOfRange(highSoftness)
            ),
            (
                try makeChromaKeySettings(spillSuppression: highSpill),
                .chromaKeySpillSuppressionOutOfRange(highSpill)
            ),
            (
                try makeChromaKeySettings(
                    keyColor: ClipRGBColor(red: highRed, green: .one, blue: .zero)
                ),
                .colorChannelOutOfRange(channel: .red, value: highRed)
            )
        ]

        for (settings, expectedError) in invalidCases {
            XCTAssertThrowsError(
                try apply(
                    .setClipChromaKey(
                        sequenceID: fixture.sequenceID,
                        trackID: fixture.videoTrackID,
                        clipID: fixture.clipID,
                        settings: settings
                    ),
                    to: fixture.project
                )
            ) { error in
                XCTAssertEqual(
                    error as? EditReducerError,
                    .invalidEdit(
                        .invalidClipEffects(clipID: fixture.clipID, error: expectedError)
                    )
                )
            }
        }
    }

    func testFRCOMP001ProjectValidationRejectsInvalidStoredChromaKey() throws {
        let fixture = try makeEditFixture(seed: 1_130)
        let highTolerance = try RationalValue(numerator: 5, denominator: 4)
        let invalidClip = try makeEditClip(
            id: try editUUID(1_130_100),
            mediaID: fixture.mediaID,
            startFrame: 20,
            effects: ClipEffects(
                chromaKey: try makeChromaKeySettings(tolerance: highTolerance)
            )
        )
        let project = try replacingVideoItems(
            [.clip(invalidClip)],
            in: fixture
        )

        guard case .invalid(let errors) = project.validate() else {
            XCTFail("Expected invalid project")
            return
        }

        XCTAssertTrue(
            errors.contains(
                .invalidClipEffects(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: invalidClip.id,
                    error: .chromaKeyToleranceOutOfRange(highTolerance)
                )
            )
        )
    }

    func testFRCOMP003ClipMaskCommandsRouteThroughUndoableHistory() throws {
        let fixture = try makeEditFixture(seed: 1_140)
        let rectangleMask = try makeRectangleMask(id: try editUUID(1_140_100), x: 0, width: 10)
        let ellipseMask = try makeEllipseMask(id: try editUUID(1_140_101))
        let replacementMask = try makeRectangleMask(
            id: rectangleMask.id,
            x: 1,
            width: 8,
            invert: true
        )
        var sequence = try applyMaskCommandSequence(
            fixture: fixture,
            rectangleMask: rectangleMask,
            ellipseMask: ellipseMask,
            replacementMask: replacementMask
        )
        let editedClip = try requiredClip(
            fixture.clipID,
            in: sequence.afterRemove,
            fixture: fixture
        )

        XCTAssertEqual(editedClip.effects.masks, [replacementMask])
        try assertMaskCommandUndoRedo(sequence: &sequence, fixture: fixture)
    }

    func testFRCOMP003NegativeClipMaskFeatherReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 1_150)
        let invalidFeather = try RationalValue(numerator: -1, denominator: 1)
        let invalidMask = try makeRectangleMask(
            id: try editUUID(1_150_100),
            x: 0,
            width: 10,
            featherRadius: invalidFeather
        )

        XCTAssertThrowsError(
            try apply(
                .addClipMask(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    mask: invalidMask
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .invalidClipEffects(
                        clipID: fixture.clipID,
                        error: .clipMaskFeatherRadiusNegative(
                            maskID: invalidMask.id,
                            invalidFeather
                        )
                    )
                )
            )
        }
    }

    func testFRCOMP003InvalidMaskMoveDestinationReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 1_151)
        let maskID = try editUUID(1_151_100)
        let projectWithMask = try apply(
            .addClipMask(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                mask: try makeRectangleMask(id: maskID, x: 0, width: 10)
            ),
            to: fixture.project
        )
        XCTAssertThrowsError(
            try apply(
                .moveClipMask(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    maskID: maskID,
                    destinationIndex: 4
                ),
                to: projectWithMask
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .clipMaskDestinationIndexOutOfRange(
                        clipID: fixture.clipID,
                        index: 4,
                        count: 1
                    )
                )
            )
        }
    }

    func testFRCOMP003ProjectValidationRejectsInvalidStoredMasks() throws {
        let fixture = try makeEditFixture(seed: 1_160)
        let invalidMaskID = try editUUID(1_160_100)
        let invalidClip = try makeEditClip(
            id: try editUUID(1_160_101),
            mediaID: fixture.mediaID,
            startFrame: 20,
            effects: ClipEffects(
                masks: [
                    ClipMask(
                        id: invalidMaskID,
                        shape: .polygon(
                            ClipPolygonMask(
                                points: [
                                    CanvasPoint(x: .zero, y: .zero),
                                    CanvasPoint(x: .one, y: .zero)
                                ]
                            )
                        )
                    )
                ]
            )
        )
        let project = try replacingVideoItems([.clip(invalidClip)], in: fixture)

        guard case .invalid(let errors) = project.validate() else {
            XCTFail("Expected invalid project")
            return
        }
        let expectedError = ProjectValidationError.invalidClipEffects(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: invalidClip.id,
            error: .clipMaskPolygonPointCountInvalid(
                maskID: invalidMaskID,
                count: 2,
                maximum: ClipMaskLimits.maximumPolygonPointCount
            )
        )

        XCTAssertEqual(errors.filter { $0 == expectedError }.count, 1)
    }
}

private func makeChromaKeySettings(
    keyColor: ClipRGBColor = .green,
    tolerance: RationalValue? = nil,
    edgeSoftness: RationalValue? = nil,
    spillSuppression: RationalValue? = nil
) throws -> ClipChromaKeySettings {
    let resolvedTolerance = try tolerance ?? RationalValue(numerator: 1, denominator: 4)
    let resolvedEdgeSoftness = try edgeSoftness ?? RationalValue(numerator: 1, denominator: 10)
    let resolvedSpillSuppression = try spillSuppression
        ?? RationalValue(numerator: 1, denominator: 2)

    return ClipChromaKeySettings(
        enabled: true,
        keyColor: keyColor,
        tolerance: resolvedTolerance,
        edgeSoftness: resolvedEdgeSoftness,
        spillSuppression: resolvedSpillSuppression
    )
}

private struct MaskCommandSequence {
    var history: EditHistory
    let afterAddRectangle: Project
    let afterAddEllipse: Project
    let afterMove: Project
    let afterSet: Project
    let afterRemove: Project
}

private func applyMaskCommandSequence(
    fixture: EditFixture,
    rectangleMask: ClipMask,
    ellipseMask: ClipMask,
    replacementMask: ClipMask
) throws -> MaskCommandSequence {
    var history = EditHistory(project: fixture.project)
    let afterAddRectangle = try applyAddMask(rectangleMask, fixture: fixture, history: &history)
    let afterAddEllipse = try applyAddMask(ellipseMask, fixture: fixture, history: &history)
    let afterMove = try history.apply(
        .moveClipMask(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            maskID: rectangleMask.id,
            destinationIndex: 1
        )
    )
    let afterSet = try history.apply(
        .setClipMask(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            mask: replacementMask
        )
    )
    let afterRemove = try history.apply(
        .removeClipMask(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            maskID: ellipseMask.id
        )
    )

    return MaskCommandSequence(
        history: history,
        afterAddRectangle: afterAddRectangle,
        afterAddEllipse: afterAddEllipse,
        afterMove: afterMove,
        afterSet: afterSet,
        afterRemove: afterRemove
    )
}

private func applyAddMask(
    _ mask: ClipMask,
    fixture: EditFixture,
    history: inout EditHistory
) throws -> Project {
    try history.apply(
        .addClipMask(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            mask: mask
        )
    )
}

private func assertMaskCommandUndoRedo(
    sequence: inout MaskCommandSequence,
    fixture: EditFixture
) throws {
    XCTAssertEqual(sequence.history.undo(), sequence.afterSet)
    XCTAssertEqual(sequence.history.undo(), sequence.afterMove)
    XCTAssertEqual(sequence.history.undo(), sequence.afterAddEllipse)
    XCTAssertEqual(sequence.history.undo(), sequence.afterAddRectangle)
    XCTAssertEqual(sequence.history.undo(), fixture.project)
    XCTAssertEqual(try sequence.history.redo(), sequence.afterAddRectangle)
    XCTAssertEqual(try sequence.history.redo(), sequence.afterAddEllipse)
    XCTAssertEqual(try sequence.history.redo(), sequence.afterMove)
    XCTAssertEqual(try sequence.history.redo(), sequence.afterSet)
    XCTAssertEqual(try sequence.history.redo(), sequence.afterRemove)
}

private func makeRectangleMask(
    id: UUID,
    x: Int64,
    width: Int64,
    featherRadius: RationalValue = .zero,
    invert: Bool = false
) throws -> ClipMask {
    ClipMask(
        id: id,
        shape: .rectangle(
            ClipRectangleMask(
                x: RationalValue(x),
                y: .zero,
                width: RationalValue(width),
                height: RationalValue(10)
            )
        ),
        featherRadius: featherRadius,
        invert: invert
    )
}

private func makeEllipseMask(id: UUID) throws -> ClipMask {
    ClipMask(
        id: id,
        shape: .ellipse(
            ClipEllipseMask(
                centerX: RationalValue(5),
                centerY: RationalValue(5),
                radiusX: RationalValue(4),
                radiusY: RationalValue(3)
            )
        )
    )
}
