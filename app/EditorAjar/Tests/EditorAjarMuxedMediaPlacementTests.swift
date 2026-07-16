// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarMuxedMediaPlacementTests: MuxedMediaPlacementTestCase {
    func testMuxedInsertCreatesOneLinkedPairAndOneUndoRemovesBoth() throws {
        let fixture = try makeFixture(
            videoItems: [.clip(try tailClip(kind: .video, start: 20, duration: 10))],
            audioItems: [.clip(try tailClip(kind: .audio, start: 20, duration: 10))]
        )
        let model = makeModel(project: fixture.project)
        model.scrub(to: 10)
        let before = model.project

        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: fixture.muxedMediaID))

        let insertedVideo = try clip(
            mediaID: fixture.muxedMediaID,
            in: try XCTUnwrap(model.activeSequence?.videoTracks.first)
        )
        let insertedAudio = try clip(
            mediaID: fixture.muxedMediaID,
            in: try XCTUnwrap(model.activeSequence?.audioTracks.first)
        )
        try assertRange(insertedVideo.timelineRange, start: 10, duration: 5)
        try assertRange(insertedAudio.timelineRange, start: 10, duration: 5)
        XCTAssertNotNil(insertedVideo.linkGroupID)
        XCTAssertEqual(insertedVideo.linkGroupID, insertedAudio.linkGroupID)
        try assertRange(
            try clip(
                named: "Tail video", in: try XCTUnwrap(model.activeSequence?.videoTracks.first)
            )
            .timelineRange,
            start: 25,
            duration: 10
        )
        try assertRange(
            try clip(
                named: "Tail audio", in: try XCTUnwrap(model.activeSequence?.audioTracks.first)
            )
            .timelineRange,
            start: 25,
            duration: 10
        )

        let afterPlacement = model.project
        model.selectClip(
            trackID: try XCTUnwrap(model.activeSequence?.videoTracks.first).id,
            clipID: insertedVideo.id,
            mode: .replace
        )
        XCTAssertTrue(model.moveSelectedClip(toStartFrame: 2))
        try assertRange(
            try clip(
                mediaID: fixture.muxedMediaID,
                in: try XCTUnwrap(model.activeSequence?.audioTracks.first)
            ).timelineRange,
            start: 2,
            duration: 5
        )

        model.undo()
        XCTAssertEqual(model.project, afterPlacement)
        model.undo()
        XCTAssertEqual(model.project, before)
        model.redo()
        XCTAssertEqual(model.project, afterPlacement)
    }

    func testMuxedMidClipInsertCreatesIndependentLeftInsertedAndRightGroups() throws {
        let originalGroupID = UUID()
        let fixture = try makeFixture(
            videoItems: [
                .clip(
                    try originalClip(
                        kind: .video,
                        duration: 30,
                        linkGroupID: originalGroupID
                    ))
            ],
            audioItems: [
                .clip(
                    try originalClip(
                        kind: .audio,
                        duration: 30,
                        linkGroupID: originalGroupID
                    ))
            ]
        )
        let model = makeModel(project: fixture.project)
        model.scrub(to: 10)
        let before = model.project

        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: fixture.muxedMediaID))

        let sequence = try XCTUnwrap(model.activeSequence)
        let video = clips(in: try XCTUnwrap(sequence.videoTracks.first))
        let audio = clips(in: try XCTUnwrap(sequence.audioTracks.first))
        XCTAssertEqual(video.count, 3)
        XCTAssertEqual(audio.count, 3)
        for (clip, (expectedStart, expectedDuration)) in zip(
            video,
            [(0, 10), (10, 5), (15, 20)]
        ) {
            try assertRange(
                clip.timelineRange,
                start: Int64(expectedStart),
                duration: Int64(expectedDuration)
            )
        }
        for (clip, (expectedStart, expectedDuration)) in zip(
            audio,
            [(0, 10), (10, 5), (15, 20)]
        ) {
            try assertRange(
                clip.timelineRange,
                start: Int64(expectedStart),
                duration: Int64(expectedDuration)
            )
        }
        let videoGroups = try video.map { try XCTUnwrap($0.linkGroupID) }
        let audioGroups = try audio.map { try XCTUnwrap($0.linkGroupID) }
        XCTAssertEqual(videoGroups, audioGroups)
        XCTAssertEqual(videoGroups[0], originalGroupID)
        XCTAssertEqual(Set(videoGroups).count, 3)
        XCTAssertEqual(video[1].source, .media(id: fixture.muxedMediaID))
        XCTAssertEqual(audio[1].source, .media(id: fixture.muxedMediaID))

        let after = model.project
        model.undo()
        XCTAssertEqual(model.project, before)
        model.redo()
        XCTAssertEqual(model.project, after)
    }

    func testMuxedAppendUsesOneSharedStartWhenTrackEndsDiffer() throws {
        let fixture = try makeFixture(
            videoItems: [.clip(try tailClip(kind: .video, start: 0, duration: 10))],
            audioItems: [.clip(try tailClip(kind: .audio, start: 0, duration: 20))]
        )
        let model = makeModel(project: fixture.project)
        model.setSelectedMediaIDs([fixture.muxedMediaID])
        let before = model.project

        XCTAssertTrue(model.editSelectedMedia(.append))

        let video = try clip(
            mediaID: fixture.muxedMediaID,
            in: try XCTUnwrap(model.activeSequence?.videoTracks.first)
        )
        let audio = try clip(
            mediaID: fixture.muxedMediaID,
            in: try XCTUnwrap(model.activeSequence?.audioTracks.first)
        )
        try assertRange(video.timelineRange, start: 20, duration: 5)
        try assertRange(audio.timelineRange, start: 20, duration: 5)
        XCTAssertEqual(video.linkGroupID, audio.linkGroupID)
        XCTAssertNotNil(video.linkGroupID)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    func testMuxedOverwriteChangesBothTargetsWithoutRipplingLaterItems() throws {
        let fixture = try makeFixture(
            videoItems: [
                .clip(try tailClip(kind: .video, start: 0, duration: 10, name: "Conflict video")),
                .clip(try tailClip(kind: .video, start: 20, duration: 10))
            ],
            audioItems: [
                .clip(try tailClip(kind: .audio, start: 0, duration: 10, name: "Conflict audio")),
                .clip(try tailClip(kind: .audio, start: 20, duration: 10))
            ]
        )
        let model = makeModel(project: fixture.project)
        model.setSelectedMediaIDs([fixture.muxedMediaID])
        let before = model.project

        XCTAssertTrue(model.editSelectedMedia(.overwrite))

        let videoTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        let audioTrack = try XCTUnwrap(model.activeSequence?.audioTracks.first)
        XCTAssertNil(clips(in: videoTrack).first { $0.name == "Conflict video" })
        XCTAssertNil(clips(in: audioTrack).first { $0.name == "Conflict audio" })
        try assertRange(
            try clip(named: "Tail video", in: videoTrack).timelineRange,
            start: 20,
            duration: 10
        )
        try assertRange(
            try clip(named: "Tail audio", in: audioTrack).timelineRange,
            start: 20,
            duration: 10
        )
        let video = try clip(mediaID: fixture.muxedMediaID, in: videoTrack)
        let audio = try clip(mediaID: fixture.muxedMediaID, in: audioTrack)
        try assertRange(video.timelineRange, start: 0, duration: 5)
        try assertRange(audio.timelineRange, start: 0, duration: 5)
        XCTAssertEqual(video.linkGroupID, audio.linkGroupID)

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    func testMuxedThreePointInsertUsesExactRangesAndLinksBothEssences() throws {
        let fixture = try makeFixture(
            videoItems: [.clip(try tailClip(kind: .video, start: 30, duration: 10))],
            audioItems: [.clip(try tailClip(kind: .audio, start: 30, duration: 10))]
        )
        let model = makeModel(project: fixture.project)
        model.setSelectedMediaIDs([fixture.muxedMediaID])
        model.scrub(to: 5)
        model.setTimelineRangeIn()
        model.scrub(to: 10)
        model.setTimelineRangeOut()
        let before = model.project

        XCTAssertTrue(model.canPerformThreePointEdit)
        XCTAssertTrue(model.performThreePointEdit(mode: .insert))

        let video = try clip(
            mediaID: fixture.muxedMediaID,
            in: try XCTUnwrap(model.activeSequence?.videoTracks.first)
        )
        let audio = try clip(
            mediaID: fixture.muxedMediaID,
            in: try XCTUnwrap(model.activeSequence?.audioTracks.first)
        )
        try assertRange(video.timelineRange, start: 5, duration: 5)
        try assertRange(audio.timelineRange, start: 5, duration: 5)
        try assertRange(video.sourceRange, start: 0, duration: 5)
        try assertRange(audio.sourceRange, start: 0, duration: 5)
        XCTAssertEqual(video.linkGroupID, audio.linkGroupID)
        XCTAssertNotNil(video.linkGroupID)
        try assertRange(
            try clip(
                named: "Tail video", in: try XCTUnwrap(model.activeSequence?.videoTracks.first)
            )
            .timelineRange,
            start: 35,
            duration: 10
        )
        try assertRange(
            try clip(
                named: "Tail audio", in: try XCTUnwrap(model.activeSequence?.audioTracks.first)
            )
            .timelineRange,
            start: 35,
            duration: 10
        )

        model.undo()
        XCTAssertEqual(model.project, before)
    }

    func testMuxedThreePointOverwritePlacesOneLinkedPairAndUndoesAtomically() throws {
        let fixture = try makeFixture(
            videoItems: [.clip(try tailClip(kind: .video, start: 20, duration: 10))],
            audioItems: [.clip(try tailClip(kind: .audio, start: 20, duration: 10))]
        )
        let model = makeModel(project: fixture.project)
        model.setSelectedMediaIDs([fixture.muxedMediaID])
        model.scrub(to: 2)
        model.setTimelineRangeIn()
        model.scrub(to: 7)
        model.setTimelineRangeOut()
        let before = model.project

        XCTAssertTrue(model.canPerformThreePointEdit)
        XCTAssertTrue(model.performThreePointEdit(mode: .overwrite))

        let videoTrack = try XCTUnwrap(model.activeSequence?.videoTracks.first)
        let audioTrack = try XCTUnwrap(model.activeSequence?.audioTracks.first)
        let video = try clip(mediaID: fixture.muxedMediaID, in: videoTrack)
        let audio = try clip(mediaID: fixture.muxedMediaID, in: audioTrack)
        try assertRange(video.timelineRange, start: 2, duration: 5)
        try assertRange(audio.timelineRange, start: 2, duration: 5)
        try assertRange(video.sourceRange, start: 0, duration: 5)
        try assertRange(audio.sourceRange, start: 0, duration: 5)
        XCTAssertEqual(video.linkGroupID, audio.linkGroupID)
        XCTAssertNotNil(video.linkGroupID)
        try assertRange(
            try clip(named: "Tail video", in: videoTrack).timelineRange,
            start: 20,
            duration: 10
        )
        try assertRange(
            try clip(named: "Tail audio", in: audioTrack).timelineRange,
            start: 20,
            duration: 10
        )

        model.undo()
        XCTAssertEqual(model.project, before)
    }

}
