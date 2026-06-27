// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable file_length

import Foundation
import XCTest

@testable import AjarCore

final class EditCommandUndoTests: XCTestCase {
    func testFRTL012NFRSTAB007UndoDoIdentityForEveryCommandKindOverGeneratedProjects() throws {
        for seed in 0..<12 {
            for commandCase in try makeValidCommandCases(seed: seed) {
                var history = EditHistory(project: commandCase.project)
                let before = history.currentProject
                let after = try history.apply(commandCase.command)

                XCTAssertEqual(after.validate(), .valid)
                XCTAssertEqual(history.undo(), before)
                XCTAssertEqual(history.currentProject, before)
                XCTAssertEqual(try history.redo(), after)
                XCTAssertEqual(history.currentProject, after)
            }
        }
    }

    func testFRTL012RedoAfterUndoReproducesExactPostCommandValue() throws {
        let fixture = try makeEditFixture(seed: 100)
        let command = EditCommand.renameSequence(
            sequenceID: fixture.sequenceID,
            name: "Renamed sequence"
        )
        var history = EditHistory(project: fixture.project)
        let after = try history.apply(command)

        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), after)
        XCTAssertEqual(history.currentProject, after)
    }

    func testFRTL012RedoHistoryClearsAfterNewCommand() throws {
        let fixture = try makeEditFixture(seed: 110)
        var history = EditHistory(project: fixture.project)
        try history.apply(.renameSequence(sequenceID: fixture.sequenceID, name: "First"))

        XCTAssertNotNil(history.undo())
        XCTAssertEqual(history.redoCount, 1)

        try history.apply(.renameSequence(sequenceID: fixture.sequenceID, name: "Second"))

        XCTAssertEqual(history.redoCount, 0)
        XCTAssertNil(try history.redo())
    }

    func testNFRSTAB007UnboundedUndoDepthWithLongCommandSequence() throws {
        let fixture = try makeEditFixture(seed: 120)
        var history = EditHistory(project: fixture.project)
        var expectedFinalProject = fixture.project

        for index in 0..<250 {
            let command = EditCommand.renameSequence(
                sequenceID: fixture.sequenceID,
                name: "Edit \(index)"
            )
            expectedFinalProject = try apply(command, to: expectedFinalProject)
            try history.apply(command)
        }

        XCTAssertEqual(history.undoCount, 250)
        XCTAssertEqual(history.currentProject, expectedFinalProject)

        for _ in 0..<250 {
            XCTAssertNotNil(history.undo())
        }

        XCTAssertEqual(history.currentProject, fixture.project)
        XCTAssertEqual(history.redoCount, 250)

        for _ in 0..<250 {
            XCTAssertNotNil(try history.redo())
        }

        XCTAssertEqual(history.currentProject, expectedFinalProject)
    }
}

final class EditReducerInvariantTests: XCTestCase {
    func testADR0008EditReducerIsDeterministicForSameProjectAndCommand() throws {
        let fixture = try makeEditFixture(seed: 200)
        let command = EditCommand.moveClip(
            sequenceID: fixture.sequenceID,
            sourceTrackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            destinationTrackID: fixture.videoTrackID,
            timelineRange: try editRange(startFrame: 16, durationFrames: 8)
        )

        let first = try apply(command, to: fixture.project)
        let second = try apply(command, to: fixture.project)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.validate(), .valid)
    }

    func testADR0008ReducerPreservesInvariantsOrReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 210)
        let validCommand = EditCommand.addClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: try makeEditClip(
                id: try editUUID(211_000),
                mediaID: fixture.mediaID,
                startFrame: 20
            )
        )
        let overlappingCommand = EditCommand.addClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: try makeEditClip(
                id: try editUUID(211_001),
                mediaID: fixture.mediaID,
                startFrame: 5
            )
        )
        let wrongKindCommand = EditCommand.addClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: try makeEditClip(
                id: try editUUID(211_002),
                mediaID: fixture.mediaID,
                startFrame: 20,
                kind: .audio
            )
        )

        try assertValidOrTypedError(validCommand, project: fixture.project)
        try assertValidOrTypedError(overlappingCommand, project: fixture.project)
        try assertValidOrTypedError(wrongKindCommand, project: fixture.project)
    }

    func testFRTL012ReducerReturnsTypedLookupErrorsWithoutCrashing() throws {
        let fixture = try makeEditFixture(seed: 220)
        let missingSequenceID = try editUUID(220_900)
        let missingTrackID = try editUUID(220_901)
        let missingClipID = try editUUID(220_902)

        XCTAssertThrowsError(
            try apply(
                .renameSequence(sequenceID: missingSequenceID, name: "Missing"),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(error as? EditReducerError, .sequenceNotFound(missingSequenceID))
        }

        XCTAssertThrowsError(
            try apply(
                .removeTrack(sequenceID: fixture.sequenceID, trackID: missingTrackID),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .trackNotFound(sequenceID: fixture.sequenceID, trackID: missingTrackID)
            )
        }

        XCTAssertThrowsError(
            try apply(
                .removeClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: missingClipID
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .clipNotFound(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: missingClipID
                )
            )
        }
    }

}

