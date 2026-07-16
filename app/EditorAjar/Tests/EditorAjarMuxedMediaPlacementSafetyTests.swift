// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarMuxedMediaPlacementSafetyTests: MuxedMediaPlacementTestCase {
    private let partialLinkMessage =
        "This edit would move or replace only part of a linked audio/video group. Target both linked tracks, move to a cut, or detach the clips first. The project was not changed."
    private let lockedLinkMessage =
        "Unlock every track in the affected linked audio/video group, then try again."

    func testMuxedPlacementRefusesWithoutBothUnlockedTargetsAndNeverPlacesHalf() throws {
        let fixture = try makeFixture(
            videoItems: [.clip(try tailClip(kind: .video, start: 0, duration: 10))],
            audioItems: [.clip(try tailClip(kind: .audio, start: 0, duration: 10))],
            audioLocked: true
        )
        let model = makeModel(project: fixture.project)
        let before = model.project

        XCTAssertFalse(model.insertMediaOnTimeline(mediaID: fixture.muxedMediaID))
        XCTAssertEqual(model.project, before)

        model.setSelectedMediaIDs([fixture.muxedMediaID])
        model.scrub(to: 1)
        model.setTimelineRangeIn()
        model.scrub(to: 5)
        model.setTimelineRangeOut()
        XCTAssertFalse(model.canPerformThreePointEdit)
        XCTAssertFalse(model.performThreePointEdit(mode: .insert))
        XCTAssertEqual(model.project, before)

        let missingAudioFixture = try makeFixture(
            videoItems: [],
            audioItems: [],
            includeAudioTrack: false
        )
        let missingAudioModel = makeModel(project: missingAudioFixture.project)
        let missingAudioBefore = missingAudioModel.project
        XCTAssertFalse(
            missingAudioModel.insertMediaOnTimeline(
                mediaID: missingAudioFixture.muxedMediaID
            ))
        XCTAssertEqual(missingAudioModel.project, missingAudioBefore)
        XCTAssertTrue(
            try XCTUnwrap(
                missingAudioModel.activeSequence?.videoTracks.first
            ).items.isEmpty)
    }

    func testVideoOnlyAndAudioOnlyInsertRemainSingleAndUnlinked() throws {
        let fixture = try makeFixture(videoItems: [], audioItems: [])
        let model = makeModel(project: fixture.project)

        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: fixture.videoOnlyMediaID))
        var sequence = try XCTUnwrap(model.activeSequence)
        XCTAssertEqual(sequence.videoTracks[0].items.count, 1)
        XCTAssertTrue(sequence.audioTracks[0].items.isEmpty)
        XCTAssertNil(try XCTUnwrap(clips(in: sequence.videoTracks[0]).first).linkGroupID)

        model.undo()
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: fixture.audioOnlyMediaID))
        sequence = try XCTUnwrap(model.activeSequence)
        XCTAssertTrue(sequence.videoTracks[0].items.isEmpty)
        XCTAssertEqual(sequence.audioTracks[0].items.count, 1)
        XCTAssertNil(try XCTUnwrap(clips(in: sequence.audioTracks[0]).first).linkGroupID)
    }

    func testMuxedInsertRipplesEveryLaterMemberOfTargetedLinkedPairInOneUndo() throws {
        let linkGroupID = UUID()
        let fixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 20,
                    duration: 10,
                    name: "Later linked video",
                    linkGroupID: linkGroupID
                ))
            ],
            audioItems: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 20,
                    duration: 10,
                    name: "Later linked audio",
                    linkGroupID: linkGroupID
                ))
            ]
        )
        let model = makeModel(project: fixture.project)
        model.scrub(to: 10)
        let before = model.project

        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: fixture.muxedMediaID))

        let sequence = try XCTUnwrap(model.activeSequence)
        let laterVideo = try clip(named: "Later linked video", in: sequence.videoTracks[0])
        let laterAudio = try clip(named: "Later linked audio", in: sequence.audioTracks[0])
        try assertRange(laterVideo.timelineRange, start: 25, duration: 10)
        try assertRange(laterAudio.timelineRange, start: 25, duration: 10)
        XCTAssertEqual(laterVideo.linkGroupID, linkGroupID)
        XCTAssertEqual(laterAudio.linkGroupID, linkGroupID)

        let after = model.project
        model.undo()
        XCTAssertEqual(model.project, before)
        model.redo()
        XCTAssertEqual(model.project, after)
    }

    func testSingleEssenceInsertAndOverwriteRefuseAffectedLinkedPairWithoutMutation() throws {
        let laterGroupID = UUID()
        let insertFixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 20,
                    duration: 10,
                    name: "Later video",
                    linkGroupID: laterGroupID
                ))
            ],
            audioItems: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 20,
                    duration: 10,
                    name: "Later audio",
                    linkGroupID: laterGroupID
                ))
            ]
        )
        let insertModel = makeModel(project: insertFixture.project)
        insertModel.scrub(to: 10)
        let beforeInsert = insertModel.project

        XCTAssertFalse(insertModel.insertMediaOnTimeline(mediaID: insertFixture.videoOnlyMediaID))
        XCTAssertEqual(insertModel.project, beforeInsert)
        XCTAssertEqual(insertModel.loadMessage, partialLinkMessage)

        let intersectingGroupID = UUID()
        let overwriteFixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 0,
                    duration: 10,
                    name: "Conflict video",
                    linkGroupID: intersectingGroupID
                ))
            ],
            audioItems: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 0,
                    duration: 10,
                    name: "Conflict audio",
                    linkGroupID: intersectingGroupID
                ))
            ]
        )
        let overwriteModel = makeModel(project: overwriteFixture.project)
        overwriteModel.setSelectedMediaIDs([overwriteFixture.videoOnlyMediaID])
        let beforeOverwrite = overwriteModel.project

        XCTAssertFalse(overwriteModel.editSelectedMedia(.overwrite))
        XCTAssertEqual(overwriteModel.project, beforeOverwrite)
        XCTAssertEqual(overwriteModel.loadMessage, partialLinkMessage)
    }

    func testMuxedInsertRefusesLaterOffTargetAndLockedLinkedPartners() throws {
        let offTargetGroupID = UUID()
        let offTargetAudio = Track(
            id: UUID(),
            kind: .audio,
            items: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 20,
                    duration: 10,
                    name: "Off-target audio",
                    linkGroupID: offTargetGroupID
                ))
            ]
        )
        let offTargetFixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 20,
                    duration: 10,
                    name: "Target video",
                    linkGroupID: offTargetGroupID
                ))
            ],
            audioItems: [],
            additionalAudioTracks: [offTargetAudio]
        )
        let offTargetModel = makeModel(project: offTargetFixture.project)
        offTargetModel.scrub(to: 10)
        let offTargetBefore = offTargetModel.project

        XCTAssertFalse(
            offTargetModel.insertMediaOnTimeline(mediaID: offTargetFixture.muxedMediaID)
        )
        XCTAssertEqual(offTargetModel.project, offTargetBefore)
        XCTAssertEqual(offTargetModel.loadMessage, partialLinkMessage)

        let lockedGroupID = UUID()
        let lockedAudio = Track(
            id: UUID(),
            kind: .audio,
            items: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 20,
                    duration: 10,
                    name: "Locked audio",
                    linkGroupID: lockedGroupID
                ))
            ],
            locked: true
        )
        let lockedFixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 20,
                    duration: 10,
                    name: "Target video",
                    linkGroupID: lockedGroupID
                ))
            ],
            audioItems: [],
            additionalAudioTracks: [lockedAudio]
        )
        let lockedModel = makeModel(project: lockedFixture.project)
        lockedModel.scrub(to: 10)
        let lockedBefore = lockedModel.project

        XCTAssertFalse(lockedModel.insertMediaOnTimeline(mediaID: lockedFixture.muxedMediaID))
        XCTAssertEqual(lockedModel.project, lockedBefore)
        XCTAssertEqual(lockedModel.loadMessage, lockedLinkMessage)
    }

    func testMuxedOverwriteRefusesOffTargetPartnerButRemovesFullyTargetedPairAtomically() throws {
        let offTargetGroupID = UUID()
        let offTargetAudio = Track(
            id: UUID(),
            kind: .audio,
            items: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 0,
                    duration: 10,
                    name: "Off-target conflict audio",
                    linkGroupID: offTargetGroupID
                ))
            ]
        )
        let offTargetFixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 0,
                    duration: 10,
                    name: "Target conflict video",
                    linkGroupID: offTargetGroupID
                ))
            ],
            audioItems: [],
            additionalAudioTracks: [offTargetAudio]
        )
        let offTargetModel = makeModel(project: offTargetFixture.project)
        offTargetModel.setSelectedMediaIDs([offTargetFixture.muxedMediaID])
        let offTargetBefore = offTargetModel.project

        XCTAssertFalse(offTargetModel.editSelectedMedia(.overwrite))
        XCTAssertEqual(offTargetModel.project, offTargetBefore)
        XCTAssertEqual(offTargetModel.loadMessage, partialLinkMessage)

        let targetGroupID = UUID()
        let targetFixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 0,
                    duration: 10,
                    name: "Target pair video",
                    linkGroupID: targetGroupID
                ))
            ],
            audioItems: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 0,
                    duration: 10,
                    name: "Target pair audio",
                    linkGroupID: targetGroupID
                ))
            ]
        )
        let targetModel = makeModel(project: targetFixture.project)
        targetModel.setSelectedMediaIDs([targetFixture.muxedMediaID])
        let targetBefore = targetModel.project

        XCTAssertTrue(targetModel.editSelectedMedia(.overwrite))
        let targetSequence = try XCTUnwrap(targetModel.activeSequence)
        XCTAssertNil(clips(in: targetSequence.videoTracks[0]).first {
            $0.linkGroupID == targetGroupID
        })
        XCTAssertNil(clips(in: targetSequence.audioTracks[0]).first {
            $0.linkGroupID == targetGroupID
        })
        modelUndoAndAssert(targetModel, equals: targetBefore)
    }

    func testSingleEssenceThreePointInsertAndOverwriteRefuseLinkedPair() throws {
        let linkGroupID = UUID()
        let fixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 20,
                    duration: 10,
                    name: "Three-point video",
                    linkGroupID: linkGroupID
                ))
            ],
            audioItems: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 20,
                    duration: 10,
                    name: "Three-point audio",
                    linkGroupID: linkGroupID
                ))
            ]
        )
        let model = makeModel(project: fixture.project)
        model.setSelectedMediaIDs([fixture.videoOnlyMediaID])
        setTimelineMarks(on: model, inFrame: 20, outFrame: 25)
        let before = model.project

        XCTAssertFalse(model.performThreePointEdit(mode: .insert))
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.loadMessage, partialLinkMessage)
        XCTAssertFalse(model.performThreePointEdit(mode: .overwrite))
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.loadMessage, partialLinkMessage)
    }

    func testMuxedThreePointInsertAndOverwriteRefuseOffTargetPartner() throws {
        let linkGroupID = UUID()
        let offTargetAudio = Track(
            id: UUID(),
            kind: .audio,
            items: [
                .clip(try makeClip(
                    kind: .audio,
                    start: 20,
                    duration: 10,
                    name: "Three-point off-target audio",
                    linkGroupID: linkGroupID
                ))
            ]
        )
        let fixture = try makeFixture(
            videoItems: [
                .clip(try makeClip(
                    kind: .video,
                    start: 20,
                    duration: 10,
                    name: "Three-point target video",
                    linkGroupID: linkGroupID
                ))
            ],
            audioItems: [],
            additionalAudioTracks: [offTargetAudio]
        )
        let model = makeModel(project: fixture.project)
        model.setSelectedMediaIDs([fixture.muxedMediaID])
        setTimelineMarks(on: model, inFrame: 20, outFrame: 25)
        let before = model.project

        XCTAssertFalse(model.performThreePointEdit(mode: .insert))
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.loadMessage, partialLinkMessage)
        XCTAssertFalse(model.performThreePointEdit(mode: .overwrite))
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.loadMessage, partialLinkMessage)
    }

    func testReplaceUsesOnlySelectedCompatibleUnlockedDestination() throws {
        let fixture = try makeFixture(
            videoItems: [.clip(try tailClip(kind: .video, start: 0, duration: 10))],
            audioItems: [.clip(try tailClip(kind: .audio, start: 0, duration: 10))]
        )
        let model = makeModel(project: fixture.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let destination = try XCTUnwrap(clips(in: sequence.videoTracks[0]).first)
        let audioBefore = sequence.audioTracks[0]
        model.selectClip(
            trackID: sequence.videoTracks[0].id,
            clipID: destination.id,
            mode: .replace
        )
        model.setSelectedMediaIDs([fixture.muxedMediaID])

        XCTAssertTrue(model.editSelectedMedia(.replace))
        let replaced = try XCTUnwrap(
            clips(
                in: try XCTUnwrap(model.activeSequence?.videoTracks.first)
            ).first)
        XCTAssertEqual(replaced.source, .media(id: fixture.muxedMediaID))
        XCTAssertEqual(model.activeSequence?.audioTracks.first, audioBefore)

        model.undo()
        model.setSelectedMediaIDs([fixture.audioOnlyMediaID])
        XCTAssertFalse(model.editSelectedMedia(.replace))
        XCTAssertEqual(model.project, fixture.project)
    }

    func testLinkedBladeAssignsFreshRightGroupAndPreservesLeftGroup() throws {
        let leftGroupID = UUID()
        let fixture = try makeFixture(
            videoItems: [
                .clip(
                    try originalClip(
                        kind: .video,
                        duration: 30,
                        linkGroupID: leftGroupID
                    ))
            ],
            audioItems: [
                .clip(
                    try originalClip(
                        kind: .audio,
                        duration: 30,
                        linkGroupID: leftGroupID
                    ))
            ]
        )
        let model = makeModel(project: fixture.project)
        let sequence = try XCTUnwrap(model.activeSequence)
        let selected = try XCTUnwrap(clips(in: sequence.videoTracks[0]).first)
        let before = model.project

        XCTAssertTrue(
            model.bladeClip(
                reference: TimelineClipReference(
                    trackID: sequence.videoTracks[0].id,
                    clipID: selected.id
                ),
                atFrame: 10
            ))

        let video = clips(in: try XCTUnwrap(model.activeSequence?.videoTracks.first))
        let audio = clips(in: try XCTUnwrap(model.activeSequence?.audioTracks.first))
        XCTAssertEqual(video.count, 2)
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(video[0].linkGroupID, leftGroupID)
        XCTAssertEqual(audio[0].linkGroupID, leftGroupID)
        XCTAssertNotNil(video[1].linkGroupID)
        XCTAssertEqual(video[1].linkGroupID, audio[1].linkGroupID)
        XCTAssertNotEqual(video[1].linkGroupID, leftGroupID)

        let after = model.project
        model.undo()
        XCTAssertEqual(model.project, before)
        model.redo()
        XCTAssertEqual(model.project, after)
    }

    private func setTimelineMarks(
        on model: EditorAjarAppModel,
        inFrame: Int64,
        outFrame: Int64
    ) {
        model.scrub(to: inFrame)
        model.setTimelineRangeIn()
        model.scrub(to: outFrame)
        model.setTimelineRangeOut()
    }

    private func modelUndoAndAssert(_ model: EditorAjarAppModel, equals project: Project?) {
        model.undo()
        XCTAssertEqual(model.project, project)
    }
}
