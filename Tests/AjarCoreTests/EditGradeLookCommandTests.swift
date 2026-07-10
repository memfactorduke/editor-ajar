// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-COL-007 undoable grade-copy and project-look command coverage.
final class EditGradeLookCommandTests: XCTestCase {
    func testFRCOL007CopyGradeAcrossTracksPreservesTargetNonColorOrderAndUndoRedo() throws {
        let fixture = try makeGradeCommandFixture(seed: 9_200)
        let sourceBefore = try gradeCommandClip(fixture.source, in: fixture.project)
        let targetBefore = try gradeCommandClip(fixture.target, in: fixture.project)
        let expectedNonColorIDs = targetBefore.effectStack.nodes
            .filter { !$0.kind.isColorGrade }
            .map(\.id)
        var history = EditHistory(project: fixture.project)

        let copied = try history.apply(
            .copyClipGrade(
                source: fixture.source,
                target: fixture.target,
                newNodeIDs: fixture.newNodeIDs
            )
        )
        let sourceAfter = try gradeCommandClip(fixture.source, in: copied)
        let targetAfter = try gradeCommandClip(fixture.target, in: copied)

        XCTAssertEqual(sourceAfter, sourceBefore)
        XCTAssertEqual(
            targetAfter.effectStack.grade.nodes.map(\.definition),
            sourceBefore.effectStack.grade.nodes.map(\.definition)
        )
        XCTAssertEqual(targetAfter.effectStack.grade.nodes.map(\.id), fixture.newNodeIDs)
        XCTAssertEqual(
            targetAfter.effectStack.nodes.filter { !$0.kind.isColorGrade }.map(\.id),
            expectedNonColorIDs
        )
        XCTAssertEqual(
            targetAfter.effectStack.nodes.map(\.kind),
            [.mosaic, .colorAdjust, .curves, .lut, .posterize, .invert, .sharpen, .glow]
        )
        XCTAssertEqual(targetAfter.effectStackAnimation.baseStack, targetAfter.effectStack)

        XCTAssertEqual(history.undo(), fixture.project)
        let redone = try XCTUnwrap(history.redo())
        XCTAssertEqual(redone, copied)
        XCTAssertEqual(
            try gradeCommandClip(fixture.target, in: redone).effectStack.grade.nodes.map(\.id),
            fixture.newNodeIDs
        )
    }

    func testFRCOL007CopyGradeIntoCompoundNestedClipIsUndoable() throws {
        let fixture = try makeNestedGradeCommandFixture(seed: 9_210)
        var history = EditHistory(project: fixture.project)

        let copied = try history.apply(
            .copyClipGrade(
                source: fixture.source,
                target: fixture.target,
                newNodeIDs: fixture.newNodeIDs
            )
        )
        let nestedTarget = try gradeCommandClip(fixture.target, in: copied)
        let compound = try gradeCommandClip(fixture.compound, in: copied)

        XCTAssertEqual(nestedTarget.effectStack.nodes.first?.kind, .gaussianBlur)
        XCTAssertEqual(nestedTarget.effectStack.grade.nodes.map(\.id), fixture.newNodeIDs)
        XCTAssertEqual(
            nestedTarget.effectStack.grade.nodes.map(\.definition),
            try gradeCommandClip(fixture.source, in: copied).effectStack.grade.nodes.map(
                \.definition)
        )
        XCTAssertEqual(compound.source, .sequence(id: fixture.target.sequenceID))
        XCTAssertTrue(copied.validate().isValid)
        XCTAssertEqual(history.undo(), fixture.project)
    }

