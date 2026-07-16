// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class LinkedTopologyEditRefusalTests: XCTestCase {
    func testDirectInsertRefusesShiftingOnlyOneLaterLinkedMemberAtomically() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_420)
        let project = try movedLinkedFixtureProject(fixture, startFrame: 20)
        let inserted = try makeEditClip(
            id: editUUID(7_420_101),
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 5
        )
        let command = EditCommand.insertClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: inserted
        )

        try assertPartialGroupRefusal(
            command,
            project: project,
            fixture: fixture
        )
    }

    func testDirectInsertRefusesStraddlingLinkedMemberWithSpecificTypedError() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_421)
        let cut = try editTime(5)
        let inserted = try makeEditClip(
            id: editUUID(7_421_101),
            mediaID: fixture.mediaID,
            startFrame: 5,
            durationFrames: 2
        )

        XCTAssertThrowsError(
            try apply(
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: inserted
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .insertWouldSplitLinkedClip(
                        clipID: fixture.videoClipID,
                        linkGroupID: fixture.linkGroupID,
                        atTime: cut
                    )
                )
            )
        }
    }

    func testDirectOverwriteRefusesRemovingOnlyOneLinkedMemberAtomically() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_422)
        let replacement = try makeEditClip(
            id: editUUID(7_422_101),
            mediaID: fixture.mediaID,
            startFrame: 2,
            durationFrames: 5
        )

        try assertPartialGroupRefusal(
            .overwriteClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: replacement
            ),
            project: fixture.project,
            fixture: fixture
        )
    }

    func testDirectBladeRefusesSplittingOnlyOneLinkedMemberAtomically() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_423)

        try assertPartialGroupRefusal(
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                atTime: try editTime(5),
                rightClipID: try editUUID(7_423_101)
            ),
            project: fixture.project,
            fixture: fixture
        )
    }

    func testLinkedPlacementRefusesWhenPartnerTrackIsLocked() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_424)
        let moved = try movedLinkedFixtureProject(fixture, startFrame: 20)
        let locked = try apply(
            .setTrackState(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                state: TrackStatePatch(locked: true)
            ),
            to: moved
        )
        let inserted = try makeEditClip(
            id: editUUID(7_424_101),
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 5
        )
        var history = EditHistory(project: locked)

        XCTAssertThrowsError(
            try history.apply(
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: inserted
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .linkedEditTargetsLockedTrack(
                        sequenceID: fixture.sequenceID,
                        linkGroupID: fixture.linkGroupID,
                        trackID: fixture.audioTrackID
                    )
                )
            )
        }
        XCTAssertEqual(history.currentProject, locked)
        XCTAssertEqual(history.undoCount, 0)
    }

    func testGroupedInsertRefusesOffTargetPartnerTrackAtomically() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_425)
        let moved = try movedLinkedFixtureProject(fixture, startFrame: 20)
        let offTargetTrackID = try editUUID(7_425_100)
        let project = try apply(
            .addTrack(
                sequenceID: fixture.sequenceID,
                track: Track(id: offTargetTrackID, kind: .audio, items: [])
            ),
            to: moved
        )
        let video = try makeEditClip(
            id: editUUID(7_425_101),
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 5
        )
        let audio = try makeEditClip(
            id: editUUID(7_425_102),
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 5,
            kind: .audio
        )
        let transaction = EditCommand.transaction([
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: video
            ),
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: offTargetTrackID,
                clip: audio
            ),
            .linkClips(
                sequenceID: fixture.sequenceID,
                linkGroupID: try editUUID(7_425_103),
                clips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: video.id),
                    ClipReference(trackID: offTargetTrackID, clipID: audio.id)
                ]
            )
        ])

        try assertPartialGroupRefusal(
            transaction,
            project: project,
            fixture: fixture
        )
    }

    func testDirectLiftRefusesRemovingOnlyOneLinkedMemberAtomically() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_430)

        try assertPartialGroupRefusal(
            .liftClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID
            ),
            project: fixture.project,
            fixture: fixture
        )
    }

    func testDirectRippleDeleteRefusesRemovingOnlyOneLinkedMemberAtomically() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_431)

        try assertPartialGroupRefusal(
            .rippleDeleteClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID
            ),
            project: fixture.project,
            fixture: fixture
        )
    }

    func testDirectLiftRefusesLockedLinkedPartnerWithoutHistoryMutation() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_432)
        let locked = try apply(
            .setTrackState(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                state: TrackStatePatch(locked: true)
            ),
            to: fixture.project
        )
        var history = EditHistory(project: locked)

        XCTAssertThrowsError(
            try history.apply(
                .liftClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.videoClipID
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .linkedEditTargetsLockedTrack(
                        sequenceID: fixture.sequenceID,
                        linkGroupID: fixture.linkGroupID,
                        trackID: fixture.audioTrackID
                    )
                )
            )
        }
        XCTAssertEqual(history.currentProject, locked)
        XCTAssertEqual(history.undoCount, 0)
    }

    func testDirectInsertRefusesNewOneMemberLinkGroupAtomically() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_433)
        let newGroupID = try editUUID(7_433_101)
        let inserted = try makeEditClip(
            id: editUUID(7_433_102),
            mediaID: fixture.mediaID,
            startFrame: 20,
            durationFrames: 5,
            linkGroupID: newGroupID
        )

        try assertNewGroupRefusal(
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: inserted
            ),
            project: fixture.project,
            expected: .linkRequiresAtLeastTwoClips(linkGroupID: newGroupID)
        )
    }

    func testGroupedInsertRefusesNewVideoOnlyLinkGroupAtomically() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_434)
        let newGroupID = try editUUID(7_434_101)
        let first = try makeEditClip(
            id: editUUID(7_434_102),
            mediaID: fixture.mediaID,
            startFrame: 20,
            durationFrames: 5,
            linkGroupID: newGroupID
        )
        let second = try makeEditClip(
            id: editUUID(7_434_103),
            mediaID: fixture.mediaID,
            startFrame: 30,
            durationFrames: 5,
            linkGroupID: newGroupID
        )

        try assertNewGroupRefusal(
            .transaction([
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: first
                ),
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: second
                )
            ]),
            project: fixture.project,
            expected: .linkRequiresVideoAndAudio(linkGroupID: newGroupID)
        )
    }
}

