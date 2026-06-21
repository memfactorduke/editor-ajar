// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditReducerLinkedClipTests: XCTestCase {
    func testFRTL009LinkAndUnlinkCommandsAreUndoableAndLeaveClipsIntact() throws {
        let unlinkedFixture = try makeLinkedEditFixture(seed: 700, linked: false)
        let linkCommand = EditCommand.linkClips(
            sequenceID: unlinkedFixture.sequenceID,
            linkGroupID: unlinkedFixture.linkGroupID,
            clips: [
                ClipReference(
                    trackID: unlinkedFixture.videoTrackID,
                    clipID: unlinkedFixture.videoClipID
                ),
                ClipReference(
                    trackID: unlinkedFixture.audioTrackID,
                    clipID: unlinkedFixture.audioClipID
                )
            ]
        )
        var linkHistory = EditHistory(project: unlinkedFixture.project)
        let linkedProject = try linkHistory.apply(linkCommand)

        XCTAssertEqual(linkedProject.validate(), .valid)
        XCTAssertEqual(
            try videoClip(in: linkedProject, fixture: unlinkedFixture).linkGroupID,
            unlinkedFixture.linkGroupID
        )
        XCTAssertEqual(
            try audioClip(in: linkedProject, fixture: unlinkedFixture).linkGroupID,
            unlinkedFixture.linkGroupID
        )
        XCTAssertEqual(linkHistory.undo(), unlinkedFixture.project)
        XCTAssertEqual(try linkHistory.redo(), linkedProject)

        let unlinkCommand = EditCommand.unlinkClips(
            sequenceID: unlinkedFixture.sequenceID,
            linkGroupID: unlinkedFixture.linkGroupID
        )
        var unlinkHistory = EditHistory(project: linkedProject)
        let detachedProject = try unlinkHistory.apply(unlinkCommand)

        XCTAssertEqual(detachedProject.validate(), .valid)
        XCTAssertNil(try videoClip(in: detachedProject, fixture: unlinkedFixture).linkGroupID)
        XCTAssertNil(try audioClip(in: detachedProject, fixture: unlinkedFixture).linkGroupID)
        XCTAssertEqual(linkedProject, unlinkHistory.undo())
        XCTAssertEqual(try unlinkHistory.redo(), detachedProject)
    }

    func testFRTL009LinkedMovePropagatesSameTimelineDeltaAcrossGeneratedProjects() throws {
        for seed in 710..<720 {
            let fixture = try makeLinkedEditFixture(seed: seed)
            let startFrame = Int64(12 + (seed - 710))

            let edited = try apply(
                .moveClip(
                    sequenceID: fixture.sequenceID,
                    sourceTrackID: fixture.videoTrackID,
                    clipID: fixture.videoClipID,
                    destinationTrackID: fixture.videoTrackID,
                    timelineRange: try editRange(startFrame: startFrame, durationFrames: 10)
                ),
                to: fixture.project
            )

            XCTAssertEqual(edited.validate(), .valid)
            try assertRange(
                try videoClip(in: edited, fixture: fixture).timelineRange,
                startFrame: startFrame,
                durationFrames: 10
            )
            try assertRange(
                try audioClip(in: edited, fixture: fixture).timelineRange,
                startFrame: startFrame,
                durationFrames: 10
            )
        }
    }

    func testFRTL009MomentaryUnlinkMoveEditsOnlySelectedClip() throws {
        let fixture = try makeLinkedEditFixture(seed: 730)

        let edited = try apply(
            .moveClip(
                sequenceID: fixture.sequenceID,
                sourceTrackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                destinationTrackID: fixture.videoTrackID,
                timelineRange: try editRange(startFrame: 12, durationFrames: 10),
                linkedClipEditMode: .unlinked
            ),
            to: fixture.project
        )

        XCTAssertEqual(edited.validate(), .valid)
        try assertRange(
            try videoClip(in: edited, fixture: fixture).timelineRange,
            startFrame: 12,
            durationFrames: 10
        )
        try assertRange(
            try audioClip(in: edited, fixture: fixture).timelineRange,
            startFrame: 0,
            durationFrames: 10
        )
    }

    func testFRTL009LinkedTrimPropagatesSourceTimelineAndDurationDeltas() throws {
        for seed in 740..<750 {
            let fixture = try makeLinkedEditFixture(seed: seed)
            let trimStartFrame = Int64(1 + ((seed - 740) % 3))
            let durationFrames = Int64(6 + ((seed - 740) % 2))

            let edited = try apply(
                .trimClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.videoClipID,
                    sourceRange: try editRange(
                        startFrame: trimStartFrame,
                        durationFrames: durationFrames
                    ),
                    timelineRange: try editRange(
                        startFrame: trimStartFrame,
                        durationFrames: durationFrames
                    )
                ),
                to: fixture.project
            )

            XCTAssertEqual(edited.validate(), .valid)
            try assertRange(
                try videoClip(in: edited, fixture: fixture).sourceRange,
                startFrame: trimStartFrame,
                durationFrames: durationFrames
            )
            try assertRange(
                try audioClip(in: edited, fixture: fixture).sourceRange,
                startFrame: trimStartFrame,
                durationFrames: durationFrames
            )
            try assertRange(
                try audioClip(in: edited, fixture: fixture).timelineRange,
                startFrame: trimStartFrame,
                durationFrames: durationFrames
            )
        }
    }

    func testFRTL009DetachAudioRemovesLinkGroupAndMissingGroupReturnsTypedError() throws {
        let fixture = try makeLinkedEditFixture(seed: 760)
        let detached = try apply(
            .unlinkClips(sequenceID: fixture.sequenceID, linkGroupID: fixture.linkGroupID),
            to: fixture.project
        )

        XCTAssertNil(try videoClip(in: detached, fixture: fixture).linkGroupID)
        XCTAssertNil(try audioClip(in: detached, fixture: fixture).linkGroupID)
        XCTAssertNotNil(try videoClip(in: detached, fixture: fixture))
        XCTAssertNotNil(try audioClip(in: detached, fixture: fixture))

        XCTAssertThrowsError(
            try apply(
                .unlinkClips(sequenceID: fixture.sequenceID, linkGroupID: fixture.linkGroupID),
                to: detached
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .linkGroupNotFound(
                    sequenceID: fixture.sequenceID,
                    linkGroupID: fixture.linkGroupID
                )
            )
        }
    }
}

