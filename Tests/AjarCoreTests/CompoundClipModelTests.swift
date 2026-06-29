// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class CompoundClipModelTests: XCTestCase {
    func testFRTL013CompoundClipResolvesSequenceDurationAndTimebaseAtQueryTime() throws {
        let fixture = try makeCompoundClipFixture(seed: 122)
        let compoundClip = try requiredCompoundClip(in: fixture.project, fixture: fixture)

        XCTAssertEqual(
            try compoundClip.resolvedSourceDuration(in: fixture.project),
            try editTime(12)
        )
        XCTAssertEqual(
            try compoundClip.resolvedSourceTimebase(in: fixture.project),
            try FrameRate(frames: 30)
        )
        let editedProject = try replacingInnerSequenceDuration(
            in: fixture.project,
            fixture: fixture,
            durationFrames: 18
        )
        XCTAssertEqual(
            try compoundClip.resolvedSourceDuration(in: editedProject),
            try editTime(18)
        )
    }

    func testFRTL013CompoundCyclesAreRejectedByProjectValidation() throws {
        let selfCycle = try makeSelfReferencingCompoundProject(seed: 130)
        XCTAssertTrue(
            compoundValidationErrors(from: selfCycle.project).contains(
                .compoundSequenceCycle(
                    sequenceID: selfCycle.sequenceID,
                    trackID: selfCycle.trackID,
                    clipID: selfCycle.clipID,
                    targetID: selfCycle.sequenceID
                )
            )
        )
        let transitiveCycle = try makeTransitiveCompoundCycleProject(seed: 131)
        let errors = compoundValidationErrors(from: transitiveCycle.project)
        XCTAssertTrue(
            errors.contains(
                .compoundSequenceCycle(
                    sequenceID: transitiveCycle.firstSequenceID,
                    trackID: transitiveCycle.firstTrackID,
                    clipID: transitiveCycle.firstClipID,
                    targetID: transitiveCycle.secondSequenceID
                )
            )
        )
        XCTAssertTrue(
            errors.contains(
                .compoundSequenceCycle(
                    sequenceID: transitiveCycle.secondSequenceID,
                    trackID: transitiveCycle.secondTrackID,
                    clipID: transitiveCycle.secondClipID,
                    targetID: transitiveCycle.firstSequenceID
                )
            )
        )
    }

    func testFRTL013ThreeNodeCompoundCycleIsRejectedByProjectValidation() throws {
        let threeNodeCycle = try makeThreeNodeCompoundCycleProject(seed: 136)
        let errors = compoundValidationErrors(from: threeNodeCycle.project)
        XCTAssertTrue(
            errors.contains(
                .compoundSequenceCycle(
                    sequenceID: threeNodeCycle.firstSequenceID,
                    trackID: threeNodeCycle.firstTrackID,
                    clipID: threeNodeCycle.firstClipID,
                    targetID: threeNodeCycle.secondSequenceID
                )
            )
        )
        XCTAssertTrue(
            errors.contains(
                .compoundSequenceCycle(
                    sequenceID: threeNodeCycle.secondSequenceID,
                    trackID: threeNodeCycle.secondTrackID,
                    clipID: threeNodeCycle.secondClipID,
                    targetID: threeNodeCycle.thirdSequenceID
                )
            )
        )
        XCTAssertTrue(
            errors.contains(
                .compoundSequenceCycle(
                    sequenceID: threeNodeCycle.thirdSequenceID,
                    trackID: threeNodeCycle.thirdTrackID,
                    clipID: threeNodeCycle.thirdClipID,
                    targetID: threeNodeCycle.firstSequenceID
                )
            )
        )
    }

    func testFRTL013CompoundCycleDecodeReturnsTypedValidationError() throws {
        let cycle = try makeSelfReferencingCompoundProject(seed: 132)
        let projectDocument = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: cycle.project.settings,
            mediaPool: [],
            sequences: cycle.project.sequences
        )
        let manifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            media: []
        )
        XCTAssertThrowsError(
            try AjarProjectCodec.decode(
                projectJSON: try compoundTestEncoder().encode(projectDocument),
                mediaJSON: try compoundTestEncoder().encode(manifest)
            )
        ) { error in
            guard case .validationFailed(let errors) = error as? AjarProjectCodecError else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(
                errors.contains(
                    .compoundSequenceCycle(
                        sequenceID: cycle.sequenceID,
                        trackID: cycle.trackID,
                        clipID: cycle.clipID,
                        targetID: cycle.sequenceID
                    )
                )
            )
        }
    }

    func testFRTL013TransitiveCompoundCycleDecodeReturnsTypedValidationError() throws {
        let cycle = try makeTransitiveCompoundCycleProject(seed: 137)
        let projectDocument = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: cycle.project.settings,
            mediaPool: [],
            sequences: cycle.project.sequences
        )
        let manifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            media: []
        )
        XCTAssertThrowsError(
            try AjarProjectCodec.decode(
                projectJSON: try compoundTestEncoder().encode(projectDocument),
                mediaJSON: try compoundTestEncoder().encode(manifest)
            )
        ) { error in
            guard case .validationFailed(let errors) = error as? AjarProjectCodecError else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(
                errors.contains(
                    .compoundSequenceCycle(
                        sequenceID: cycle.firstSequenceID,
                        trackID: cycle.firstTrackID,
                        clipID: cycle.firstClipID,
                        targetID: cycle.secondSequenceID
                    )
                )
            )
        }
    }

    func testFRTL013CompoundClipRoundTripsThroughAjarProjectCodec() throws {
        let fixture = try makeCompoundClipFixture(seed: 133)
        let package = try AjarProjectCodec.encode(fixture.project)
        let loaded = try compoundEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        XCTAssertEqual(loaded, fixture.project)
        XCTAssertEqual(
            try requiredCompoundClip(in: loaded, fixture: fixture).source,
            .sequence(id: fixture.innerSequenceID)
        )
    }

    func testFRTL013LegacyMediaOnlyProjectStillDecodesThroughProjectCodec() throws {
        let fixture = try makeEditFixture(seed: 134)
        let legacyDocument = Project(
            schemaVersion: 1,
            settings: fixture.project.settings,
            mediaPool: [],
            sequences: fixture.project.sequences
        )
        let legacyManifest = AjarMediaManifest(schemaVersion: 1, media: fixture.project.mediaPool)
        let loaded = try compoundEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: try compoundTestEncoder().encode(legacyDocument),
                mediaJSON: try compoundTestEncoder().encode(legacyManifest)
            )
        )
        XCTAssertEqual(loaded.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(loaded.mediaPool, fixture.project.mediaPool)
        XCTAssertEqual(loaded.sequences, fixture.project.sequences)
    }

    func testFRTL013InsertCompoundClipRoutesThroughUndoableHistory() throws {
        let fixture = try makeCompoundInsertFixture(seed: 135)
        var history = EditHistory(project: fixture.project)
        let edited = try history.apply(
            .insertCompoundClip(
                sequenceID: fixture.outerSequenceID,
                trackID: fixture.outerTrackID,
                clipID: fixture.compoundClipID,
                targetSequenceID: fixture.innerSequenceID,
                timelineStart: try editTime(5),
                kind: .video,
                name: "FR-TL-013 Compound"
            )
        )
        let inserted = try requiredClip(
            fixture.compoundClipID,
            trackID: fixture.outerTrackID,
            in: edited,
            sequenceID: fixture.outerSequenceID
        )
        XCTAssertEqual(inserted.source, .sequence(id: fixture.innerSequenceID))
        try assertRange(inserted.sourceRange, startFrame: 0, durationFrames: 12)
        try assertRange(inserted.timelineRange, startFrame: 5, durationFrames: 12)
        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRTL013InsertCompoundClipRejectsCycleBeforeHistoryCommit() throws {
        let fixture = try makeCompoundInsertCycleFixture(seed: 138)
        XCTAssertEqual(fixture.project.validate(), .valid)
        var history = EditHistory(project: fixture.project)

        XCTAssertThrowsError(
            try history.apply(
                .insertCompoundClip(
                    sequenceID: fixture.targetSequenceID,
                    trackID: fixture.targetTrackID,
                    clipID: fixture.insertedClipID,
                    targetSequenceID: fixture.sourceSequenceID,
                    timelineStart: .zero,
                    kind: .video,
                    name: "FR-TL-013 Cycle Guard"
                )
            )
        ) { error in
            guard case .validationFailed(let errors) = error as? EditReducerError else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(
                errors.contains(
                    .compoundSequenceCycle(
                        sequenceID: fixture.targetSequenceID,
                        trackID: fixture.targetTrackID,
                        clipID: fixture.insertedClipID,
                        targetID: fixture.sourceSequenceID
                    )
                )
            )
        }
        XCTAssertEqual(history.currentProject, fixture.project)
        XCTAssertEqual(history.undoCount, 0)
        XCTAssertEqual(history.redoCount, 0)
    }
}