struct EditCommandCase {
    let project: Project
    let command: EditCommand
}

private func assertValidOrTypedError(_ command: EditCommand, project: Project) throws {
    do {
        let edited = try apply(command, to: project)
        XCTAssertEqual(edited.validate(), .valid)
    } catch let error as EditReducerError {
        guard case .validationFailed(let errors) = error else {
            XCTFail("Expected validationFailed, got \(error)")
            return
        }
        XCTAssertFalse(errors.isEmpty)
    }
}

private func makeValidCommandCases(seed: Int) throws -> [EditCommandCase] {
    let fixture = try makeEditFixture(seed: seed)
    let addTrackID = try editUUID(seed * 1_000 + 20)
    let addClipID = try editUUID(seed * 1_000 + 21)
    let addClip = try makeEditClip(id: addClipID, mediaID: fixture.mediaID, startFrame: 20)

    return try makeClipCommandCases(fixture: fixture, addClip: addClip, seed: seed)
        + makeLinkedClipCommandCases(seed: seed)
        + (try makeTrackCommandCases(fixture: fixture, addTrackID: addTrackID))
        + makeMarkerCommandCases(fixture: fixture, seed: seed)
        + makeProjectCommandCases(fixture: fixture, seed: seed)
}

private func makeClipCommandCases(
    fixture: EditFixture,
    addClip: Clip,
    seed: Int
) throws -> [EditCommandCase] {
    try makeCoreClipCommandCases(fixture: fixture, seed: seed)
        + makeTransformCommandCases(fixture: fixture)
        + makeLegacyClipCommandCases(fixture: fixture, addClip: addClip)
}

private func makeCoreClipCommandCases(
    fixture: EditFixture,
    seed: Int
) throws -> [EditCommandCase] {
    try makePlacementClipCommandCases(fixture: fixture, seed: seed)
        + makeReplaceAndThreePointCommandCases(fixture: fixture, seed: seed)
        + makeTrimClipCommandCases(fixture: fixture, seed: seed)
}

private func makePlacementClipCommandCases(
    fixture: EditFixture,
    seed: Int
) throws -> [EditCommandCase] {
    var cases: [EditCommandCase] = []
    let insertClip = try makeEditClip(
        id: try editUUID(seed * 1_000 + 22),
        mediaID: fixture.mediaID,
        startFrame: 10,
        durationFrames: 4
    )
    let overwriteClip = try makeEditClip(
        id: try editUUID(seed * 1_000 + 23),
        mediaID: fixture.mediaID,
        startFrame: 0,
        durationFrames: 4
    )
    let appendClip = try makeEditClip(
        id: try editUUID(seed * 1_000 + 24),
        mediaID: fixture.mediaID,
        startFrame: 100,
        durationFrames: 4
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: insertClip
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .overwriteClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: overwriteClip
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .appendClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: appendClip
            )
        )
    )
    return cases
}

private func makeReplaceAndThreePointCommandCases(
    fixture: EditFixture,
    seed: Int
) throws -> [EditCommandCase] {
    let threePointSourceRange = try editRange(startFrame: 2, durationFrames: 4)
    return try [
        EditCommandCase(
            project: fixture.project,
            command: .replaceClipSource(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                source: .media(id: fixture.mediaID),
                sourceRange: try editRange(startFrame: 1, durationFrames: 4)
            )
        ),
        makeThreePointCommandCase(
            fixture: fixture,
            seed: seed,
            sourceRange: threePointSourceRange,
            timelineFrame: 10,
            mode: .insert
        ),
        makeThreePointCommandCase(
            fixture: fixture,
            seed: seed + 1,
            sourceRange: threePointSourceRange,
            timelineFrame: 0,
            mode: .overwrite
        )
    ]
}

private func makeLegacyClipCommandCases(
    fixture: EditFixture,
    addClip: Clip
) throws -> [EditCommandCase] {
    var cases: [EditCommandCase] = []
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .addClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: addClip
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .removeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .moveClip(
                sequenceID: fixture.sequenceID,
                sourceTrackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                destinationTrackID: fixture.videoTrackID,
                timelineRange: try editRange(startFrame: 12, durationFrames: 6)
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .trimClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                sourceRange: try editRange(startFrame: 2, durationFrames: 5),
                timelineRange: try editRange(startFrame: 0, durationFrames: 5)
            )
        )
    )
    return cases
}

