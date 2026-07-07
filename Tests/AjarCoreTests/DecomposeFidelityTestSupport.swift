// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

struct WindowedDecomposeFixture {
    let project: Project
    let parentSequenceID: UUID
    let targetSequenceID: UUID
    let trackID: UUID
    let compoundClipID: UUID
    let headClipID: UUID
    let insideClipID: UUID
    let tailClipID: UUID
    let outsideClipID: UUID
    let windowMarkerID: UUID
    let preWindowMarkerID: UUID
    let outsideClipMarkerID: UUID
    let nestedTimelineMarkerID: UUID
    let parentMarkerID: UUID
}

struct RemappedInnerDecomposeFixture {
    let project: Project
    let parentSequenceID: UUID
    let trackID: UUID
    let compoundClipID: UUID
    let reverseClipID: UUID
    let freezeClipID: UUID
}

struct RichRoundTripFixture {
    let project: Project
    let sequenceID: UUID
    let destinationTrackID: UUID
    let compoundSequenceID: UUID
    let compoundClipID: UUID
    let selection: [ClipReference]
}

private struct WindowedDecomposeIDs {
    let mediaID: UUID
    let parentSequenceID: UUID
    let targetSequenceID: UUID
    let trackID: UUID
    let compoundClipID: UUID
    let headClipID: UUID
    let insideClipID: UUID
    let tailClipID: UUID
    let outsideClipID: UUID
    let windowMarkerID: UUID
    let preWindowMarkerID: UUID
    let outsideClipMarkerID: UUID
    let nestedTimelineMarkerID: UUID
    let parentMarkerID: UUID
}

func makeWindowedDecomposeFixture(
    seed: Int,
    compoundSpeed: RationalValue
) throws -> WindowedDecomposeFixture {
    let ids = try makeWindowedDecomposeIDs(seed: seed)
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [try makeEditMediaRef(id: ids.mediaID)],
        sequences: [
            try makeWindowedParentSequence(ids: ids, compoundSpeed: compoundSpeed),
            try makeWindowedTargetSequence(ids: ids)
        ]
    )

    return WindowedDecomposeFixture(
        project: project,
        parentSequenceID: ids.parentSequenceID,
        targetSequenceID: ids.targetSequenceID,
        trackID: ids.trackID,
        compoundClipID: ids.compoundClipID,
        headClipID: ids.headClipID,
        insideClipID: ids.insideClipID,
        tailClipID: ids.tailClipID,
        outsideClipID: ids.outsideClipID,
        windowMarkerID: ids.windowMarkerID,
        preWindowMarkerID: ids.preWindowMarkerID,
        outsideClipMarkerID: ids.outsideClipMarkerID,
        nestedTimelineMarkerID: ids.nestedTimelineMarkerID,
        parentMarkerID: ids.parentMarkerID
    )
}

private func makeWindowedDecomposeIDs(seed: Int) throws -> WindowedDecomposeIDs {
    let base = seed * 1_000
    return WindowedDecomposeIDs(
        mediaID: try editUUID(base + 1),
        parentSequenceID: try editUUID(base + 2),
        targetSequenceID: try editUUID(base + 3),
        trackID: try editUUID(base + 4),
        compoundClipID: try editUUID(base + 5),
        headClipID: try editUUID(base + 6),
        insideClipID: try editUUID(base + 7),
        tailClipID: try editUUID(base + 8),
        outsideClipID: try editUUID(base + 9),
        windowMarkerID: try editUUID(base + 10),
        preWindowMarkerID: try editUUID(base + 11),
        outsideClipMarkerID: try editUUID(base + 12),
        nestedTimelineMarkerID: try editUUID(base + 13),
        parentMarkerID: try editUUID(base + 14)
    )
}

/// Nested layout: head `[0, 6)`, inside `[6, 8)`, tail `[8, 12)`, outside `[12, 14)` against a
/// compound `sourceRange` window of `[4, 10)`.
private func makeWindowedTargetSequence(ids: WindowedDecomposeIDs) throws -> Sequence {
    let head = try makeEditClip(
        id: ids.headClipID,
        mediaID: ids.mediaID,
        startFrame: 0,
        durationFrames: 6
    )
    let inside = try makeEditClip(
        id: ids.insideClipID,
        mediaID: ids.mediaID,
        startFrame: 6,
        durationFrames: 2
    )
    let tail = try makeEditClip(
        id: ids.tailClipID,
        mediaID: ids.mediaID,
        startFrame: 8,
        durationFrames: 4
    )
    let outside = try makeEditClip(
        id: ids.outsideClipID,
        mediaID: ids.mediaID,
        startFrame: 12,
        durationFrames: 2
    )
    return Sequence(
        id: ids.targetSequenceID,
        name: "FR-CMP-004 windowed target",
        videoTracks: [
            Track(
                id: ids.trackID,
                kind: .video,
                items: [.clip(head), .clip(inside), .clip(tail), .clip(outside)]
            )
        ],
        audioTracks: [],
        markers: try makeWindowedTargetMarkers(ids: ids),
        timebase: try FrameRate(frames: 24)
    )
}

