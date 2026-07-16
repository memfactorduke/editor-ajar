// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class LinkedPlacementActionNameTests: XCTestCase {
    func testLinkedInsertUsesGestureName() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            fixture.transaction([
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: fixture.video
                ),
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clip: fixture.audio
                )
            ]).actionName,
            "Insert Clip"
        )
    }

    func testLinkedMidClipInsertKeepsInsertGestureName() throws {
        let fixture = try makeFixture()
        let rightVideoID = try editUUID(7_409_201)
        let rightAudioID = try editUUID(7_409_202)
        let commands: [EditCommand] = [
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.video.id,
                atTime: try editTime(5),
                rightClipID: rightVideoID
            ),
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audio.id,
                atTime: try editTime(5),
                rightClipID: rightAudioID
            ),
            .linkClips(
                sequenceID: fixture.sequenceID,
                linkGroupID: try editUUID(7_409_203),
                clips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: rightVideoID),
                    ClipReference(trackID: fixture.audioTrackID, clipID: rightAudioID)
                ]
            ),
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: fixture.video
            ),
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clip: fixture.audio
            )
        ]
        XCTAssertEqual(fixture.transaction(commands).actionName, "Insert Clip")
    }

    func testLinkedOverwriteUsesGestureName() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            fixture.transaction([
                .overwriteClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: fixture.video
                ),
                .overwriteClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clip: fixture.audio
                )
            ]).actionName,
            "Overwrite Clip"
        )
    }

    func testLinkedAppendWithUnequalTrackEndsUsesGestureName() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            fixture.transaction([
                .appendClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: fixture.video
                ),
                .addClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clip: fixture.audio
                )
            ]).actionName,
            "Append Clip"
        )
    }

    func testLinkedThreePointEditUsesGestureName() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            fixture.transaction([
                fixture.threePointEdit(
                    trackID: fixture.videoTrackID,
                    clip: fixture.video,
                    kind: .video
                ),
                fixture.threePointEdit(
                    trackID: fixture.audioTrackID,
                    clip: fixture.audio,
                    kind: .audio
                )
            ]).actionName,
            "Three-Point Edit"
        )
    }

    func testLinkedBladeUsesGestureName() throws {
        let fixture = try makeFixture()
        let rightVideoID = try editUUID(7_409_101)
        let rightAudioID = try editUUID(7_409_102)
        let commands: [EditCommand] = [
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.video.id,
                atTime: try editTime(5),
                rightClipID: rightVideoID
            ),
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audio.id,
                atTime: try editTime(5),
                rightClipID: rightAudioID
            ),
            .linkClips(
                sequenceID: fixture.sequenceID,
                linkGroupID: try editUUID(7_409_103),
                clips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: rightVideoID),
                    ClipReference(trackID: fixture.audioTrackID, clipID: rightAudioID)
                ]
            )
        ]
        XCTAssertEqual(EditCommand.transaction(commands).actionName, "Blade Clip")
    }

    private func makeFixture() throws -> LinkedPlacementActionNameFixture {
        let linked = try makeLinkedEditFixture(seed: 7_409, linked: false)
        return try LinkedPlacementActionNameFixture(
            linked: linked,
            video: requiredClip(
                linked.videoClipID,
                trackID: linked.videoTrackID,
                in: linked.project,
                sequenceID: linked.sequenceID
            ),
            audio: requiredClip(
                linked.audioClipID,
                trackID: linked.audioTrackID,
                in: linked.project,
                sequenceID: linked.sequenceID
            )
        )
    }
}

private struct LinkedPlacementActionNameFixture {
    let sequenceID: UUID
    let videoTrackID: UUID
    let audioTrackID: UUID
    let linkGroupID: UUID
    let video: Clip
    let audio: Clip

    init(linked: LinkedEditFixture, video: Clip, audio: Clip) {
        sequenceID = linked.sequenceID
        videoTrackID = linked.videoTrackID
        audioTrackID = linked.audioTrackID
        linkGroupID = linked.linkGroupID
        self.video = video
        self.audio = audio
    }

    func transaction(_ commands: [EditCommand]) -> EditCommand {
        .transaction(
            commands + [
                .linkClips(
                    sequenceID: sequenceID,
                    linkGroupID: linkGroupID,
                    clips: [
                        ClipReference(trackID: videoTrackID, clipID: video.id),
                        ClipReference(trackID: audioTrackID, clipID: audio.id)
                    ]
                )
            ])
    }

    func threePointEdit(trackID: UUID, clip: Clip, kind: TrackKind) -> EditCommand {
        .threePointEdit(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: clip.id,
            source: clip.source,
            sourceRange: clip.sourceRange,
            timelineStart: clip.timelineRange.start,
            kind: kind,
            name: clip.name,
            mode: .insert
        )
    }
}
