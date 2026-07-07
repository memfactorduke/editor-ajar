// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-002 project codec coverage: round-trip fidelity and nested legacy decode of full
/// project JSON that predates the `timeRemap` key.
final class AjarProjectTimeRemapCodecTests: XCTestCase {
    func testFRSPD002ProjectCodecRoundTripsTimeRemapCurve() throws {
        let fixture = try makeEditFixture(seed: 4_360)
        let curve = try rampCurve()
        let remapClip = try makeRemapClip(
            clipSeed: 4_360_005,
            curve: curve,
            sourceDurationFrames: 36,
            mediaID: fixture.mediaID
        )
        let remapProject = try replacingVideoItems([.clip(remapClip)], in: fixture)
        XCTAssertTrue(remapProject.validate().isValid)

        let package = try AjarProjectCodec.encode(remapProject)
        let loaded = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let loadedClip = try requiredClip(remapClip.id, in: loaded, fixture: fixture)

        XCTAssertEqual(loadedClip.timeRemap, curve)
        XCTAssertEqual(loaded, remapProject)
        XCTAssertEqual(
            try loadedClip.sourceTime(at: try editTime(28)),
            try editTime(24)
        )
    }

    func testFRSPD002NestedLegacyProjectJSONWithoutTimeRemapKeyDecodesToConstantSpeed() throws {
        // The legacy fixture nests the clip inside sequence -> track -> item JSON, so this
        // exercises the full project codec path rather than a bare `Clip` decode.
        let fixture = try makeEditFixture(seed: 4_361)
        let package = try AjarProjectCodec.encode(fixture.project)
        let legacyProjectJSON = try projectJSONWithoutTimeRemapKey(package.projectJSON)
        let legacyLoaded = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let legacyClip = try requiredClip(fixture.clipID, in: legacyLoaded, fixture: fixture)

        XCTAssertNil(legacyClip.timeRemap)
        XCTAssertEqual(legacyClip.speed, .one)
        // Constant-speed behavior: identity mapping for a 1x clip starting at zero.
        XCTAssertEqual(try legacyClip.sourceTime(at: try editTime(4)), try editTime(4))
        XCTAssertTrue(legacyLoaded.validate().isValid)
    }

    func testFRSPD002TimeRemapKeyframeListSurvivesClipCodableRoundTrip() throws {
        let curve = try ClipTimeRemap(keyframes: [
            try remapKeyframe(0, 0),
            try remapKeyframe(6, 6),
            try remapKeyframe(18, 6),
            try remapKeyframe(24, 12)
        ])
        let clip = try makeRemapClip(
            clipSeed: 4_362,
            curve: curve,
            sourceDurationFrames: 12
        )

        let decoded = try JSONDecoder().decode(
            Clip.self,
            from: JSONEncoder().encode(clip)
        )

        XCTAssertEqual(decoded, clip)
        XCTAssertEqual(decoded.timeRemap?.keyframes.count, 4)
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

private func projectJSONWithoutTimeRemapKey(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let stripped = try stripTimeRemap(from: object)
    return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
}

private func stripTimeRemap(from value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        dictionary.removeValue(forKey: "timeRemap")
        for (key, nested) in dictionary {
            dictionary[key] = try stripTimeRemap(from: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try stripTimeRemap(from: $0) }
    }
    return value
}
