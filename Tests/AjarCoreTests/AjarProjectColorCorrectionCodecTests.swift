// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class AjarProjectColorCorrectionCodecTests: XCTestCase {
    func testFRCOL001ColorCorrectionRoundTripThroughProjectCodec() throws {
        let project = try makeColorCorrectionCodecProject()
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loadedProject = try editableColorCorrectionProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let videoClip = try firstColorCorrectionClip(in: loadedProject)

        XCTAssertEqual(loadedProject, project)
        XCTAssertEqual(videoClip.effects.colorCorrection, try colorCorrectionCodecValue())
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }

    func testFRPROJ005FRCOL001LegacyEffectsWithoutColorCorrectionDefaultToIdentity() throws {
        let project = try makeColorCorrectionCodecProject()
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let legacyProjectJSON = try colorCorrectionProjectJSONWithoutColorCorrection(
            package.projectJSON
        )
        let loadedProject = try editableColorCorrectionProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let videoClip = try firstColorCorrectionClip(in: loadedProject)

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.effects.colorCorrection, .identity)
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }

    func testFRPROJ005FRCOL001SparseColorCorrectionDefaultsMissingControls() throws {
        let json = """
        {
          "exposure" : {
            "denominator" : 2,
            "numerator" : 1
          },
          "gain" : {
            "blue" : {
              "denominator" : 10,
              "numerator" : 9
            },
            "green" : {
              "denominator" : 1,
              "numerator" : 1
            },
            "red" : {
              "denominator" : 5,
              "numerator" : 6
            }
          }
        }
        """

        let correction = try JSONDecoder().decode(
            ClipColorCorrection.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(correction.lift, .zero)
        XCTAssertEqual(correction.gamma, .one)
        XCTAssertEqual(
            correction.gain,
            ClipColorChannels(
                red: try RationalValue(numerator: 6, denominator: 5),
                green: .one,
                blue: try RationalValue(numerator: 9, denominator: 10)
            )
        )
        XCTAssertEqual(correction.exposure, try RationalValue(numerator: 1, denominator: 2))
        XCTAssertEqual(correction.contrast, .one)
        XCTAssertEqual(correction.saturation, .one)
        XCTAssertEqual(correction.temperature, .zero)
        XCTAssertEqual(correction.tint, .zero)
        XCTAssertEqual(correction.vibrance, .zero)
    }

    func testFRPROJ005FRCOL001SparseAnimatableColorCorrectionDefaultsMissingControls() throws {
        let json = """
        {
          "vibrance" : {
            "base" : {
              "denominator" : 3,
              "numerator" : 1
            },
            "keyframes" : []
          }
        }
        """

        let correction = try JSONDecoder().decode(
            AnimatableClipColorCorrection.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(
            correction.baseCorrection,
            ClipColorCorrection(vibrance: try RationalValue(numerator: 1, denominator: 3))
        )
        XCTAssertEqual(correction.value(at: .zero), correction.baseCorrection)
    }
}

private func makeColorCorrectionCodecProject() throws -> Project {
    let mediaID = try colorCorrectionCodecUUID(1)
    let clip = Clip(
        id: try colorCorrectionCodecUUID(2),
        source: .media(id: mediaID),
        sourceRange: try colorCorrectionCodecRange(startFrame: 0, durationFrames: 10),
        timelineRange: try colorCorrectionCodecRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Color correction codec clip",
        effects: ClipEffects(colorCorrection: try colorCorrectionCodecValue())
    )
    let sequence = Sequence(
        id: try colorCorrectionCodecUUID(3),
        name: "Color correction codec",
        videoTracks: [
            Track(
                id: try colorCorrectionCodecUUID(4),
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
        mediaPool: [try colorCorrectionCodecMedia(id: mediaID)],
        sequences: [sequence]
    )
}

private func colorCorrectionCodecValue() throws -> ClipColorCorrection {
    ClipColorCorrection(
        lift: ClipColorChannels(
            red: try RationalValue(numerator: 1, denominator: 20),
            green: .zero,
            blue: try RationalValue(numerator: -1, denominator: 20)
        ),
        gamma: ClipColorChannels(
            red: .one,
            green: try RationalValue(numerator: 11, denominator: 10),
            blue: .one
        ),
        gain: ClipColorChannels(
            red: try RationalValue(numerator: 6, denominator: 5),
            green: .one,
            blue: try RationalValue(numerator: 9, denominator: 10)
        ),
        exposure: try RationalValue(numerator: 1, denominator: 2),
        contrast: try RationalValue(numerator: 6, denominator: 5),
        saturation: try RationalValue(numerator: 7, denominator: 5),
        temperature: try RationalValue(numerator: 1, denominator: 4),
        tint: try RationalValue(numerator: -1, denominator: 5),
        vibrance: try RationalValue(numerator: 1, denominator: 3)
    )
}

private func colorCorrectionCodecMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/color-correction-codec.mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try colorCorrectionCodecTime(240),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func colorCorrectionProjectJSONWithoutColorCorrection(_ projectJSON: Data) throws -> Data {
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
    effects.removeValue(forKey: "colorCorrection")
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

private func editableColorCorrectionProject(from result: AjarProjectLoadResult) throws -> Project {
    guard case .editable(let project) = result else {
        XCTFail("Expected editable project")
        throw ColorCorrectionCodecError.expectedEditableProject
    }
    return project
}

private func firstColorCorrectionClip(in project: Project) throws -> Clip {
    let sequence = try XCTUnwrap(project.sequences.first)
    let track = try XCTUnwrap(sequence.videoTracks.first)
    for item in track.items {
        if case .clip(let clip) = item {
            return clip
        }
    }
    throw ColorCorrectionCodecError.expectedClip
}

private func colorCorrectionCodecRange(
    startFrame: Int64,
    durationFrames: Int64
) throws -> TimeRange {
    try TimeRange(
        start: try colorCorrectionCodecTime(startFrame),
        duration: try colorCorrectionCodecTime(durationFrames)
    )
}

private func colorCorrectionCodecTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func colorCorrectionCodecUUID(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value + 900)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}

private enum ColorCorrectionCodecError: Error {
    case expectedClip
    case expectedEditableProject
}
