// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class LinkedTopologyGroupedEditSafetyTests: XCTestCase {
    func testGroupedInsertPreservesLaterLinkedTopology() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_426)
        let project = try movedLinkedFixtureProject(fixture, startFrame: 20)
        let clips = try newLinkedPair(fixture: fixture, seed: 7_426, startFrame: 10)
        let edited = try apply(
            .transaction([
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: clips.video
                ),
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clip: clips.audio
                ),
                clips.linkCommand(sequenceID: fixture.sequenceID, fixture: fixture)
            ]),
            to: project
        )

        try assertTimelineStart(
            fixture.videoClipID,
            trackID: fixture.videoTrackID,
            project: edited,
            sequenceID: fixture.sequenceID,
            frame: 25
        )
        try assertTimelineStart(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            project: edited,
            sequenceID: fixture.sequenceID,
            frame: 25
        )
    }

    func testGroupedOverwriteRemovesWholeLinkedGroup() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_427)
        let clips = try newLinkedPair(fixture: fixture, seed: 7_427, startFrame: 2)
        let edited = try apply(
            .transaction([
                .overwriteClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: clips.video
                ),
                .overwriteClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clip: clips.audio
                ),
                clips.linkCommand(sequenceID: fixture.sequenceID, fixture: fixture)
            ]),
            to: fixture.project
        )

        XCTAssertNil(
            clip(
                fixture.videoClipID,
                in: try projectTrack(
                    fixture.videoTrackID,
                    in: edited,
                    sequenceID: fixture.sequenceID
                )
            )
        )
        XCTAssertNil(
            clip(
                fixture.audioClipID,
                in: try projectTrack(
                    fixture.audioTrackID,
                    in: edited,
                    sequenceID: fixture.sequenceID
                )
            )
        )
    }

    func testGroupedLiftRemovesWholeLinkedGroup() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_435)
        let edited = try apply(
            .transaction([
                .liftClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.videoClipID
                ),
                .liftClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clipID: fixture.audioClipID
                )
            ]),
            to: fixture.project
        )

        XCTAssertNil(
            try projectTrack(
                fixture.videoTrackID,
                in: edited,
                sequenceID: fixture.sequenceID
            ).items.compactMap(clipValue).first(where: { $0.id == fixture.videoClipID })
        )
        XCTAssertNil(
            try projectTrack(
                fixture.audioTrackID,
                in: edited,
                sequenceID: fixture.sequenceID
            ).items.compactMap(clipValue).first(where: { $0.id == fixture.audioClipID })
        )
    }

    func testGroupedRippleDeleteRemovesWholeLinkedGroup() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_436)
        let edited = try apply(
            .transaction([
                .rippleDeleteClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.videoClipID
                ),
                .rippleDeleteClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clipID: fixture.audioClipID
                )
            ]),
            to: fixture.project
        )

        XCTAssertNil(
            try projectTrack(
                fixture.videoTrackID,
                in: edited,
                sequenceID: fixture.sequenceID
            ).items.compactMap(clipValue).first(where: { $0.id == fixture.videoClipID })
        )
        XCTAssertNil(
            try projectTrack(
                fixture.audioTrackID,
                in: edited,
                sequenceID: fixture.sequenceID
            ).items.compactMap(clipValue).first(where: { $0.id == fixture.audioClipID })
        )
    }

    func testGroupedBladeRequiresAndPreservesBothLinkedHalves() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_428)
        let rightVideoID = try editUUID(7_428_101)
        let rightAudioID = try editUUID(7_428_102)
        let rightGroupID = try editUUID(7_428_103)
        let edited = try apply(
            try groupedBladeCommand(
                fixture: fixture,
                rightVideoID: rightVideoID,
                rightAudioID: rightAudioID,
                rightGroupID: rightGroupID
            ),
            to: fixture.project
        )

        XCTAssertEqual(
            try requiredClip(
                fixture.videoClipID,
                trackID: fixture.videoTrackID,
                in: edited,
                sequenceID: fixture.sequenceID
            ).linkGroupID,
            fixture.linkGroupID
        )
        XCTAssertEqual(
            try requiredClip(
                fixture.audioClipID,
                trackID: fixture.audioTrackID,
                in: edited,
                sequenceID: fixture.sequenceID
            ).linkGroupID,
            fixture.linkGroupID
        )
        XCTAssertEqual(
            try requiredClip(
                rightVideoID,
                trackID: fixture.videoTrackID,
                in: edited,
                sequenceID: fixture.sequenceID
            ).linkGroupID,
            rightGroupID
        )
        XCTAssertEqual(
            try requiredClip(
                rightAudioID,
                trackID: fixture.audioTrackID,
                in: edited,
                sequenceID: fixture.sequenceID
            ).linkGroupID,
            rightGroupID
        )
    }

    private func newLinkedPair(
        fixture: LinkedEditFixture,
        seed: Int,
        startFrame: Int64
    ) throws -> LinkedTopologyPair {
        LinkedTopologyPair(
            video: try makeEditClip(
                id: editUUID(seed * 100 + 1),
                mediaID: fixture.mediaID,
                startFrame: startFrame,
                durationFrames: 5
            ),
            audio: try makeEditClip(
                id: editUUID(seed * 100 + 2),
                mediaID: fixture.mediaID,
                startFrame: startFrame,
                durationFrames: 5,
                kind: .audio
            ),
            linkGroupID: try editUUID(seed * 100 + 3)
        )
    }

    private func assertTimelineStart(
        _ clipID: UUID,
        trackID: UUID,
        project: Project,
        sequenceID: UUID,
        frame: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let found = try requiredClip(
            clipID,
            trackID: trackID,
            in: project,
            sequenceID: sequenceID
        )
        XCTAssertEqual(found.timelineRange.start, try editTime(frame), file: file, line: line)
    }

    private func groupedBladeCommand(
        fixture: LinkedEditFixture,
        rightVideoID: UUID,
        rightAudioID: UUID,
        rightGroupID: UUID
    ) throws -> EditCommand {
        .transaction([
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                atTime: try editTime(5),
                rightClipID: rightVideoID
            ),
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                atTime: try editTime(5),
                rightClipID: rightAudioID
            ),
            .linkClips(
                sequenceID: fixture.sequenceID,
                linkGroupID: rightGroupID,
                clips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: rightVideoID),
                    ClipReference(trackID: fixture.audioTrackID, clipID: rightAudioID)
                ]
            )
        ])
    }
}

private func clipValue(_ item: TimelineItem) -> Clip? {
    guard case .clip(let clip) = item else { return nil }
    return clip
}

private struct LinkedTopologyPair {
    let video: Clip
    let audio: Clip
    let linkGroupID: UUID

    func linkCommand(
        sequenceID: UUID,
        fixture: LinkedEditFixture
    ) -> EditCommand {
        .linkClips(
            sequenceID: sequenceID,
            linkGroupID: linkGroupID,
            clips: [
                ClipReference(trackID: fixture.videoTrackID, clipID: video.id),
                ClipReference(trackID: fixture.audioTrackID, clipID: audio.id)
            ]
        )
    }
}