final class EditReducerLinkedClipValidationTests: XCTestCase {
    func testFRTL009InvalidLinkCommandsRejectTooFewAndDuplicateReferences() throws {
        let fixture = try makeLinkedEditFixture(seed: 770, linked: false)
        let videoReference = ClipReference(
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID
        )

        XCTAssertThrowsError(
            try apply(
                .linkClips(
                    sequenceID: fixture.sequenceID,
                    linkGroupID: fixture.linkGroupID,
                    clips: [videoReference]
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.linkRequiresAtLeastTwoClips(linkGroupID: fixture.linkGroupID))
            )
        }

        XCTAssertThrowsError(
            try apply(
                .linkClips(
                    sequenceID: fixture.sequenceID,
                    linkGroupID: fixture.linkGroupID,
                    clips: [videoReference, videoReference]
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .duplicateClipLinkReference(
                        trackID: fixture.videoTrackID,
                        clipID: fixture.videoClipID
                    )
                )
            )
        }
    }

    func testFRTL009InvalidLinkCommandRejectsVideoOnlyGroup() throws {
        let fixture = try makeLinkedEditFixture(seed: 770, linked: false)
        let videoReference = ClipReference(
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID
        )

        let secondVideoClipID = try editUUID(770_100)
        let secondVideoClip = try makeEditClip(
            id: secondVideoClipID,
            mediaID: fixture.mediaID,
            startFrame: 12
        )
        let videoOnlyProject = try apply(
            .addClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: secondVideoClip
            ),
            to: fixture.project
        )
        XCTAssertThrowsError(
            try apply(
                .linkClips(
                    sequenceID: fixture.sequenceID,
                    linkGroupID: fixture.linkGroupID,
                    clips: [
                        videoReference,
                        ClipReference(trackID: fixture.videoTrackID, clipID: secondVideoClipID)
                    ]
                ),
                to: videoOnlyProject
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.linkRequiresVideoAndAudio(linkGroupID: fixture.linkGroupID))
            )
        }
    }

    func testFRTL009InvalidLinkCommandReturnsTypedMissingClipError() throws {
        let fixture = try makeLinkedEditFixture(seed: 770, linked: false)
        let videoReference = ClipReference(
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID
        )

        let missingClipID = try editUUID(770_101)
        XCTAssertThrowsError(
            try apply(
                .linkClips(
                    sequenceID: fixture.sequenceID,
                    linkGroupID: fixture.linkGroupID,
                    clips: [
                        videoReference,
                        ClipReference(trackID: fixture.audioTrackID, clipID: missingClipID)
                    ]
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .clipNotFound(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clipID: missingClipID
                )
            )
        }
    }

    func testFRTL009InvalidLinkCommandRejectsClipAlreadyLinkedElsewhere() throws {
        let linkedFixture = try makeLinkedEditFixture(seed: 771)
        let alternateLinkGroupID = try editUUID(771_100)
        XCTAssertThrowsError(
            try apply(
                .linkClips(
                    sequenceID: linkedFixture.sequenceID,
                    linkGroupID: alternateLinkGroupID,
                    clips: [
                        ClipReference(
                            trackID: linkedFixture.videoTrackID,
                            clipID: linkedFixture.videoClipID
                        ),
                        ClipReference(
                            trackID: linkedFixture.audioTrackID,
                            clipID: linkedFixture.audioClipID
                        )
                    ]
                ),
                to: linkedFixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .clipAlreadyLinked(
                        clipID: linkedFixture.videoClipID,
                        linkGroupID: linkedFixture.linkGroupID
                    )
                )
            )
        }
    }
}

