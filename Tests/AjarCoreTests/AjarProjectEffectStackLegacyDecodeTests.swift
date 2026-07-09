// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-FX-003 project codec coverage: round-trip fidelity and nested legacy decode of a stack
/// living inside a compound clip's nested sequence (the path that has regressed before).
final class AjarProjectEffectStackLegacyDecodeTests: XCTestCase {
    func testFRFX003ProjectCodecRoundTripsEffectStackOnMediaClip() throws {
        let fixture = try makeEditFixture(seed: 5_300)
        let node = ClipEffectNode(
            id: try editUUID(5_300_100),
            enabled: true,
            definition: .placeholder(
                ClipPlaceholderEffectParameters(amount: try rational(3, 10))
            )
        )
        let clip = Clip(
            id: fixture.clipID,
            source: .media(id: fixture.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Stack media",
            effectStack: ClipEffectStack(nodes: [node])
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)
        XCTAssertTrue(project.validate().isValid)

        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loaded = try effectStackEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let loadedClip = try requiredClip(fixture.clipID, in: loaded, fixture: fixture)

        XCTAssertEqual(loadedClip.effectStack.nodes, [node])
        XCTAssertEqual(loadedClip.effectStackAnimation, .constant(loadedClip.effectStack))
        XCTAssertEqual(loaded, project)
    }

    func testFRFX003NestedLegacyCompoundProjectWithoutEffectStackKeysDecodesEmpty() throws {
        // Legacy fixture: parent → compound clip → nested sequence → track → item → clip.
        // Strip effectStack keys everywhere; absent keys must default to empty — nesting has
        // dropped new fields before when only top-level clip decode was tested.
        let nestedProject = try makeNestedCompoundEffectStackProject()
        let package = try AjarProjectCodec.encodeNewDocument(nestedProject)
        let legacyProjectJSON = try projectJSONWithoutKeys(
            ["effectStack", "effectStackAnimation"],
            in: package.projectJSON
        )
        let loaded = try effectStackEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )

        let parentClip = try firstVideoClip(in: loaded.sequences[0])
        XCTAssertEqual(parentClip.effectStack, .empty)
        XCTAssertEqual(parentClip.effectStackAnimation, .empty)

        guard case .sequence(let nestedID) = parentClip.source else {
            XCTFail("Expected compound source")
            return
        }
        let nestedSequence = try XCTUnwrap(loaded.sequences.first { $0.id == nestedID })
        let nestedClip = try firstVideoClip(in: nestedSequence)
        XCTAssertEqual(nestedClip.effectStack, .empty)
        XCTAssertEqual(nestedClip.effectStackAnimation, .empty)
        XCTAssertEqual(nestedClip.effectStackAnimation, .constant(nestedClip.effectStack))
        XCTAssertTrue(loaded.validate().isValid)
    }

    func testFRFX003NestedCompoundRoundTripsEffectStackOnInnerClip() throws {
        let project = try makeNestedCompoundEffectStackProject(withInnerStack: true)
        XCTAssertTrue(project.validate().isValid)

        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loaded = try effectStackEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let parentClip = try firstVideoClip(in: loaded.sequences[0])
        guard case .sequence(let nestedID) = parentClip.source else {
            XCTFail("Expected compound source")
            return
        }
        let nestedSequence = try XCTUnwrap(loaded.sequences.first { $0.id == nestedID })
        let nestedClip = try firstVideoClip(in: nestedSequence)

        XCTAssertEqual(nestedClip.effectStack.nodes.count, 1)
        XCTAssertEqual(nestedClip.effectStack.nodes[0].kind, .placeholder)
        XCTAssertEqual(loaded, project)
    }
}

private func makeNestedCompoundEffectStackProject(
    withInnerStack: Bool = false
) throws -> Project {
    let ids = try NestedCompoundIDs()
    let innerStack = try makeInnerStack(enabled: withInnerStack, nodeID: ids.innerNodeID)
    let nestedClip = Clip(
        id: ids.nestedClipID,
        source: .media(id: ids.mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Inner nested",
        effectStack: innerStack
    )
    let nestedSequence = Sequence(
        id: ids.nestedSequenceID,
        name: "Nested",
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
        name: "Compound outer"
    )
    let parentSequence = Sequence(
        id: ids.parentSequenceID,
        name: "Parent",
        videoTracks: [
            Track(id: ids.parentTrackID, kind: .video, items: [.clip(parentClip)])
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
        mediaPool: [try makeEditMediaRef(id: ids.mediaID)],
        sequences: [parentSequence, nestedSequence]
    )
}

private struct NestedCompoundIDs {
    let mediaID: UUID
    let nestedSequenceID: UUID
    let nestedTrackID: UUID
    let nestedClipID: UUID
    let parentSequenceID: UUID
    let parentTrackID: UUID
    let parentClipID: UUID
    let innerNodeID: UUID

    init() throws {
        mediaID = try editUUID(5_310_001)
        nestedSequenceID = try editUUID(5_310_002)
        nestedTrackID = try editUUID(5_310_003)
        nestedClipID = try editUUID(5_310_004)
        parentSequenceID = try editUUID(5_310_005)
        parentTrackID = try editUUID(5_310_006)
        parentClipID = try editUUID(5_310_007)
        innerNodeID = try editUUID(5_310_100)
    }
}

private func makeInnerStack(enabled: Bool, nodeID: UUID) throws -> ClipEffectStack {
    guard enabled else {
        return .empty
    }
    return ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: nodeID,
                definition: .placeholder(
                    ClipPlaceholderEffectParameters(amount: try rational(2, 5))
                )
            )
        ]
    )
}

private func firstVideoClip(in sequence: Sequence) throws -> Clip {
    let track = try XCTUnwrap(sequence.videoTracks.first)
    guard case .clip(let clip) = track.items.first else {
        XCTFail("Expected clip item")
        throw AjarProjectCodecError.malformedProjectJSON("missing clip")
    }
    return clip
}

private func effectStackEditableProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        XCTFail("Expected editable project")
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

private func projectJSONWithoutKeys(_ keys: [String], in data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let stripped = try strippingKeys(Set(keys), from: object)
    return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
}

private func strippingKeys(_ keys: Set<String>, from value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        for key in keys {
            dictionary.removeValue(forKey: key)
        }
        for (nestedKey, nested) in dictionary {
            dictionary[nestedKey] = try strippingKeys(keys, from: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try strippingKeys(keys, from: $0) }
    }
    return value
}
