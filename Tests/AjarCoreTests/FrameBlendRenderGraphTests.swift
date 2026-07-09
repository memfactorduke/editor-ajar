// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-004 render graph coverage: sampling-mode threading into source nodes, byte-identical
/// content-hash back-compat for the default nearest mode, cache invalidation when the mode
/// changes, and compound-nested propagation.
final class FrameBlendRenderGraphTests: XCTestCase {
    func testFRSPD004BuilderThreadsFrameBlendModeIntoSourceNode() throws {
        let project = try makeBlendProject(seed: 4_600, frameSampling: .frameBlend)
        let graph = try buildGraph(project, at: try editTime(3))

        XCTAssertEqual(try sourcePayload(in: graph).frameSampling, .frameBlend)
        XCTAssertEqual(try sourcePayload(in: graph).resolvedFrameSampling, .frameBlend)
    }

    func testFRSPD004NearestModeMapsToNilSourceNodeField() throws {
        // Both the implicit default and an explicit `.nearest` fold to `nil` on the node, so
        // toggling a clip back to nearest restores the pre-FR-SPD-004 cache identity.
        let defaulted = try makeBlendProject(seed: 4_601, frameSampling: .nearest)
        let graph = try buildGraph(defaulted, at: try editTime(3))

        XCTAssertNil(try sourcePayload(in: graph).frameSampling)
        XCTAssertEqual(try sourcePayload(in: graph).resolvedFrameSampling, .nearest)
    }