private func makeWindowedTargetMarkers(ids: WindowedDecomposeIDs) throws -> [Marker] {
    [
        Marker(
            id: ids.preWindowMarkerID,
            time: try editTime(2),
            name: "before window",
            anchor: .clip(trackID: ids.trackID, clipID: ids.headClipID)
        ),
        Marker(
            id: ids.windowMarkerID,
            time: try editTime(5),
            name: "inside window",
            color: .red,
            note: "restore me",
            anchor: .clip(trackID: ids.trackID, clipID: ids.headClipID)
        ),
        Marker(
            id: ids.nestedTimelineMarkerID,
            time: try editTime(6),
            name: "nested timeline"
        ),
        Marker(
            id: ids.outsideClipMarkerID,
            time: try editTime(13),
            name: "outside clip",
            anchor: .clip(trackID: ids.trackID, clipID: ids.outsideClipID)
        )
    ]
}

private func makeWindowedParentSequence(
    ids: WindowedDecomposeIDs,
    compoundSpeed: RationalValue
) throws -> Sequence {
    let windowDuration = try editTime(6)
    let compoundClip = Clip(
        id: ids.compoundClipID,
        source: .sequence(id: ids.targetSequenceID),
        sourceRange: try TimeRange(start: editTime(4), duration: windowDuration),
        timelineRange: try TimeRange(
            start: editTime(20),
            duration: Clip.timelineDuration(
                forSourceDuration: windowDuration,
                speed: compoundSpeed
            )
        ),
        kind: .video,
        name: "FR-CMP-004 windowed compound",
        speed: compoundSpeed
    )
    return Sequence(
        id: ids.parentSequenceID,
        name: "FR-CMP-004 windowed parent",
        videoTracks: [Track(id: ids.trackID, kind: .video, items: [.clip(compoundClip)])],
        audioTracks: [],
        markers: [
            Marker(id: ids.parentMarkerID, time: try editTime(2), name: "parent timeline")
        ],
        timebase: try FrameRate(frames: 24)
    )
}

/// Nested layout: reverse clip `[0, 8)` and freeze clip `[8, 12)` (held frame at source `3`)
/// against a compound `sourceRange` window of `[2, 10)`.
func makeRemappedInnerDecomposeFixture(seed: Int) throws -> RemappedInnerDecomposeFixture {
    let base = seed * 1_000
    let mediaID = try editUUID(base + 1)
    let parentSequenceID = try editUUID(base + 2)
    let targetSequenceID = try editUUID(base + 3)
    let trackID = try editUUID(base + 4)
    let compoundClipID = try editUUID(base + 5)
    let reverseClipID = try editUUID(base + 6)
    let freezeClipID = try editUUID(base + 7)
    let targetSequence = try makeRemappedTargetSequence(
        id: targetSequenceID,
        trackID: trackID,
        mediaID: mediaID,
        reverseClipID: reverseClipID,
        freezeClipID: freezeClipID
    )
    let compoundClip = Clip(
        id: compoundClipID,
        source: .sequence(id: targetSequenceID),
        sourceRange: try editRange(startFrame: 2, durationFrames: 8),
        timelineRange: try editRange(startFrame: 30, durationFrames: 8),
        kind: .video,
        name: "FR-CMP-004 remapped compound"
    )
    let parentSequence = Sequence(
        id: parentSequenceID,
        name: "FR-CMP-004 remapped parent",
        videoTracks: [Track(id: trackID, kind: .video, items: [.clip(compoundClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [try makeEditMediaRef(id: mediaID)],
        sequences: [parentSequence, targetSequence]
    )

    return RemappedInnerDecomposeFixture(
        project: project,
        parentSequenceID: parentSequenceID,
        trackID: trackID,
        compoundClipID: compoundClipID,
        reverseClipID: reverseClipID,
        freezeClipID: freezeClipID
    )
}

private func makeRemappedTargetSequence(
    id: UUID,
    trackID: UUID,
    mediaID: UUID,
    reverseClipID: UUID,
    freezeClipID: UUID
) throws -> Sequence {
    let reverseClip = try makeEditClip(
        id: reverseClipID,
        mediaID: mediaID,
        startFrame: 0,
        durationFrames: 8,
        reverse: true
    )
    let freezeClip = Clip(
        id: freezeClipID,
        source: .media(id: mediaID),
        sourceRange: try editRange(startFrame: 3, durationFrames: 4),
        timelineRange: try editRange(startFrame: 8, durationFrames: 4),
        kind: .video,
        name: "FR-CMP-004 frozen inner",
        freezeFrame: true
    )
    return Sequence(
        id: id,
        name: "FR-CMP-004 remapped target",
        videoTracks: [
            Track(id: trackID, kind: .video, items: [.clip(reverseClip), .clip(freezeClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}
