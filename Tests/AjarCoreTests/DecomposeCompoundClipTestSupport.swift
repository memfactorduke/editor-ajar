// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

struct SpeedDecomposeScenario {
    let seed: Int
    let speed: RationalValue
    let compoundDuration: Int64
    let expectedFirstStart: Int64
    let expectedFirstDuration: Int64
    let expectedSecondStart: Int64
    let expectedSecondDuration: Int64
}

struct SpeedAwareDecomposeFixture {
    let project: Project
    let parentSequenceID: UUID
    let trackID: UUID
    let compoundClipID: UUID
    let firstClipID: UUID
    let secondClipID: UUID
}

struct EmptyDecomposeFixture {
    let project: Project
    let parentSequenceID: UUID
    let targetSequenceID: UUID
    let trackID: UUID
    let compoundClipID: UUID
}

struct OverlapDecomposeFixture {
    let project: Project
    let parentSequenceID: UUID
    let compoundTrackID: UUID
    let targetTrackID: UUID
    let compoundClipID: UUID
    let innerClipID: UUID
}

struct MultiTrackDecomposeFixture {
    let project: Project
    let parentSequenceID: UUID
    let videoTrackID: UUID
    let audioTrackID: UUID
    let compoundClipID: UUID
    let videoClipID: UUID
    let audioClipID: UUID
}

private struct SpeedDecomposeIDs {
    let mediaID: UUID
    let parentSequenceID: UUID
    let targetSequenceID: UUID
    let trackID: UUID
    let compoundClipID: UUID
    let firstClipID: UUID
    let secondClipID: UUID
}

private struct OverlapDecomposeIDs {
    let mediaID: UUID
    let parentSequenceID: UUID
    let targetSequenceID: UUID
    let compoundTrackID: UUID
    let targetTrackID: UUID
    let compoundClipID: UUID
    let innerClipID: UUID
    let existingClipID: UUID
}

private struct MultiTrackDecomposeIDs {
    let mediaID: UUID
    let parentSequenceID: UUID
    let targetSequenceID: UUID
    let videoTrackID: UUID
    let audioTrackID: UUID
    let compoundClipID: UUID
    let videoClipID: UUID
    let audioClipID: UUID
}

func speedDecomposeScenarios() throws -> [SpeedDecomposeScenario] {
    [
        SpeedDecomposeScenario(
            seed: 1382,
            speed: RationalValue(2),
            compoundDuration: 6,
            expectedFirstStart: 10,
            expectedFirstDuration: 4,
            expectedSecondStart: 14,
            expectedSecondDuration: 2
        ),
        SpeedDecomposeScenario(
            seed: 1383,
            speed: try RationalValue(numerator: 1, denominator: 2),
            compoundDuration: 24,
            expectedFirstStart: 10,
            expectedFirstDuration: 16,
            expectedSecondStart: 26,
            expectedSecondDuration: 8
        )
    ]
}

func makeSpeedAwareDecomposeFixture(
    seed: Int,
    compoundSpeed: RationalValue,
    compoundTimelineDurationFrames: Int64
) throws -> SpeedAwareDecomposeFixture {
    let ids = try makeSpeedDecomposeIDs(seed: seed)
    let media = try makeEditMediaRef(id: ids.mediaID)
    let targetSequence = try makeSpeedTargetSequence(ids: ids)
    let parentSequence = try makeSpeedParentSequence(
        ids: ids,
        compoundSpeed: compoundSpeed,
        compoundTimelineDurationFrames: compoundTimelineDurationFrames
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [media],
        sequences: [parentSequence, targetSequence]
    )

    return SpeedAwareDecomposeFixture(
        project: project,
        parentSequenceID: ids.parentSequenceID,
        trackID: ids.trackID,
        compoundClipID: ids.compoundClipID,
        firstClipID: ids.firstClipID,
        secondClipID: ids.secondClipID
    )
}

private func makeSpeedDecomposeIDs(seed: Int) throws -> SpeedDecomposeIDs {
    let base = seed * 1_000
    return SpeedDecomposeIDs(
        mediaID: try editUUID(base + 1),
        parentSequenceID: try editUUID(base + 2),
        targetSequenceID: try editUUID(base + 3),
        trackID: try editUUID(base + 4),
        compoundClipID: try editUUID(base + 5),
        firstClipID: try editUUID(base + 6),
        secondClipID: try editUUID(base + 7)
    )
}

