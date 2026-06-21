// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

struct EditFixture {
    let project: Project
    let sequenceID: UUID
    let videoTrackID: UUID
    let audioTrackID: UUID
    let clipID: UUID
    let mediaID: UUID
}

func makeEditFixture(seed: Int) throws -> EditFixture {
    let base = seed * 1_000
    let mediaID = try editUUID(base + 1)
    let sequenceID = try editUUID(base + 2)
    let videoTrackID = try editUUID(base + 3)
    let audioTrackID = try editUUID(base + 4)
    let clipID = try editUUID(base + 5)
    let media = try makeEditMediaRef(id: mediaID)
    let clip = try makeEditClip(id: clipID, mediaID: mediaID, startFrame: 0)
    let videoTrack = Track(id: videoTrackID, kind: .video, items: [.clip(clip)])
    let audioTrack = Track(id: audioTrackID, kind: .audio, items: [])
    let sequence = Sequence(
        id: sequenceID,
        name: "Sequence \(seed)",
        videoTracks: [videoTrack],
        audioTracks: [audioTrack],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: 1,
        settings: try makeEditSettings(),
        mediaPool: [media],
        sequences: [sequence]
    )

    return EditFixture(
        project: project,
        sequenceID: sequenceID,
        videoTrackID: videoTrackID,
        audioTrackID: audioTrackID,
        clipID: clipID,
        mediaID: mediaID
    )
}

func makeEditMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try editTime(240),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

func makeEditClip(
    id: UUID,
    mediaID: UUID,
    startFrame: Int64,
    durationFrames: Int64 = 10,
    kind: TrackKind = .video
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: durationFrames),
        timelineRange: try editRange(startFrame: startFrame, durationFrames: durationFrames),
        kind: kind,
        name: "Clip \(id.uuidString)"
    )
}

func editRange(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: editTime(startFrame), duration: editTime(durationFrames))
}

func editTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

func editUUID(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}

private func makeEditSettings() throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: 1_920, height: 1_080),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}
