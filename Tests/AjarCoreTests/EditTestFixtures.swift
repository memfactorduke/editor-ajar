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

func applyingAddClip(_ clip: Clip, fixture: EditFixture) throws -> Project {
    try apply(
        .addClip(sequenceID: fixture.sequenceID, trackID: fixture.videoTrackID, clip: clip),
        to: fixture.project
    )
}

func projectTrack(_ project: Project, fixture: EditFixture) throws -> Track {
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })
    return try XCTUnwrap(sequence.videoTracks.first { $0.id == fixture.videoTrackID })
}

func clip(_ clipID: UUID, in track: Track) -> Clip? {
    for item in track.items {
        if case .clip(let clip) = item, clip.id == clipID {
            return clip
        }
    }
    return nil
}

func requiredClip(
    _ clipID: UUID,
    in project: Project,
    fixture: EditFixture
) throws -> Clip {
    try XCTUnwrap(clip(clipID, in: try projectTrack(project, fixture: fixture)))
}

func replacingVideoItems(
    _ items: [TimelineItem],
    in fixture: EditFixture
) throws -> Project {
    let project = fixture.project
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })
    let videoTracks = sequence.videoTracks.map { track in
        if track.id == fixture.videoTrackID {
            return Track(
                id: track.id,
                kind: track.kind,
                items: items,
                enabled: track.enabled,
                locked: track.locked,
                muted: track.muted,
                solo: track.solo,
                hidden: track.hidden
            )
        }
        return track
    }
    let replacementSequence = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: videoTracks,
        audioTracks: sequence.audioTracks,
        markers: sequence.markers,
        timebase: sequence.timebase
    )

    return Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: project.sequences.map { $0.id == sequence.id ? replacementSequence : $0 }
    )
}

func replacingMarkers(
    _ markers: [Marker],
    in fixture: EditFixture
) throws -> Project {
    let project = fixture.project
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })
    let replacementSequence = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: sequence.videoTracks,
        audioTracks: sequence.audioTracks,
        markers: markers,
        timebase: sequence.timebase
    )

    return Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: project.sequences.map { $0.id == sequence.id ? replacementSequence : $0 }
    )
}

func assertClipRange(
    _ clipID: UUID,
    in project: Project,
    fixture: EditFixture,
    startFrame: Int64,
    durationFrames: Int64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let foundClip = try requiredClip(clipID, in: project, fixture: fixture)
    try assertRange(
        foundClip.timelineRange,
        startFrame: startFrame,
        durationFrames: durationFrames,
        file: file,
        line: line
    )
}

func assertRange(
    _ range: TimeRange,
    startFrame: Int64,
    durationFrames: Int64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(range.start, try editTime(startFrame), file: file, line: line)
    XCTAssertEqual(range.duration, try editTime(durationFrames), file: file, line: line)
}

extension Array where Element == ProjectValidationError {
    var containsItemsOverlap: Bool {
        for error in self {
            if case .itemsOverlap = error {
                return true
            }
        }
        return false
    }

    var containsMissingMarkerClipReference: Bool {
        for error in self {
            if case .missingMarkerClipReference = error {
                return true
            }
        }
        return false
    }
}

private func makeEditSettings() throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: 1_920, height: 1_080),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}
