// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

private struct RichRoundTripIDs {
    let mediaID: UUID
    let sequenceID: UUID
    let firstVideoTrackID: UUID
    let secondVideoTrackID: UUID
    let audioTrackID: UUID
    let transformedClipID: UUID
    let plainClipID: UUID
    let audioClipID: UUID
    let unselectedClipID: UUID
    let timelineMarkerID: UUID
    let transformedClipMarkerID: UUID
    let audioClipMarkerID: UUID
    let unselectedClipMarkerID: UUID
}

/// Builds a multi-track, attribute-bearing, marker-bearing sequence for the FR-CMP-004
/// make-then-decompose round trip: a 2x transformed video clip, a plain video clip on a second
/// track, an audio clip with a non-identity mix, an unselected clip, and markers anchored to
/// selected clips, an unselected clip, and the timeline.
func makeRichRoundTripFixture(seed: Int) throws -> RichRoundTripFixture {
    let ids = try makeRichRoundTripIDs(seed: seed)
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [try makeEditMediaRef(id: ids.mediaID)],
        sequences: [try makeRichRoundTripSequence(ids: ids)]
    )

    return RichRoundTripFixture(
        project: project,
        sequenceID: ids.sequenceID,
        destinationTrackID: ids.firstVideoTrackID,
        compoundSequenceID: try editUUID(seed * 1_000 + 14),
        compoundClipID: try editUUID(seed * 1_000 + 15),
        selection: [
            ClipReference(trackID: ids.firstVideoTrackID, clipID: ids.transformedClipID),
            ClipReference(trackID: ids.secondVideoTrackID, clipID: ids.plainClipID),
            ClipReference(trackID: ids.audioTrackID, clipID: ids.audioClipID)
        ]
    )
}

private func makeRichRoundTripIDs(seed: Int) throws -> RichRoundTripIDs {
    let base = seed * 1_000
    return RichRoundTripIDs(
        mediaID: try editUUID(base + 1),
        sequenceID: try editUUID(base + 2),
        firstVideoTrackID: try editUUID(base + 3),
        secondVideoTrackID: try editUUID(base + 4),
        audioTrackID: try editUUID(base + 5),
        transformedClipID: try editUUID(base + 6),
        plainClipID: try editUUID(base + 7),
        audioClipID: try editUUID(base + 8),
        unselectedClipID: try editUUID(base + 9),
        timelineMarkerID: try editUUID(base + 10),
        transformedClipMarkerID: try editUUID(base + 11),
        audioClipMarkerID: try editUUID(base + 12),
        unselectedClipMarkerID: try editUUID(base + 13)
    )
}

private func makeRichRoundTripSequence(ids: RichRoundTripIDs) throws -> Sequence {
    let half = try RationalValue(numerator: 1, denominator: 2)
    let transformedClip = try makeEditClip(
        id: ids.transformedClipID,
        mediaID: ids.mediaID,
        startFrame: 10,
        durationFrames: 8,
        transform: ClipTransform(opacity: half),
        speed: RationalValue(2)
    )
    let plainClip = try makeEditClip(
        id: ids.plainClipID,
        mediaID: ids.mediaID,
        startFrame: 12,
        durationFrames: 8
    )
    let audioClip = try makeEditClip(
        id: ids.audioClipID,
        mediaID: ids.mediaID,
        startFrame: 10,
        durationFrames: 6,
        kind: .audio,
        audioMix: ClipAudioMix(gain: .constant(half))
    )
    let unselectedClip = try makeEditClip(
        id: ids.unselectedClipID,
        mediaID: ids.mediaID,
        startFrame: 30,
        durationFrames: 8
    )
    return Sequence(
        id: ids.sequenceID,
        name: "FR-CMP-004 rich round trip",
        videoTracks: [
            Track(id: ids.firstVideoTrackID, kind: .video, items: [.clip(transformedClip)]),
            Track(
                id: ids.secondVideoTrackID,
                kind: .video,
                items: [.clip(plainClip), .clip(unselectedClip)]
            )
        ],
        audioTracks: [
            Track(id: ids.audioTrackID, kind: .audio, items: [.clip(audioClip)])
        ],
        markers: try makeRichRoundTripMarkers(ids: ids),
        timebase: try FrameRate(frames: 24)
    )
}

private func makeRichRoundTripMarkers(ids: RichRoundTripIDs) throws -> [Marker] {
    [
        Marker(id: ids.timelineMarkerID, time: try editTime(3), name: "timeline marker"),
        Marker(
            id: ids.transformedClipMarkerID,
            time: try editTime(11),
            name: "on transformed clip",
            color: .green,
            note: "round trip me",
            anchor: .clip(trackID: ids.firstVideoTrackID, clipID: ids.transformedClipID)
        ),
        Marker(
            id: ids.audioClipMarkerID,
            time: try editTime(15),
            name: "on audio clip",
            anchor: .clip(trackID: ids.audioTrackID, clipID: ids.audioClipID)
        ),
        Marker(
            id: ids.unselectedClipMarkerID,
            time: try editTime(31),
            name: "on unselected clip",
            anchor: .clip(trackID: ids.secondVideoTrackID, clipID: ids.unselectedClipID)
        )
    ]
}
