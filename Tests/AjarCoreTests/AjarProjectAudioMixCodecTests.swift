// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class AjarProjectAudioMixCodecTests: XCTestCase {
    func testFRAUD001AudioMixRoundTripsThroughProjectCodec() throws {
        let project = try makeAudioCodecProject()
        let package = try AjarProjectCodec.encode(project)
        let loadedProject = try editableAudioCodecProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let audioTrack = try firstAudioCodecTrack(in: loadedProject)
        let audioClip = try firstAudioCodecClip(in: loadedProject)

        XCTAssertEqual(loadedProject, project)
        XCTAssertEqual(audioTrack.audioGain, try audioCodecTrackGain())
        XCTAssertEqual(audioTrack.audioPan, try audioCodecTrackPan())
        XCTAssertEqual(audioClip.audioMix, try audioCodecClipMix())
    }

    func testFRPROJ005FRAUD001LegacyAudioClipDefaultsToUnityCenterNoFade() throws {
        let project = try makeAudioCodecProject()
        let package = try AjarProjectCodec.encode(project)
        let legacyProjectJSON = try audioCodecProjectJSONWithoutAudioKeys(package.projectJSON)
        let loadedProject = try editableAudioCodecProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let audioTrack = try firstAudioCodecTrack(in: loadedProject)
        let audioClip = try firstAudioCodecClip(in: loadedProject)

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(audioTrack.audioGain, .constant(.one))
        XCTAssertEqual(audioTrack.audioPan, .constant(.zero))
        XCTAssertEqual(audioClip.audioMix, .identity)
    }
}

private func makeAudioCodecProject() throws -> Project {
    let fixture = try makeLinkedEditFixture(seed: 620)
    let withClipAudio = try apply(
        .setClipAudioMix(
            sequenceID: fixture.sequenceID,
            trackID: fixture.audioTrackID,
            clipID: fixture.audioClipID,
            audioMix: try audioCodecClipMix()
        ),
        to: fixture.project
    )

    return try apply(
        .setTrackAudioMix(
            sequenceID: fixture.sequenceID,
            trackID: fixture.audioTrackID,
            audio: TrackAudioMixPatch(
                gain: try audioCodecTrackGain(),
                pan: try audioCodecTrackPan()
            )
        ),
        to: withClipAudio
    )
}

private func audioCodecClipMix() throws -> ClipAudioMix {
    ClipAudioMix(
        gain: try Animatable(
            base: try RationalValue(numerator: 3, denominator: 4),
            keyframes: [
                Keyframe(
                    time: try editTime(0),
                    value: try RationalValue(numerator: 3, denominator: 4),
                    interpolation: .linear
                ),
                Keyframe(
                    time: try editTime(6),
                    value: try RationalValue(numerator: 5, denominator: 4),
                    interpolation: .easeInOut
                )
            ]
        ),
        pan: .constant(try RationalValue(numerator: 1, denominator: 3)),
        fadeIn: ClipAudioFade(duration: try editTime(2), curve: .easeIn),
        fadeOut: ClipAudioFade(duration: try editTime(2), curve: .easeOut)
    )
}

private func audioCodecTrackGain() throws -> Animatable<RationalValue> {
    .constant(try RationalValue(numerator: 5, denominator: 4))
}

private func audioCodecTrackPan() throws -> Animatable<RationalValue> {
    .constant(try RationalValue(numerator: -1, denominator: 3))
}

private func audioCodecProjectJSONWithoutAudioKeys(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var audioTracks = try XCTUnwrap(sequence["audioTracks"] as? [[String: Any]])
    var audioTrack = try XCTUnwrap(audioTracks.first)
    var items = try XCTUnwrap(audioTrack["items"] as? [[String: Any]])
    var clipItem = try XCTUnwrap(items.first)
    var clipWrapper = try XCTUnwrap(clipItem["clip"] as? [String: Any])

    document["schemaVersion"] = 1
    audioTrack.removeValue(forKey: "audioGain")
    audioTrack.removeValue(forKey: "audioPan")

    if var clipPayload = clipWrapper["_0"] as? [String: Any] {
        clipPayload.removeValue(forKey: "audioMix")
        clipWrapper["_0"] = clipPayload
    } else {
        clipWrapper.removeValue(forKey: "audioMix")
    }

    clipItem["clip"] = clipWrapper
    items[0] = clipItem
    audioTrack["items"] = items
    audioTracks[0] = audioTrack
    sequence["audioTracks"] = audioTracks
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func editableAudioCodecProject(from result: AjarProjectLoadResult) throws -> Project {
    guard case .editable(let project) = result else {
        XCTFail("Expected editable project")
        throw AudioCodecError.expectedEditableProject
    }
    return project
}

private func firstAudioCodecTrack(in project: Project) throws -> Track {
    let sequence = try XCTUnwrap(project.sequences.first)
    return try XCTUnwrap(sequence.audioTracks.first)
}

private func firstAudioCodecClip(in project: Project) throws -> Clip {
    let track = try firstAudioCodecTrack(in: project)
    for item in track.items {
        if case .clip(let clip) = item {
            return clip
        }
    }
    throw AudioCodecError.expectedAudioClip
}

private enum AudioCodecError: Error {
    case expectedEditableProject
    case expectedAudioClip
}