private func assertPartialGroupRefusal(
    _ command: EditCommand,
    project: Project,
    fixture: LinkedEditFixture,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    var history = EditHistory(project: project)
    XCTAssertThrowsError(
        try history.apply(command),
        file: file,
        line: line
    ) { error in
        XCTAssertEqual(
            error as? EditReducerError,
            .invalidEdit(
                .linkedEditWouldDesynchronizeGroup(
                    sequenceID: fixture.sequenceID,
                    linkGroupID: fixture.linkGroupID
                )
            ),
            file: file,
            line: line
        )
    }
    XCTAssertEqual(history.currentProject, project, file: file, line: line)
    XCTAssertEqual(history.undoCount, 0, file: file, line: line)
}

private func assertNewGroupRefusal(
    _ command: EditCommand,
    project: Project,
    expected: EditCommandValidationError,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    var history = EditHistory(project: project)
    XCTAssertThrowsError(
        try history.apply(command),
        file: file,
        line: line
    ) { error in
        XCTAssertEqual(
            error as? EditReducerError,
            .invalidEdit(expected),
            file: file,
            line: line
        )
    }
    XCTAssertEqual(history.currentProject, project, file: file, line: line)
    XCTAssertEqual(history.undoCount, 0, file: file, line: line)
}

func movedLinkedFixtureProject(
    _ fixture: LinkedEditFixture,
    startFrame: Int64
) throws -> Project {
    try apply(
        .moveClip(
            sequenceID: fixture.sequenceID,
            sourceTrackID: fixture.videoTrackID,
            clipID: fixture.videoClipID,
            destinationTrackID: fixture.videoTrackID,
            timelineRange: editRange(startFrame: startFrame, durationFrames: 10)
        ),
        to: fixture.project
    )
}