func makeLinkedClipCommandCases(seed: Int) throws -> [EditCommandCase] {
    let unlinkedFixture = try makeLinkedEditFixture(seed: 1_000 + seed, linked: false)
    let linkedFixture = try makeLinkedEditFixture(seed: 1_100 + seed)
    let unlinkedVideoReference = ClipReference(
        trackID: unlinkedFixture.videoTrackID,
        clipID: unlinkedFixture.videoClipID
    )
    let unlinkedAudioReference = ClipReference(
        trackID: unlinkedFixture.audioTrackID,
        clipID: unlinkedFixture.audioClipID
    )

    return try [
        EditCommandCase(
            project: unlinkedFixture.project,
            command: .linkClips(
                sequenceID: unlinkedFixture.sequenceID,
                linkGroupID: unlinkedFixture.linkGroupID,
                clips: [unlinkedVideoReference, unlinkedAudioReference]
            )
        ),
        EditCommandCase(
            project: linkedFixture.project,
            command: .unlinkClips(
                sequenceID: linkedFixture.sequenceID,
                linkGroupID: linkedFixture.linkGroupID
            )
        ),
        EditCommandCase(
            project: linkedFixture.project,
            command: .moveClip(
                sequenceID: linkedFixture.sequenceID,
                sourceTrackID: linkedFixture.videoTrackID,
                clipID: linkedFixture.videoClipID,
                destinationTrackID: linkedFixture.videoTrackID,
                timelineRange: try editRange(startFrame: 12, durationFrames: 10)
            )
        ),
        EditCommandCase(
            project: linkedFixture.project,
            command: .trimClip(
                sequenceID: linkedFixture.sequenceID,
                trackID: linkedFixture.videoTrackID,
                clipID: linkedFixture.videoClipID,
                sourceRange: try editRange(startFrame: 1, durationFrames: 8),
                timelineRange: try editRange(startFrame: 1, durationFrames: 8)
            )
        )
    ]
}

private func videoClip(in project: Project, fixture: LinkedEditFixture) throws -> Clip {
    try requiredClip(
        fixture.videoClipID,
        trackID: fixture.videoTrackID,
        in: project,
        sequenceID: fixture.sequenceID
    )
}

private func audioClip(in project: Project, fixture: LinkedEditFixture) throws -> Clip {
    try requiredClip(
        fixture.audioClipID,
        trackID: fixture.audioTrackID,
        in: project,
        sequenceID: fixture.sequenceID
    )
}