    func testFRCOL007SaveApplyRenameDeleteLookAreUndoable() throws {
        let fixture = try makeGradeCommandFixture(seed: 9_220)
        let lookID = try editUUID(9_220_900)
        let appliedIDs = try (9_220_910...9_220_914).map(editUUID)
        var history = EditHistory(project: fixture.project)

        let afterSave = try history.apply(
            .saveLookFromClip(source: fixture.source, lookID: lookID, name: "Warm Film")
        )
        let savedLook = try XCTUnwrap(afterSave.looks.first)
        XCTAssertEqual(savedLook.id, lookID)
        XCTAssertEqual(savedLook.name, "Warm Film")
        XCTAssertEqual(
            savedLook.grade,
            try gradeCommandClip(fixture.source, in: fixture.project).effectStack.grade
        )

        let afterApply = try history.apply(
            .applyLookToClip(
                lookID: lookID,
                target: fixture.target,
                newNodeIDs: appliedIDs
            )
        )
        let appliedClip = try gradeCommandClip(fixture.target, in: afterApply)
        XCTAssertEqual(appliedClip.effectStack.grade.nodes.map(\.id), appliedIDs)
        XCTAssertEqual(
            appliedClip.effectStack.grade.nodes.map(\.definition),
            savedLook.grade.nodes.map(\.definition)
        )

        let afterRename = try history.apply(.renameLook(lookID: lookID, name: "Warm Film 2"))
        XCTAssertEqual(afterRename.looks.first?.name, "Warm Film 2")
        let afterDelete = try history.apply(.deleteLook(lookID: lookID))
        XCTAssertEqual(afterDelete.looks, [])

        XCTAssertEqual(history.undo(), afterRename)
        XCTAssertEqual(history.undo(), afterApply)
        XCTAssertEqual(history.undo(), afterSave)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), afterSave)
        XCTAssertEqual(try history.redo(), afterApply)
        XCTAssertEqual(try history.redo(), afterRename)
        XCTAssertEqual(try history.redo(), afterDelete)
    }

    func testFRCOL007GradeCommandsRejectNodeIDCountAndDuplicates() throws {
        let fixture = try makeGradeCommandFixture(seed: 9_230)
        let sourceGrade = try gradeCommandClip(fixture.source, in: fixture.project).effectStack
            .grade

        assertGradeInvalidEdit(
            .gradeNodeIDCountMismatch(expected: sourceGrade.nodes.count, actual: 1)
        ) {
            try apply(
                .copyClipGrade(
                    source: fixture.source,
                    target: fixture.target,
                    newNodeIDs: [fixture.newNodeIDs[0]]
                ),
                to: fixture.project
            )
        }
        var duplicateIDs = fixture.newNodeIDs
        duplicateIDs[1] = duplicateIDs[0]
        assertGradeInvalidEdit(.duplicateGradeNodeID(nodeID: duplicateIDs[0])) {
            try apply(
                .copyClipGrade(
                    source: fixture.source,
                    target: fixture.target,
                    newNodeIDs: duplicateIDs
                ),
                to: fixture.project
            )
        }
    }

    func testFRCOL007GradeCommandsRejectNonFreshNodeIDs() throws {
        let fixture = try makeGradeCommandFixture(seed: 9_230)
        let sourceGrade = try gradeCommandClip(fixture.source, in: fixture.project).effectStack
            .grade
        let sourceNodeID = try XCTUnwrap(sourceGrade.nodes.first?.id)
        var sourceCollidingIDs = fixture.newNodeIDs
        sourceCollidingIDs[0] = sourceNodeID
        assertGradeInvalidEdit(.gradeNodeIDNotFresh(nodeID: sourceNodeID)) {
            try apply(
                .copyClipGrade(
                    source: fixture.source,
                    target: fixture.target,
                    newNodeIDs: sourceCollidingIDs
                ),
                to: fixture.project
            )
        }
        let retainedTargetID = try XCTUnwrap(
            gradeCommandClip(fixture.target, in: fixture.project).effectStack.nodes
                .first(where: { !$0.kind.isColorGrade })?.id
        )
        var targetCollidingIDs = fixture.newNodeIDs
        targetCollidingIDs[0] = retainedTargetID
        assertGradeInvalidEdit(.gradeNodeIDNotFresh(nodeID: retainedTargetID)) {
            try apply(
                .copyClipGrade(
                    source: fixture.source,
                    target: fixture.target,
                    newNodeIDs: targetCollidingIDs
                ),
                to: fixture.project
            )
        }
        let removedTargetColorID = try XCTUnwrap(
            gradeCommandClip(fixture.target, in: fixture.project).effectStack.grade.nodes.first?.id
        )
        var removedColorCollidingIDs = fixture.newNodeIDs
        removedColorCollidingIDs[0] = removedTargetColorID
        assertGradeInvalidEdit(.gradeNodeIDNotFresh(nodeID: removedTargetColorID)) {
            try apply(
                .copyClipGrade(
                    source: fixture.source,
                    target: fixture.target,
                    newNodeIDs: removedColorCollidingIDs
                ),
                to: fixture.project
            )
        }
    }

    func testFRCOL007GradeCommandsReturnTypedSourceAndVideoErrors() throws {
        let fixture = try makeGradeCommandFixture(seed: 9_230)
        let withoutSourceGrade = try apply(
            .resetClipEffectStack(
                sequenceID: fixture.source.sequenceID,
                trackID: fixture.source.trackID,
                clipID: fixture.source.clipID
            ),
            to: fixture.project
        )
        assertGradeInvalidEdit(.gradeSourceHasNoGrade(clipID: fixture.source.clipID)) {
            try apply(
                .copyClipGrade(
                    source: fixture.source,
                    target: fixture.target,
                    newNodeIDs: fixture.newNodeIDs
                ),
                to: withoutSourceGrade
            )
        }

        let audioFixture = try makeAudioGradeCommandFixture(seed: 9_231)
        assertGradeInvalidEdit(
            .gradeRequiresVideoClip(clipID: audioFixture.audio.clipID, kind: .audio)
        ) {
            try apply(
                .copyClipGrade(
                    source: audioFixture.audio,
                    target: audioFixture.video,
                    newNodeIDs: [audioFixture.newNodeID]
                ),
                to: audioFixture.project
            )
        }
        assertGradeInvalidEdit(
            .gradeRequiresVideoClip(clipID: audioFixture.audio.clipID, kind: .audio)
        ) {
            try apply(
                .copyClipGrade(
                    source: audioFixture.video,
                    target: audioFixture.audio,
                    newNodeIDs: [audioFixture.newNodeID]
                ),
                to: audioFixture.project
            )
        }
    }

    func testFRCOL007LookCommandsReturnTypedNameIdentityAndLookupErrors() throws {
        let fixture = try makeGradeCommandFixture(seed: 9_240)
        let lookID = try editUUID(9_240_900)

        assertGradeInvalidEdit(.blankLookName) {
            try apply(
                .saveLookFromClip(source: fixture.source, lookID: lookID, name: " \n "),
                to: fixture.project
            )
        }
        let withLook = try apply(
            .saveLookFromClip(source: fixture.source, lookID: lookID, name: "Warm Film"),
            to: fixture.project
        )
        let targetColorID = try XCTUnwrap(
            gradeCommandClip(fixture.target, in: withLook).effectStack.grade.nodes.first?.id
        )
        var applyCollidingIDs = fixture.newNodeIDs
        applyCollidingIDs[0] = targetColorID
        assertGradeInvalidEdit(.gradeNodeIDNotFresh(nodeID: targetColorID)) {
            try apply(
                .applyLookToClip(
                    lookID: lookID,
                    target: fixture.target,
                    newNodeIDs: applyCollidingIDs
                ),
                to: withLook
            )
        }
        assertGradeInvalidEdit(.duplicateLookName(" warm film ")) {
            try apply(
                .saveLookFromClip(
                    source: fixture.source,
                    lookID: try editUUID(9_240_901),
                    name: " warm film "
                ),
                to: withLook
            )
        }
        assertGradeInvalidEdit(.duplicateLookID(lookID)) {
            try apply(
                .saveLookFromClip(source: fixture.source, lookID: lookID, name: "Other"),
                to: withLook
            )
        }

        let missingID = try editUUID(9_240_999)
        assertGradeInvalidEdit(.lookNotFound(missingID)) {
            try apply(
                .applyLookToClip(
                    lookID: missingID,
                    target: fixture.target,
                    newNodeIDs: fixture.newNodeIDs
                ),
                to: withLook
            )
        }
        assertGradeInvalidEdit(.lookNotFound(missingID)) {
            try apply(.renameLook(lookID: missingID, name: "Missing"), to: withLook)
        }
        assertGradeInvalidEdit(.lookNotFound(missingID)) {
            try apply(.deleteLook(lookID: missingID), to: withLook)
        }
    }
}