private func makeTransformCommandCases(
    fixture: EditFixture
) throws -> [EditCommandCase] {
    let transform = try makeNonIdentityClipTransform()
    return [
        EditCommandCase(
            project: fixture.project,
            command: .setClipTransform(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                transform: transform
            )
        )
    ] + (try makeTransformKeyframeCommandCases(fixture: fixture))
        + (try makeLumaKeyCommandCases(fixture: fixture))
        + (try makeColorCorrectionCommandCases(fixture: fixture))
        + (try makeMaskCommandCases(fixture: fixture))
}

private func makeLumaKeyCommandCases(
    fixture: EditFixture
) throws -> [EditCommandCase] {
    let settings = ClipLumaKeySettings(
        enabled: true,
        lowThreshold: try RationalValue(numerator: 1, denominator: 5),
        highThreshold: try RationalValue(numerator: 4, denominator: 5),
        softness: try RationalValue(numerator: 1, denominator: 10),
        invert: true
    )
    let lumaKeyProject = try apply(
        .setClipLumaKey(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            settings: settings
        ),
        to: fixture.project
    )

    return [
        EditCommandCase(
            project: fixture.project,
            command: .setClipLumaKey(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                settings: settings
            )
        ),
        EditCommandCase(
            project: lumaKeyProject,
            command: .clearClipLumaKey(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            )
        )
    ]
}

private func makeColorCorrectionCommandCases(
    fixture: EditFixture
) throws -> [EditCommandCase] {
    let correction = ClipColorCorrection(
        exposure: try RationalValue(numerator: 1, denominator: 2),
        saturation: try RationalValue(numerator: 3, denominator: 2),
        temperature: try RationalValue(numerator: 1, denominator: 5)
    )
    let correctedProject = try apply(
        .setClipColorCorrection(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            correction: correction
        ),
        to: fixture.project
    )

    return [
        EditCommandCase(
            project: fixture.project,
            command: .setClipColorCorrection(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                correction: correction
            )
        ),
        EditCommandCase(
            project: correctedProject,
            command: .clearClipColorCorrection(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            )
        )
    ]
}

private func makeMaskCommandCases(
    fixture: EditFixture
) throws -> [EditCommandCase] {
    let context = try makeUndoMaskCommandContext(fixture: fixture)

    return [
        EditCommandCase(
            project: fixture.project,
            command: .addClipMask(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                mask: context.firstMask
            )
        ),
        EditCommandCase(
            project: context.projectWithFirstMask,
            command: .setClipMask(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                mask: context.replacementMask
            )
        ),
        EditCommandCase(
            project: context.projectWithTwoMasks,
            command: .moveClipMask(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                maskID: context.firstMask.id,
                destinationIndex: 1
            )
        ),
        EditCommandCase(
            project: context.projectWithTwoMasks,
            command: .removeClipMask(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                maskID: context.secondMask.id
            )
        )
    ]
}

private struct UndoMaskCommandContext {
    let firstMask: ClipMask
    let secondMask: ClipMask
    let replacementMask: ClipMask
    let projectWithFirstMask: Project
    let projectWithTwoMasks: Project
}

private func makeUndoMaskCommandContext(
    fixture: EditFixture
) throws -> UndoMaskCommandContext {
    let firstMask = makeUndoRectangleMask(id: try editUUID(910_100), x: 0, width: 10)
    let secondMask = makeUndoRectangleMask(id: try editUUID(910_101), x: 2, width: 6)
    let replacementMask = makeUndoRectangleMask(
        id: firstMask.id,
        x: 1,
        width: 8,
        invert: true
    )
    let projectWithFirstMask = try addingUndoMask(firstMask, to: fixture.project, fixture: fixture)
    let projectWithTwoMasks = try addingUndoMask(
        secondMask,
        to: projectWithFirstMask,
        fixture: fixture
    )

    return UndoMaskCommandContext(
        firstMask: firstMask,
        secondMask: secondMask,
        replacementMask: replacementMask,
        projectWithFirstMask: projectWithFirstMask,
        projectWithTwoMasks: projectWithTwoMasks
    )
}

private func addingUndoMask(
    _ mask: ClipMask,
    to project: Project,
    fixture: EditFixture
) throws -> Project {
    try apply(
        .addClipMask(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            mask: mask
        ),
        to: project
    )
}

