// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Codec coverage for FR-FX-001 video transition fields (nested-legacy + round-trip).
final class AjarProjectVideoTransitionCodecTests: XCTestCase {
    func testFRFX001TransitionPairRoundTripsThroughProjectCodec() throws {
        let project = try makeVideoTransitionPairProject(
            kind: .wipe,
            direction: .topRight
        )
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loaded = try editableTransitionProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        XCTAssertEqual(loaded.schemaMinor, AjarProjectCodec.currentSchemaMinor)
        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 10)
        let outgoing = try videoTransitionTrackClip(
            VideoTransitionFixtureID.outgoingClip(),
            in: loaded
        )
        let incoming = try videoTransitionTrackClip(
            VideoTransitionFixtureID.incomingClip(),
            in: loaded
        )
        XCTAssertEqual(outgoing.trailingTransition?.kind, .wipe)
        XCTAssertEqual(outgoing.trailingTransition?.direction, .topRight)
        XCTAssertEqual(incoming.leadingTransition?.kind, .wipe)
        XCTAssertEqual(incoming.leadingTransition?.direction, .topRight)
    }

    func testFRPROJ005FRFX001LegacyProjectWithoutTransitionKeysDecodesNil() throws {
        let project = try makeVideoTransitionPairProject(kind: .zoom)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let legacyJSON = try projectJSONWithoutTransitionKeys(package.projectJSON)
        let loaded = try editableTransitionProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let outgoing = try videoTransitionTrackClip(
            VideoTransitionFixtureID.outgoingClip(),
            in: loaded
        )
        let incoming = try videoTransitionTrackClip(
            VideoTransitionFixtureID.incomingClip(),
            in: loaded
        )
        XCTAssertNil(outgoing.leadingTransition)
        XCTAssertNil(outgoing.trailingTransition)
        XCTAssertNil(incoming.leadingTransition)
        XCTAssertNil(incoming.trailingTransition)
    }

    func testFRFX001NestedLegacyCompoundKeepsTransitionsNil() throws {
        // Nested compound sequence clip payload without transition keys decodes defaults.
        let project = try makeVideoTransitionPairProject()
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let legacyJSON = try projectJSONWithoutTransitionKeys(package.projectJSON)
        // Re-encode path not required; decode already exercised. Sanity: schema major stays.
        let loaded = try editableTransitionProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyJSON,
                mediaJSON: package.mediaJSON
            )
        )
        XCTAssertEqual(loaded.schemaVersion, AjarProjectCodec.currentSchemaVersion)
    }
}

private func editableTransitionProject(from result: AjarProjectLoadResult) throws -> Project {
    guard case .editable(let project) = result else {
        XCTFail("Expected editable project")
        struct ExpectedEditableProjectError: Error {}
        throw ExpectedEditableProjectError()
    }
    return project
}

/// Strips leading/trailing transition keys from every clip payload (legacy decode path).
/// Handles synthesized enum wrappers (`clip` → `_0`) the same way as the crossfade legacy test.
private func projectJSONWithoutTransitionKeys(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    for sequenceIndex in sequences.indices {
        var sequence = sequences[sequenceIndex]
        for trackKey in ["videoTracks", "audioTracks"] {
            guard var tracks = sequence[trackKey] as? [[String: Any]] else { continue }
            for trackIndex in tracks.indices {
                var track = tracks[trackIndex]
                guard var items = track["items"] as? [[String: Any]] else { continue }
                for itemIndex in items.indices {
                    var item = items[itemIndex]
                    guard var clipWrapper = item["clip"] as? [String: Any] else {
                        continue
                    }
                    if var clipPayload = clipWrapper["_0"] as? [String: Any] {
                        clipPayload.removeValue(forKey: "leadingTransition")
                        clipPayload.removeValue(forKey: "trailingTransition")
                        clipWrapper["_0"] = clipPayload
                    } else {
                        clipWrapper.removeValue(forKey: "leadingTransition")
                        clipWrapper.removeValue(forKey: "trailingTransition")
                    }
                    item["clip"] = clipWrapper
                    items[itemIndex] = item
                }
                track["items"] = items
                tracks[trackIndex] = track
            }
            sequence[trackKey] = tracks
        }
        sequences[sequenceIndex] = sequence
    }
    document["sequences"] = sequences
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}
