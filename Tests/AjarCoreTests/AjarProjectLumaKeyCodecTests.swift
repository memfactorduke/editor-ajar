// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class AjarProjectLumaKeyCodecTests: XCTestCase {
    func testFRCOMP005LumaKeyRoundTripThroughProjectCodec() throws {
        let project = try makeLumaKeyCodecProject()
        let package = try AjarProjectCodec.encode(project)
        let loadedProject = try editableLumaKeyProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let videoClip = try firstLumaKeyClip(in: loadedProject)

        XCTAssertEqual(loadedProject, project)
        XCTAssertEqual(videoClip.effects.lumaKey, try lumaKeyCodecValue())
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }

    func testFRPROJ005FRCOMP005LegacyEffectsWithoutLumaKeyDefaultToDisabled() throws {
        let project = try makeLumaKeyCodecProject()
        let package = try AjarProjectCodec.encode(project)
        let legacyProjectJSON = try lumaKeyProjectJSONWithoutLumaKey(package.projectJSON)
        let loadedProject = try editableLumaKeyProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let videoClip = try firstLumaKeyClip(in: loadedProject)

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.effects.lumaKey, .disabled)
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }
}

private func makeLumaKeyCodecProject() throws -> Project {
    let mediaID = try lumaKeyCodecUUID(1)
    let clip = Clip(
        id: try lumaKeyCodecUUID(2),
        source: .media(id: mediaID),
        sourceRange: try lumaKeyCodecRange(startFrame: 0, durationFrames: 10),
        timelineRange: try lumaKeyCodecRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Luma key codec clip",
        effects: ClipEffects(lumaKey: try lumaKeyCodecValue())
    )
    let sequence = Sequence(
        id: try lumaKeyCodecUUID(3),
        name: "Luma key codec",
        videoTracks: [
            Track(
                id: try lumaKeyCodecUUID(4),
                kind: .video,
                items: [.clip(clip)]
            )
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )

    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [try lumaKeyCodecMedia(id: mediaID)],
        sequences: [sequence]
    )
}

private func lumaKeyCodecValue() throws -> ClipLumaKeySettings {
    ClipLumaKeySettings(
        enabled: true,
        lowThreshold: try RationalValue(numerator: 1, denominator: 5),
        highThreshold: try RationalValue(numerator: 4, denominator: 5),
        softness: try RationalValue(numerator: 1, denominator: 10),
        invert: true
    )
}

private func lumaKeyCodecMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/luma-key-codec.mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "prores4444",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try lumaKeyCodecTime(240),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func lumaKeyProjectJSONWithoutLumaKey(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var tracks = try XCTUnwrap(sequence["videoTracks"] as? [[String: Any]])
    var track = try XCTUnwrap(tracks.first)
    var items = try XCTUnwrap(track["items"] as? [[String: Any]])
    var clipItem = try XCTUnwrap(items.first)
    var clipWrapper = try XCTUnwrap(clipItem["clip"] as? [String: Any])
    var clipPayload = try XCTUnwrap(clipWrapper["_0"] as? [String: Any])
    var effects = try XCTUnwrap(clipPayload["effects"] as? [String: Any])

    document["schemaVersion"] = 1
    effects.removeValue(forKey: "lumaKey")
    clipPayload["effects"] = effects
    clipPayload.removeValue(forKey: "effectsAnimation")
    clipWrapper["_0"] = clipPayload
    clipItem["clip"] = clipWrapper
    items[0] = clipItem
    track["items"] = items
    tracks[0] = track
    sequence["videoTracks"] = tracks
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func editableLumaKeyProject(from result: AjarProjectLoadResult) throws -> Project {
    guard case .editable(let project) = result else {
        XCTFail("Expected editable project")
        throw LumaKeyCodecError.expectedEditableProject
    }
    return project
}

private func firstLumaKeyClip(in project: Project) throws -> Clip {
    let sequence = try XCTUnwrap(project.sequences.first)
    let track = try XCTUnwrap(sequence.videoTracks.first)
    for item in track.items {
        if case .clip(let clip) = item {
            return clip
        }
    }
    throw LumaKeyCodecError.expectedClip
}

private func lumaKeyCodecRange(
    startFrame: Int64,
    durationFrames: Int64
) throws -> TimeRange {
    try TimeRange(
        start: try lumaKeyCodecTime(startFrame),
        duration: try lumaKeyCodecTime(durationFrames)
    )
}

private func lumaKeyCodecTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func lumaKeyCodecUUID(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value + 1_000)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}

private enum LumaKeyCodecError: Error {
    case expectedClip
    case expectedEditableProject
}
