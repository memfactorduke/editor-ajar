// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class AjarProjectClipEffectLegacyDecodeTests: XCTestCase {
    func testFRPROJ005FRCOMP001LegacyEffectsWithoutChromaKeyDefaultToDisabled() throws {
        let package = try AjarProjectCodec.encode(try makeLegacyClipEffectProject())
        let legacyProjectJSON = try legacyEffectsProjectJSONWithoutClipEffectKey(
            "chromaKey",
            package.projectJSON
        )
        let loadedProject = try editableLegacyEffectsProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let videoClip = try firstLegacyEffectsClip(in: loadedProject)

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.effects.chromaKey, .disabled)
        XCTAssertEqual(videoClip.effectsAnimation.chromaKey, .disabled)
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }

    func testFRPROJ005FRCOMP003LegacyEffectsWithoutMasksDefaultToEmpty() throws {
        let package = try AjarProjectCodec.encode(try makeLegacyClipEffectProject())
        let legacyProjectJSON = try legacyEffectsProjectJSONWithoutClipEffectKey(
            "masks",
            package.projectJSON
        )
        let loadedProject = try editableLegacyEffectsProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let videoClip = try firstLegacyEffectsClip(in: loadedProject)

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.effects.masks, [])
        XCTAssertEqual(videoClip.effectsAnimation.masks, [])
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }

    func testFRPROJ005FRCOL001LegacyEffectsWithoutColorCorrectionDefaultToIdentity() throws {
        let package = try AjarProjectCodec.encode(try makeLegacyClipEffectProject())
        let legacyProjectJSON = try legacyEffectsProjectJSONWithoutClipEffectKey(
            "colorCorrection",
            package.projectJSON
        )
        let loadedProject = try editableLegacyEffectsProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let videoClip = try firstLegacyEffectsClip(in: loadedProject)

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.effects.colorCorrection, .identity)
        XCTAssertEqual(videoClip.effectsAnimation.colorCorrection, .identity)
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }
}

private func legacyEffectsProjectJSONWithoutClipEffectKey(
    _ key: String,
    _ projectJSON: Data
) throws -> Data {
    try updatingLegacyEffectsFirstClipPayload(projectJSON) { clipPayload in
        var effects = try XCTUnwrap(clipPayload["effects"] as? [String: Any])
        var effectsAnimation = try XCTUnwrap(
            clipPayload["effectsAnimation"] as? [String: Any]
        )

        effects.removeValue(forKey: key)
        effectsAnimation.removeValue(forKey: key)
        clipPayload["effects"] = effects
        clipPayload["effectsAnimation"] = effectsAnimation
    }
}

private func updatingLegacyEffectsFirstClipPayload(
    _ projectJSON: Data,
    update: (inout [String: Any]) throws -> Void
) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var videoTracks = try XCTUnwrap(sequence["videoTracks"] as? [[String: Any]])
    var videoTrack = try XCTUnwrap(videoTracks.first)
    var items = try XCTUnwrap(videoTrack["items"] as? [[String: Any]])
    var clipItem = try XCTUnwrap(items.first)
    var clipWrapper = try XCTUnwrap(clipItem["clip"] as? [String: Any])

    document["schemaVersion"] = 1
    if var clipPayload = clipWrapper["_0"] as? [String: Any] {
        try update(&clipPayload)
        clipWrapper["_0"] = clipPayload
        clipItem["clip"] = clipWrapper
    } else {
        try update(&clipWrapper)
        clipItem["clip"] = clipWrapper
    }

    items[0] = clipItem
    videoTrack["items"] = items
    videoTracks[0] = videoTrack
    sequence["videoTracks"] = videoTracks
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func makeLegacyClipEffectProject() throws -> Project {
    let mediaID = try legacyEffectsUUID(1)
    let clip = Clip(
        id: try legacyEffectsUUID(2),
        source: .media(id: mediaID),
        sourceRange: try legacyEffectsRange(startFrame: 0, durationFrames: 10),
        timelineRange: try legacyEffectsRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Legacy clip effects",
        effects: try makeLegacyClipEffects()
    )
    let sequence = Sequence(
        id: try legacyEffectsUUID(3),
        name: "Legacy effect decode",
        videoTracks: [
            Track(
                id: try legacyEffectsUUID(4),
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
            resolution: PixelDimensions(width: 16, height: 9),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [try legacyEffectsMedia(id: mediaID)],
        sequences: [sequence]
    )
}

private func makeLegacyClipEffects() throws -> ClipEffects {
    ClipEffects(
        chromaKey: ClipChromaKeySettings(
            enabled: true,
            tolerance: try RationalValue(numerator: 1, denominator: 4),
            edgeSoftness: try RationalValue(numerator: 1, denominator: 10),
            spillSuppression: try RationalValue(numerator: 1, denominator: 2)
        ),
        colorCorrection: ClipColorCorrection(
            exposure: try RationalValue(numerator: 1, denominator: 2),
            saturation: try RationalValue(numerator: 3, denominator: 2)
        ),
        masks: [
            ClipMask(
                id: try legacyEffectsUUID(5),
                shape: .rectangle(
                    ClipRectangleMask(
                        x: .zero,
                        y: .zero,
                        width: RationalValue(16),
                        height: RationalValue(9)
                    )
                ),
                featherRadius: try RationalValue(numerator: 1, denominator: 2)
            )
        ]
    )
}

private func legacyEffectsMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/legacy-effects.mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 16, height: 9),
            frameRate: try FrameRate(frames: 24),
            duration: try legacyEffectsTime(240),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func editableLegacyEffectsProject(from result: AjarProjectLoadResult) throws -> Project {
    guard case .editable(let project) = result else {
        XCTFail("Expected editable project")
        throw LegacyEffectsCodecError.expectedEditableProject
    }
    return project
}

private func firstLegacyEffectsClip(in project: Project) throws -> Clip {
    let sequence = try XCTUnwrap(project.sequences.first)
    let track = try XCTUnwrap(sequence.videoTracks.first)
    for item in track.items {
        if case .clip(let clip) = item {
            return clip
        }
    }
    throw LegacyEffectsCodecError.expectedClip
}

private func legacyEffectsRange(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(
        start: legacyEffectsTime(startFrame),
        duration: legacyEffectsTime(durationFrames)
    )
}

private func legacyEffectsTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func legacyEffectsUUID(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", 900_000 + value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}

private enum LegacyEffectsCodecError: Error {
    case expectedEditableProject
    case expectedClip
}