private func makeTransformKeyframeCommandCases(
    fixture: EditFixture
) throws -> [EditCommandCase] {
    let keyframe = ClipTransformKeyframe(
        time: try editTime(2),
        value: .opacity(try RationalValue(numerator: 1, denominator: 2)),
        interpolation: .linear
    )
    let movedKeyframe = ClipTransformKeyframe(
        time: try editTime(4),
        value: .opacity(try RationalValue(numerator: 1, denominator: 4)),
        interpolation: .easeInOut
    )
    let projectWithKeyframe = try apply(
        .addClipTransformKeyframe(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            parameter: .opacity,
            keyframe: keyframe
        ),
        to: fixture.project
    )

    return [
        EditCommandCase(
            project: fixture.project,
            command: .addClipTransformKeyframe(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                parameter: .opacity,
                keyframe: keyframe
            )
        ),
        EditCommandCase(
            project: projectWithKeyframe,
            command: .moveClipTransformKeyframe(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                parameter: .opacity,
                fromTime: try editTime(2),
                keyframe: movedKeyframe
            )
        ),
        EditCommandCase(
            project: projectWithKeyframe,
            command: .deleteClipTransformKeyframe(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                parameter: .opacity,
                time: try editTime(2)
            )
        )
    ]
}

private func makeThreePointCommandCase(
    fixture: EditFixture,
    seed: Int,
    sourceRange: TimeRange,
    timelineFrame: Int64,
    mode: ThreePointEditMode
) throws -> EditCommandCase {
    EditCommandCase(
        project: fixture.project,
        command: .threePointEdit(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: try editUUID(seed * 1_000 + 25),
            source: .media(id: fixture.mediaID),
            sourceRange: sourceRange,
            timelineStart: try editTime(timelineFrame),
            kind: .video,
            name: "Three-point \(mode.rawValue) \(seed)",
            mode: mode
        )
    )
}

private func makeTrackCommandCases(
    fixture: EditFixture,
    addTrackID: UUID
) throws -> [EditCommandCase] {
    var cases: [EditCommandCase] = []
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .addTrack(
                sequenceID: fixture.sequenceID,
                track: Track(id: addTrackID, kind: .video, items: [])
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .removeTrack(sequenceID: fixture.sequenceID, trackID: fixture.audioTrackID)
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .setTrackState(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                state: TrackStatePatch(enabled: false, locked: true, hidden: true)
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .setTrackState(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                state: TrackStatePatch(locked: true, muted: true, solo: true)
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .setTrackCompositing(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                compositing: TrackCompositingPatch(
                    opacity: .constant(try RationalValue(numerator: 3, denominator: 4)),
                    blendMode: .softLight
                )
            )
        )
    )
    return cases
}

private func makeProjectCommandCases(
    fixture: EditFixture,
    seed: Int
) throws -> [EditCommandCase] {
    let addedSequence = try makeEmptyEditSequence(
        id: try editUUID(seed * 1_000 + 50),
        name: "Generated added sequence \(seed)"
    )
    let removedSequence = try makeEmptyEditSequence(
        id: try editUUID(seed * 1_000 + 51),
        name: "Generated removed sequence \(seed)"
    )
    let duplicatedSequence = try makeEmptyEditSequence(
        id: try editUUID(seed * 1_000 + 52),
        name: "Generated duplicated sequence \(seed)"
    )
    let removeSequenceProject = Project(
        schemaVersion: fixture.project.schemaVersion,
        settings: fixture.project.settings,
        mediaPool: fixture.project.mediaPool,
        sequences: fixture.project.sequences + [removedSequence]
    )
    let settings = ProjectSettings(
        frameRate: try FrameRate(frames: 30),
        resolution: PixelDimensions(width: 1_280, height: 720),
        colorSpace: .sRGB,
        audioSampleRate: 44_100
    )

    var cases: [EditCommandCase] = []
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .addSequence(addedSequence)
        )
    )
    cases.append(
        EditCommandCase(
            project: removeSequenceProject,
            command: .removeSequence(sequenceID: removedSequence.id)
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .duplicateSequence(
                sourceSequenceID: fixture.sequenceID,
                duplicate: duplicatedSequence
            )
        )
    )
    cases.append(
        EditCommandCase(
            project: fixture.project,
            command: .renameSequence(
                sequenceID: fixture.sequenceID,
                name: "Generated \(seed)"
            )
        )
    )
    cases.append(
        EditCommandCase(project: fixture.project, command: .setProjectSettings(settings))
    )
    return cases
}

private func makeUndoRectangleMask(
    id: UUID,
    x: Int64,
    width: Int64,
    invert: Bool = false
) -> ClipMask {
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
        invert: invert
    )
}
