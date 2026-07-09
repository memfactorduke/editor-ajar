// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

func fx002Project(
    stack: ClipEffectStack,
    animation: AnimatableClipEffectStack,
    fixture: EditFixture
) throws -> Project {
    try replacingVideoItems(
        [
            .clip(
                Clip(
                    id: fixture.clipID,
                    source: .media(id: fixture.mediaID),
                    sourceRange: try editRange(startFrame: 0, durationFrames: 10),
                    timelineRange: try editRange(startFrame: 0, durationFrames: 10),
                    kind: .video,
                    name: "FX002",
                    effectStack: stack,
                    effectStackAnimation: animation
                )
            )
        ],
        in: fixture
    )
}

func makeFX002Settings() throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: 16, height: 16),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}

func makeFX002Sequence(id: UUID, trackID: UUID, clip: Clip) throws -> Sequence {
    Sequence(
        id: id,
        name: "FX002",
        videoTracks: [Track(id: trackID, kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

struct FX002NestedIDs {
    let mediaID: UUID
    let nestedSequenceID: UUID
    let nestedTrackID: UUID
    let nestedClipID: UUID
    let parentSequenceID: UUID
    let parentTrackID: UUID
    let parentClipID: UUID
    let nodeID: UUID

    init() throws {
        mediaID = try editUUID(6_120_001)
        nestedSequenceID = try editUUID(6_120_200)
        nestedTrackID = try editUUID(6_120_202)
        nestedClipID = try editUUID(6_120_201)
        parentSequenceID = try editUUID(6_120_203)
        parentTrackID = try editUUID(6_120_204)
        parentClipID = try editUUID(6_120_205)
        nodeID = try editUUID(6_120_100)
    }
}

func makeFX002NestedProject(ids: FX002NestedIDs, nestedClip: Clip) throws -> Project {
    let nestedSequence = Sequence(
        id: ids.nestedSequenceID,
        name: "FX002 nested",
        videoTracks: [
            Track(id: ids.nestedTrackID, kind: .video, items: [.clip(nestedClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let parentClip = Clip(
        id: ids.parentClipID,
        source: .sequence(id: ids.nestedSequenceID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Compound parent"
    )
    let parentSequence = Sequence(
        id: ids.parentSequenceID,
        name: "FX002 parent",
        videoTracks: [
            Track(id: ids.parentTrackID, kind: .video, items: [.clip(parentClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try makeFX002Settings(),
        mediaPool: [try makeFXMediaRef(id: ids.mediaID)],
        sequences: [parentSequence, nestedSequence]
    )
}

func clearGaussianBlurParameters(in projectJSON: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: projectJSON)
    let cleared = try clearingGaussianBlurParameters(in: object)
    return try JSONSerialization.data(withJSONObject: cleared, options: [.sortedKeys])
}

func clearingGaussianBlurParameters(in value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        if dictionary["kind"] as? String == "gaussianBlur" {
            dictionary["parameters"] = [String: Any]()
        }
        for (key, nested) in dictionary {
            dictionary[key] = try clearingGaussianBlurParameters(in: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try clearingGaussianBlurParameters(in: $0) }
    }
    return value
}

func fx002EditableProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        XCTFail("Expected editable project")
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

func nestedEffectClip(
    nestedClipID: UUID,
    nestedSequenceID: UUID,
    in project: Project
) throws -> Clip {
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == nestedSequenceID })
    let track = try XCTUnwrap(sequence.videoTracks.first)
    for item in track.items {
        if case .clip(let clip) = item, clip.id == nestedClipID {
            return clip
        }
    }
    throw NSError(domain: "FX002", code: 2)
}

func makeFXMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "prores4444",
            pixelDimensions: PixelDimensions(width: 16, height: 16),
            frameRate: try FrameRate(frames: 24),
            duration: try FrameRate(frames: 24).duration(ofFrames: 10),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}
