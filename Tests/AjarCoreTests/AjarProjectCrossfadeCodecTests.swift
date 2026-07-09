// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Codec coverage for the additive ADR-0015 `equalPower` crossfade curve (FR-AUD-002).
final class AjarProjectCrossfadeCodecTests: XCTestCase {
    func testFRAUD002EqualPowerCrossfadePairRoundTripsThroughProjectCodec() throws {
        let project = try makeCrossfadePairProject(curve: .equalPower)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loadedProject = try editableCrossfadeProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )

        XCTAssertEqual(loadedProject, project)
        let outgoingClip = try crossfadeCodecClip(
            CrossfadeFixtureID.outgoingClip(),
            in: loadedProject
        )
        let incomingClip = try crossfadeCodecClip(
            CrossfadeFixtureID.incomingClip(),
            in: loadedProject
        )
        XCTAssertEqual(outgoingClip.audioMix.trailingCrossfade?.curve, .equalPower)
        XCTAssertEqual(incomingClip.audioMix.leadingCrossfade?.curve, .equalPower)
    }

    func testFRPROJ005FRAUD002LegacyProjectWithoutCrossfadeKeysDecodesUnchanged() throws {
        let project = try makeCrossfadePairProject(curve: .equalPower)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let legacyProjectJSON = try crossfadeProjectJSONWithoutCrossfadeKeys(package.projectJSON)
        let loadedProject = try editableCrossfadeProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        let outgoingClip = try crossfadeCodecClip(
            CrossfadeFixtureID.outgoingClip(),
            in: loadedProject
        )
        let incomingClip = try crossfadeCodecClip(
            CrossfadeFixtureID.incomingClip(),
            in: loadedProject
        )
        XCTAssertNil(outgoingClip.audioMix.leadingCrossfade)
        XCTAssertNil(outgoingClip.audioMix.trailingCrossfade)
        XCTAssertNil(incomingClip.audioMix.leadingCrossfade)
        XCTAssertNil(incomingClip.audioMix.trailingCrossfade)
        XCTAssertEqual(outgoingClip.audioMix.gain, .constant(.one))
        XCTAssertEqual(outgoingClip.audioMix.fadeIn, .none)
        XCTAssertEqual(outgoingClip.audioMix.fadeOut, .none)
        XCTAssertEqual(
            outgoingClip.sourceRange,
            try editRange(startFrame: 0, durationFrames: 10)
        )
        XCTAssertEqual(
            incomingClip.timelineRange,
            try editRange(startFrame: 10, durationFrames: 10)
        )
    }
}

private func editableCrossfadeProject(from result: AjarProjectLoadResult) throws -> Project {
    guard case .editable(let project) = result else {
        XCTFail("Expected editable project")
        throw CrossfadeCodecError.expectedEditableProject
    }
    return project
}

private func crossfadeCodecClip(_ clipID: UUID, in project: Project) throws -> Clip {
    let sequence = try XCTUnwrap(project.sequences.first)
    let track = try XCTUnwrap(sequence.audioTracks.first)
    for item in track.items {
        if case .clip(let clip) = item, clip.id == clipID {
            return clip
        }
    }
    throw CrossfadeCodecError.expectedClip
}

/// Simulates a legacy (schema 1) project saved before crossfades existed by removing
/// both crossfade keys from every clip's audio mix payload.
private func crossfadeProjectJSONWithoutCrossfadeKeys(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var audioTracks = try XCTUnwrap(sequence["audioTracks"] as? [[String: Any]])
    var audioTrack = try XCTUnwrap(audioTracks.first)
    var items = try XCTUnwrap(audioTrack["items"] as? [[String: Any]])

    for index in items.indices {
        var clipItem = items[index]
        guard var clipWrapper = clipItem["clip"] as? [String: Any] else {
            continue
        }
        if var clipPayload = clipWrapper["_0"] as? [String: Any] {
            clipPayload = clipPayloadWithoutCrossfadeKeys(clipPayload)
            clipWrapper["_0"] = clipPayload
        } else {
            clipWrapper = clipPayloadWithoutCrossfadeKeys(clipWrapper)
        }
        clipItem["clip"] = clipWrapper
        items[index] = clipItem
    }

    document["schemaVersion"] = 1
    audioTrack["items"] = items
    audioTracks[0] = audioTrack
    sequence["audioTracks"] = audioTracks
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func clipPayloadWithoutCrossfadeKeys(_ payload: [String: Any]) -> [String: Any] {
    var clipPayload = payload
    if var audioMix = clipPayload["audioMix"] as? [String: Any] {
        audioMix.removeValue(forKey: "leadingCrossfade")
        audioMix.removeValue(forKey: "trailingCrossfade")
        clipPayload["audioMix"] = audioMix
    }
    return clipPayload
}

private enum CrossfadeCodecError: Error {
    case expectedEditableProject
    case expectedClip
}