private func makeSpeedTargetSequence(ids: SpeedDecomposeIDs) throws -> Sequence {
    let firstClip = try makeEditClip(
        id: ids.firstClipID,
        mediaID: ids.mediaID,
        startFrame: 0,
        durationFrames: 8
    )
    let secondClip = try makeEditClip(
        id: ids.secondClipID,
        mediaID: ids.mediaID,
        startFrame: 8,
        durationFrames: 4
    )
    let targetTrack = Track(
        id: ids.trackID,
        kind: .video,
        items: [.clip(firstClip), .clip(secondClip)]
    )
    return Sequence(
        id: ids.targetSequenceID,
        name: "FR-CMP-004 speed target",
        videoTracks: [targetTrack],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeSpeedParentSequence(
    ids: SpeedDecomposeIDs,
    compoundSpeed: RationalValue,
    compoundTimelineDurationFrames: Int64
) throws -> Sequence {
    let compoundRange = try editRange(
        startFrame: 10,
        durationFrames: compoundTimelineDurationFrames
    )
    let compoundClip = Clip(
        id: ids.compoundClipID,
        source: .sequence(id: ids.targetSequenceID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 12),
        timelineRange: compoundRange,
        kind: .video,
        name: "FR-CMP-004 speed compound",
        speed: compoundSpeed
    )
    let track = Track(id: ids.trackID, kind: .video, items: [.clip(compoundClip)])
    return Sequence(
        id: ids.parentSequenceID,
        name: "FR-CMP-004 speed parent",
        videoTracks: [track],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

func makeEmptyDecomposeFixture(seed: Int) throws -> EmptyDecomposeFixture {
    let base = seed * 1_000
    let parentSequenceID = try editUUID(base + 1)
    let targetSequenceID = try editUUID(base + 2)
    let trackID = try editUUID(base + 3)
    let compoundClipID = try editUUID(base + 4)
    let targetSequence = Sequence(
        id: targetSequenceID,
        name: "FR-CMP-004 empty target",
        videoTracks: [],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let compoundClip = try makeCompoundClip(
        id: compoundClipID,
        targetSequenceID: targetSequenceID,
        startFrame: 0,
        durationFrames: 8
    )
    let parentSequence = Sequence(
        id: parentSequenceID,
        name: "FR-CMP-004 empty parent",
        videoTracks: [Track(id: trackID, kind: .video, items: [.clip(compoundClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [],
        sequences: [parentSequence, targetSequence]
    )

    return EmptyDecomposeFixture(
        project: project,
        parentSequenceID: parentSequenceID,
        targetSequenceID: targetSequenceID,
        trackID: trackID,
        compoundClipID: compoundClipID
    )
}

func makeMultiTrackDecomposeFixture(seed: Int) throws -> MultiTrackDecomposeFixture {
    let ids = try makeMultiTrackDecomposeIDs(seed: seed)
    let media = try makeEditMediaRef(id: ids.mediaID)
    let targetSequence = try makeMultiTrackTargetSequence(ids: ids)
    let parentSequence = try makeMultiTrackParentSequence(ids: ids)
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [media],
        sequences: [parentSequence, targetSequence]
    )

    return MultiTrackDecomposeFixture(
        project: project,
        parentSequenceID: ids.parentSequenceID,
        videoTrackID: ids.videoTrackID,
        audioTrackID: ids.audioTrackID,
        compoundClipID: ids.compoundClipID,
        videoClipID: ids.videoClipID,
        audioClipID: ids.audioClipID
    )
}

private func makeMultiTrackDecomposeIDs(seed: Int) throws -> MultiTrackDecomposeIDs {
    let base = seed * 1_000
    return MultiTrackDecomposeIDs(
        mediaID: try editUUID(base + 1),
        parentSequenceID: try editUUID(base + 2),
        targetSequenceID: try editUUID(base + 3),
        videoTrackID: try editUUID(base + 4),
        audioTrackID: try editUUID(base + 5),
        compoundClipID: try editUUID(base + 6),
        videoClipID: try editUUID(base + 7),
        audioClipID: try editUUID(base + 8)
    )
}

private func makeMultiTrackTargetSequence(ids: MultiTrackDecomposeIDs) throws -> Sequence {
    let videoClip = try makeEditClip(
        id: ids.videoClipID,
        mediaID: ids.mediaID,
        startFrame: 0,
        durationFrames: 8
    )
    let audioClip = try makeEditClip(
        id: ids.audioClipID,
        mediaID: ids.mediaID,
        startFrame: 2,
        durationFrames: 6,
        kind: .audio
    )
    return Sequence(
        id: ids.targetSequenceID,
        name: "FR-CMP-004 multi-track target",
        videoTracks: [Track(id: ids.videoTrackID, kind: .video, items: [.clip(videoClip)])],
        audioTracks: [Track(id: ids.audioTrackID, kind: .audio, items: [.clip(audioClip)])],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeMultiTrackParentSequence(ids: MultiTrackDecomposeIDs) throws -> Sequence {
    let compoundClip = try makeCompoundClip(
        id: ids.compoundClipID,
        targetSequenceID: ids.targetSequenceID,
        startFrame: 12,
        durationFrames: 12
    )
    return Sequence(
        id: ids.parentSequenceID,
        name: "FR-CMP-004 multi-track parent",
        videoTracks: [Track(id: ids.videoTrackID, kind: .video, items: [.clip(compoundClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

func makeOverlapDecomposeFixture(seed: Int) throws -> OverlapDecomposeFixture {
    let ids = try makeOverlapDecomposeIDs(seed: seed)
    let media = try makeEditMediaRef(id: ids.mediaID)
    let targetSequence = try makeOverlapTargetSequence(ids: ids)
    let parentSequence = try makeOverlapParentSequence(ids: ids)
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [media],
        sequences: [parentSequence, targetSequence]
    )

    return OverlapDecomposeFixture(
        project: project,
        parentSequenceID: ids.parentSequenceID,
        compoundTrackID: ids.compoundTrackID,
        targetTrackID: ids.targetTrackID,
        compoundClipID: ids.compoundClipID,
        innerClipID: ids.innerClipID
    )
}

private func makeOverlapDecomposeIDs(seed: Int) throws -> OverlapDecomposeIDs {
    let base = seed * 1_000
    return OverlapDecomposeIDs(
        mediaID: try editUUID(base + 1),
        parentSequenceID: try editUUID(base + 2),
        targetSequenceID: try editUUID(base + 3),
        compoundTrackID: try editUUID(base + 4),
        targetTrackID: try editUUID(base + 5),
        compoundClipID: try editUUID(base + 6),
        innerClipID: try editUUID(base + 7),
        existingClipID: try editUUID(base + 8)
    )
}

private func makeOverlapTargetSequence(ids: OverlapDecomposeIDs) throws -> Sequence {
    let innerClip = try makeEditClip(
        id: ids.innerClipID,
        mediaID: ids.mediaID,
        startFrame: 0,
        durationFrames: 10
    )
    let targetTrack = Track(id: ids.targetTrackID, kind: .video, items: [.clip(innerClip)])
    return Sequence(
        id: ids.targetSequenceID,
        name: "FR-CMP-004 overlap target",
        videoTracks: [targetTrack],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeOverlapParentSequence(ids: OverlapDecomposeIDs) throws -> Sequence {
    let compoundClip = try makeCompoundClip(
        id: ids.compoundClipID,
        targetSequenceID: ids.targetSequenceID,
        startFrame: 0,
        durationFrames: 10
    )
    let existingClip = try makeEditClip(
        id: ids.existingClipID,
        mediaID: ids.mediaID,
        startFrame: 0,
        durationFrames: 10
    )
    return Sequence(
        id: ids.parentSequenceID,
        name: "FR-CMP-004 overlap parent",
        videoTracks: [
            Track(id: ids.compoundTrackID, kind: .video, items: [.clip(compoundClip)]),
            Track(id: ids.targetTrackID, kind: .video, items: [.clip(existingClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

func requiredDecomposeSequence(_ sequenceID: UUID, in project: Project) throws -> Sequence {
    try XCTUnwrap(project.sequences.first { $0.id == sequenceID })
}
