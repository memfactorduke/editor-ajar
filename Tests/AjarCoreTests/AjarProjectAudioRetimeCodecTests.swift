// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-001 project codec coverage for the clip audio retime mode: round-trip fidelity and
/// nested legacy decode of full project JSON that predates the `retimeMode` key.
final class AjarProjectAudioRetimeCodecTests: XCTestCase {
    func testFRSPD001ProjectCodecRoundTripsPitchCorrectedRetimeMode() throws {
        let fixture = try makeLinkedEditFixture(seed: 4_370)
        let project = try pitchCorrectedProject(fixture: fixture)
        XCTAssertTrue(project.validate().isValid)

        let package = try AjarProjectCodec.encode(project)
        let loaded = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let loadedClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: loaded,
            sequenceID: fixture.sequenceID
        )

        XCTAssertEqual(loadedClip.audioMix.retimeMode, .pitchCorrected)
        XCTAssertEqual(loaded, project)
    }

    func testFRSPD001NestedLegacyProjectJSONWithoutRetimeModeKeyDecodesToPitchShifted() throws {
        // The legacy fixture nests the clip inside sequence -> track -> item -> audioMix JSON,
        // so this exercises the full project codec path rather than a bare `ClipAudioMix`
        // decode. Absent key = pitchShifted: the exact legacy varispeed behavior.
        let fixture = try makeLinkedEditFixture(seed: 4_371)
        let package = try AjarProjectCodec.encode(fixture.project)
        let legacyProjectJSON = try projectJSONWithoutRetimeModeKey(package.projectJSON)
        let legacyLoaded = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let legacyClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: legacyLoaded,
            sequenceID: fixture.sequenceID
        )

        XCTAssertEqual(legacyClip.audioMix.retimeMode, .pitchShifted)
        XCTAssertEqual(legacyLoaded, fixture.project)
        XCTAssertTrue(legacyLoaded.validate().isValid)
    }

    func testFRSPD001RetimeModeSurvivesClipCodableRoundTrip() throws {
        let clip = try makeEditClip(
            id: editUUID(4_372_001),
            mediaID: try editUUID(4_372_002),
            startFrame: 0,
            kind: .audio,
            audioMix: ClipAudioMix(retimeMode: .pitchCorrected),
            speed: try RationalValue(numerator: 2, denominator: 1)
        )

        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))

        XCTAssertEqual(decoded, clip)
        XCTAssertEqual(decoded.audioMix.retimeMode, .pitchCorrected)
    }

    func testFRSPD001PitchCorrectedRejectsFreezeFrameAndTimeRemapInValidation() throws {
        let fixture = try makeLinkedEditFixture(seed: 4_373)
        let freezeClip = try makeEditClip(
            id: fixture.audioClipID,
            mediaID: fixture.mediaID,
            startFrame: 0,
            kind: .audio,
            audioMix: ClipAudioMix(retimeMode: .pitchCorrected),
            freezeFrame: true
        )
        let freezeProject = try replacingAudioItems([.clip(freezeClip)], in: fixture)

        guard case .invalid(let errors) = freezeProject.validate() else {
            XCTFail("Expected pitchCorrected + freezeFrame to fail validation")
            return
        }
        XCTAssertTrue(errors.contains(
            .invalidClipAudioRetime(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                error: .pitchCorrectedConflictsWithFreezeFrame
            )
        ))

        // Reverse composes: the WSOLA stage stretches the reversed stream (FR-SPD-003).
        let reverseClip = try makeEditClip(
            id: fixture.audioClipID,
            mediaID: fixture.mediaID,
            startFrame: 0,
            kind: .audio,
            audioMix: ClipAudioMix(retimeMode: .pitchCorrected),
            reverse: true
        )
        let reverseProject = try replacingAudioItems([.clip(reverseClip)], in: fixture)
        XCTAssertTrue(reverseProject.validate().isValid)
    }
}

private func pitchCorrectedProject(fixture: LinkedEditFixture) throws -> Project {
    let clip = try makeEditClip(
        id: fixture.audioClipID,
        mediaID: fixture.mediaID,
        startFrame: 0,
        kind: .audio,
        audioMix: ClipAudioMix(retimeMode: .pitchCorrected),
        speed: try RationalValue(numerator: 2, denominator: 1)
    )
    return try replacingAudioItems([.clip(clip)], in: fixture)
}

private func replacingAudioItems(
    _ items: [TimelineItem],
    in fixture: LinkedEditFixture
) throws -> Project {
    let project = fixture.project
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })
    let audioTracks = sequence.audioTracks.map { track in
        track.id == fixture.audioTrackID
            ? Track(id: track.id, kind: track.kind, items: items)
            : track
    }
    let videoTracks = sequence.videoTracks.map { track in
        track.id == fixture.videoTrackID
            ? Track(id: track.id, kind: track.kind, items: [])
            : track
    }
    let replacementSequence = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: videoTracks,
        audioTracks: audioTracks,
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

private func editableProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        XCTFail("Expected editable project")
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

private func projectJSONWithoutRetimeModeKey(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let stripped = try stripRetimeMode(from: object)
    return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
}

private func stripRetimeMode(from value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        dictionary.removeValue(forKey: "retimeMode")
        for (key, nested) in dictionary {
            dictionary[key] = try stripRetimeMode(from: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try stripRetimeMode(from: $0) }
    }
    return value
}
