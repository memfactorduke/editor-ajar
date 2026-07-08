// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-004 project codec coverage: round-trip fidelity, nested legacy decode of full project
/// JSON that predates the `frameSampling` key, and edit preservation through blade splits.
final class AjarProjectFrameSamplingCodecTests: XCTestCase {
    func testFRSPD004ProjectCodecRoundTripsFrameBlendMode() throws {
        let fixture = try makeEditFixture(seed: 4_610)
        let blendClip = try makeFrameBlendClip(fixture: fixture, seed: 4_610_005)
        let blendProject = try replacingVideoItems([.clip(blendClip)], in: fixture)
        XCTAssertTrue(blendProject.validate().isValid)

        let package = try AjarProjectCodec.encode(blendProject)
        let loaded = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let loadedClip = try requiredClip(blendClip.id, in: loaded, fixture: fixture)

        XCTAssertEqual(loadedClip.frameSampling, .frameBlend)
        XCTAssertEqual(loaded, blendProject)
    }

    func testFRSPD004NestedLegacyProjectJSONWithoutFrameSamplingKeyDecodesToNearest() throws {
        // The legacy fixture nests the clip inside sequence -> track -> item JSON, so this
        // exercises the full project codec path rather than a bare `Clip` decode.
        let fixture = try makeEditFixture(seed: 4_611)
        let package = try AjarProjectCodec.encode(fixture.project)
        let legacyProjectJSON = try projectJSONWithoutKey("frameSampling", in: package.projectJSON)
        let legacyLoaded = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let legacyClip = try requiredClip(fixture.clipID, in: legacyLoaded, fixture: fixture)

        XCTAssertEqual(legacyClip.frameSampling, .nearest)
        XCTAssertTrue(legacyLoaded.validate().isValid)
    }

    func testFRSPD004FrameSamplingSurvivesClipCodableRoundTrip() throws {
        let fixture = try makeEditFixture(seed: 4_612)
        let clip = try makeFrameBlendClip(fixture: fixture, seed: 4_612_005)

        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))

        XCTAssertEqual(decoded, clip)
        XCTAssertEqual(decoded.frameSampling, .frameBlend)
    }

    func testFRSPD004BladeSplitPreservesFrameSamplingOnBothHalves() throws {
        // FR-SPD-004 x edits: both blade halves (the `copying` left half and the directly
        // constructed right half) must keep the opt-in sampling mode.
        let fixture = try makeEditFixture(seed: 4_613)
        let blendClip = try makeFrameBlendClip(fixture: fixture, seed: 4_613_005)
        let project = try replacingVideoItems([.clip(blendClip)], in: fixture)
        let rightClipID = try editUUID(4_613_009)

        let bladed = try apply(
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: blendClip.id,
                atTime: try editTime(4),
                rightClipID: rightClipID
            ),
            to: project
        )

        let leftClip = try requiredClip(blendClip.id, in: bladed, fixture: fixture)
        let rightClip = try requiredClip(rightClipID, in: bladed, fixture: fixture)
        XCTAssertEqual(leftClip.frameSampling, .frameBlend)
        XCTAssertEqual(rightClip.frameSampling, .frameBlend)
    }

    private func makeFrameBlendClip(fixture: EditFixture, seed: Int) throws -> Clip {
        Clip(
            id: try editUUID(seed),
            source: .media(id: fixture.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 20),
            kind: .video,
            name: "FR-SPD-004 codec clip \(seed)",
            speed: try RationalValue(numerator: 1, denominator: 2),
            frameSampling: .frameBlend
        )
    }
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

private func projectJSONWithoutKey(_ key: String, in data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let stripped = try strippingKey(key, from: object)
    return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
}

private func strippingKey(_ key: String, from value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        dictionary.removeValue(forKey: key)
        for (nestedKey, nested) in dictionary {
            dictionary[nestedKey] = try strippingKey(key, from: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try strippingKey(key, from: $0) }
    }
    return value
}