    func testADR0009FRSPD004NearestHashIsByteIdenticalToLegacyProjectGraph() throws {
        // Round-trip the project through the codec, strip every `frameSampling` key to fake a
        // pre-FR-SPD-004 file, and prove the rebuilt graph carries the same content hashes.
        let project = try makeBlendProject(seed: 4_602, frameSampling: .nearest)
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let legacyJSON = try projectJSONWithoutFrameSamplingKey(package.projectJSON)
        let legacyProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyJSON,
                mediaJSON: package.mediaJSON
            )
        )

        let graph = try buildGraph(project, at: try editTime(3))
        let legacyGraph = try buildGraph(legacyProject, at: try editTime(3))

        XCTAssertEqual(
            try sourceRenderNode(in: graph).contentHash,
            try sourceRenderNode(in: legacyGraph).contentHash
        )
        XCTAssertEqual(graph.outputNode?.contentHash, legacyGraph.outputNode?.contentHash)

        // Byte-level proof: the sorted-keys hash payload encoding of a nearest source node
        // omits the optional key entirely, so the SHA-256 input is unchanged.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(try sourcePayload(in: graph))
        let legacyEncoded = try encoder.encode(try sourcePayload(in: legacyGraph))
        XCTAssertEqual(encoded, legacyEncoded)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("frameSampling"))
    }

    func testADR0009FRSPD004FrameBlendModeInvalidatesSourceAndCompositeHashes() throws {
        let nearest = try buildGraph(
            try makeBlendProject(seed: 4_603, frameSampling: .nearest),
            at: try editTime(3)
        )
        let blended = try buildGraph(
            try makeBlendProject(seed: 4_603, frameSampling: .frameBlend),
            at: try editTime(3)
        )

        XCTAssertEqual(
            try sourcePayload(in: nearest).sourceTime,
            try sourcePayload(in: blended).sourceTime
        )
        XCTAssertNotEqual(
            try sourceRenderNode(in: nearest).contentHash,
            try sourceRenderNode(in: blended).contentHash
        )
        XCTAssertNotEqual(nearest.outputNode?.contentHash, blended.outputNode?.contentHash)
    }

    func testFRSPD004CompoundNestingPropagatesInnerClipSamplingMode() throws {
        // FR-SPD-004 x compound: a frame-blend media clip nested inside a compound sequence
        // carries its mode through the nested graph the executor renders recursively.
        let project = try makeCompoundBlendProject()
        let outerSequence = try XCTUnwrap(project.sequences.first)

        let graph = try buildRenderGraph(for: outerSequence, at: try editTime(3), in: project)
        let compoundNode = try XCTUnwrap(
            graph.nodes.first { node in
                if case .compound = node.kind {
                    return true
                }
                return false
            }
        )
        guard case .compound(let payload) = compoundNode.kind else {
            return XCTFail("Expected compound node payload")
        }

        let nestedSource = try sourcePayload(in: payload.graph)
        XCTAssertEqual(nestedSource.frameSampling, .frameBlend)
        // Odd outer frame through the nested 1/2x clip resolves a fractional source position.
        XCTAssertEqual(nestedSource.sourceTime, try RationalTime(value: 3, timescale: 48))
    }

    /// Builds a project whose first sequence wraps a nested sequence holding a single 1/2x
    /// frame-blend media clip.
    private func makeCompoundBlendProject() throws -> Project {
        let mediaID = try editUUID(4_604_001)
        let media = try makeEditMediaRef(id: mediaID)
        let innerClip = Clip(
            id: try editUUID(4_604_002),
            source: .media(id: mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 20),
            kind: .video,
            name: "FR-SPD-004 nested blend clip",
            speed: try RationalValue(numerator: 1, denominator: 2),
            frameSampling: .frameBlend
        )
        let nestedSequence = Sequence(
            id: try editUUID(4_604_003),
            name: "FR-SPD-004 nested sequence",
            videoTracks: [
                Track(id: try editUUID(4_604_004), kind: .video, items: [.clip(innerClip)])
            ],
            audioTracks: [],
            markers: [],
            timebase: try FrameRate(frames: 24)
        )
        let compoundClip = Clip(
            id: try editUUID(4_604_005),
            source: .sequence(id: nestedSequence.id),
            sourceRange: try editRange(startFrame: 0, durationFrames: 20),
            timelineRange: try editRange(startFrame: 0, durationFrames: 20),
            kind: .video,
            name: "FR-SPD-004 compound clip"
        )
        let outerSequence = Sequence(
            id: try editUUID(4_604_006),
            name: "FR-SPD-004 outer sequence",
            videoTracks: [
                Track(id: try editUUID(4_604_007), kind: .video, items: [.clip(compoundClip)])
            ],
            audioTracks: [],
            markers: [],
            timebase: try FrameRate(frames: 24)
        )
        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try makeBlendSettings(),
            mediaPool: [media],
            sequences: [outerSequence, nestedSequence]
        )
    }

    private func makeBlendProject(
        seed: Int,
        frameSampling: ClipFrameSamplingMode
    ) throws -> Project {
        let base = seed * 1_000
        let mediaID = try editUUID(base + 1)
        let media = try makeEditMediaRef(id: mediaID)
        let clip = Clip(
            id: try editUUID(base + 2),
            source: .media(id: mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 20),
            kind: .video,
            name: "FR-SPD-004 graph clip \(seed)",
            speed: try RationalValue(numerator: 1, denominator: 2),
            frameSampling: frameSampling
        )
        let sequence = Sequence(
            id: try editUUID(base + 3),
            name: "FR-SPD-004 graph sequence \(seed)",
            videoTracks: [Track(id: try editUUID(base + 4), kind: .video, items: [.clip(clip)])],
            audioTracks: [],
            markers: [],
            timebase: try FrameRate(frames: 24)
        )
        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try makeBlendSettings(),
            mediaPool: [media],
            sequences: [sequence]
        )
    }

    private func makeBlendSettings() throws -> ProjectSettings {
        ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        )
    }

    private func buildGraph(_ project: Project, at time: RationalTime) throws -> RenderGraph {
        let sequence = try XCTUnwrap(project.sequences.first)
        return try buildRenderGraph(for: sequence, at: time, in: project)
    }
}

private func sourceRenderNode(in graph: RenderGraph) throws -> RenderNode {
    try XCTUnwrap(
        graph.nodes.first { node in
            if case .source = node.kind {
                return true
            }
            return false
        }
    )
}

private func sourcePayload(in graph: RenderGraph) throws -> RenderSourceNode {
    guard case .source(let payload) = try sourceRenderNode(in: graph).kind else {
        XCTFail("Expected source node payload")
        throw RenderGraphBuildError.contentHashEncodingFailed("missing source payload")
    }
    return payload
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

private func projectJSONWithoutFrameSamplingKey(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let stripped = try stripFrameSampling(from: object)
    return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
}

private func stripFrameSampling(from value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        dictionary.removeValue(forKey: "frameSampling")
        for (key, nested) in dictionary {
            dictionary[key] = try stripFrameSampling(from: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try stripFrameSampling(from: $0) }
    }
    return value
}
