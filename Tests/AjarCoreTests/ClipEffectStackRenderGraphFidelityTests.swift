// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-002 / NFR-QUAL-001: library effect parameters must survive render-graph construction
/// and Codable round-trip bit-identically. A silent `decodeIfPresent` → identity default
/// (e.g. sharpen amount → 0) makes the GPU path a pixel-exact no-op.
final class ClipEffectStackRenderGraphFidelityTests: XCTestCase {
    func testFRFX002NFRQUAL001EveryKindSurvivesRenderGraphCarryAndCodableRoundTrip() throws {
        let cases = try nonIdentityDefinitionsByKind()
        XCTAssertEqual(
            Set(cases.map(\.kind)),
            Set(ClipEffectKind.allCases),
            "test must cover every ClipEffectKind"
        )

        for entry in cases {
            let (liveStack, roundTrippedStack) = try graphStacks(for: entry.definition)
            let liveNode = try XCTUnwrap(liveStack.nodes.first)
            let roundTrippedNode = try XCTUnwrap(roundTrippedStack.nodes.first)

            XCTAssertEqual(
                liveNode.definition,
                entry.definition,
                "live graph dropped/mutated parameters for \(entry.kind.rawValue)"
            )
            XCTAssertEqual(
                liveNode.definition.kind,
                entry.kind,
                "live graph kind mismatch for \(entry.kind.rawValue)"
            )
            XCTAssertEqual(
                roundTrippedNode.definition,
                entry.definition,
                """
                Codable round-trip of render graph mutated parameters for \(entry.kind.rawValue). \
                Live: \(String(describing: liveNode.definition)) \
                Round-tripped: \(String(describing: roundTrippedNode.definition))
                """
            )
            XCTAssertNotEqual(
                entry.definition,
                ClipEffectDefinition.identity(for: entry.kind),
                "fixture for \(entry.kind.rawValue) must be non-identity"
            )
        }
    }

    func testFRFX002NFRQUAL001ClipEffectDefinitionCodableRoundTripPreservesAllKinds() throws {
        for entry in try nonIdentityDefinitionsByKind() {
            let encoded = try JSONEncoder().encode(entry.definition)
            let decoded = try JSONDecoder().decode(ClipEffectDefinition.self, from: encoded)
            XCTAssertEqual(
                decoded,
                entry.definition,
                """
                ClipEffectDefinition Codable mismatch for \(entry.kind.rawValue). \
                JSON: \(String(data: encoded, encoding: .utf8) ?? "<binary>")
                """
            )
        }
    }
}

// MARK: - Fixtures

private struct KindDefinition {
    let kind: ClipEffectKind
    let definition: ClipEffectDefinition
}

private func nonIdentityDefinitionsByKind() throws -> [KindDefinition] {
    [
        KindDefinition(
            kind: .placeholder,
            definition: .placeholder(
                ClipPlaceholderEffectParameters(
                    amount: try RationalValue(numerator: 3, denominator: 5)
                )
            )
        ),
        KindDefinition(
            kind: .gaussianBlur,
            definition: .gaussianBlur(ClipGaussianBlurParameters(radius: RationalValue(4)))
        ),
        KindDefinition(
            kind: .boxBlur,
            definition: .boxBlur(ClipBoxBlurParameters(radius: RationalValue(4)))
        ),
        KindDefinition(
            kind: .zoomBlur,
            definition: .zoomBlur(
                ClipZoomBlurParameters(
                    amount: try RationalValue(numerator: 1, denominator: 2),
                    centerX: RationalValue.approximating(0.5),
                    centerY: RationalValue.approximating(0.5)
                )
            )
        ),
        KindDefinition(
            kind: .sharpen,
            definition: .sharpen(
                ClipSharpenParameters(
                    amount: try RationalValue(numerator: 1, denominator: 2),
                    radius: RationalValue(1)
                )
            )
        ),
        KindDefinition(
            kind: .glow,
            definition: .glow(
                ClipGlowParameters(
                    radius: RationalValue(4),
                    amount: try RationalValue(numerator: 1, denominator: 2)
                )
            )
        )
    ]
}

/// Builds a project/graph for `definition` and returns (live carried stack, Codable round-tripped).
private func graphStacks(
    for definition: ClipEffectDefinition
) throws -> (ClipEffectStack, ClipEffectStack) {
    let project = try fidelityProject(definition: definition)
    let sequence = try XCTUnwrap(project.sequences.first)
    let frameRate = project.settings.frameRate
    let graph = try buildRenderGraph(
        for: sequence,
        at: try RationalTime.atFrame(0, frameRate: frameRate),
        in: project
    )
    let liveStack = try carriedEffectStack(in: graph)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(graph)
    let decodedGraph = try JSONDecoder().decode(RenderGraph.self, from: encoded)
    let roundTrippedStack = try carriedEffectStack(in: decodedGraph)
    return (liveStack, roundTrippedStack)
}

private func fidelityProject(definition: ClipEffectDefinition) throws -> Project {
    let mediaID = try fidelityUUID(7_001)
    let clipID = try fidelityUUID(7_002)
    let nodeID = try fidelityUUID(7_003)
    let stack = ClipEffectStack(
        nodes: [ClipEffectNode(id: nodeID, enabled: true, definition: definition)]
    )
    let frameRate = try FrameRate(frames: 24)
    let duration = try RationalTime.atFrame(24, frameRate: frameRate)
    let media = MediaRef(
        id: mediaID,
        sourceURL: URL(fileURLWithPath: "/media/effect-fidelity.mov"),
        contentHash: ContentHash.sha256(data: Data(mediaID.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 96, height: 96),
            frameRate: frameRate,
            duration: duration,
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(start: .zero, duration: duration),
        kind: .video,
        name: "Effect fidelity \(definition.kind.rawValue)",
        effectStack: stack
    )
    let sequence = Sequence(
        id: try fidelityUUID(7_004),
        name: "Effect fidelity",
        videoTracks: [
            Track(id: try fidelityUUID(7_005), kind: .video, items: [.clip(clip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: frameRate
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: frameRate,
            resolution: PixelDimensions(width: 96, height: 96),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [media],
        sequences: [sequence]
    )
}

private func carriedEffectStack(in graph: RenderGraph) throws -> ClipEffectStack {
    guard case .composite(let composite) = graph.outputNode?.kind else {
        throw NSError(
            domain: "ClipEffectStackRenderGraphFidelityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "missing composite output"]
        )
    }
    let input = try XCTUnwrap(composite.inputs.first)
    return try XCTUnwrap(
        input.effectStack,
        "effect stack was omitted from the graph (empty stacks are nil — fixture must be non-empty)"
    )
}

private func fidelityUUID(_ value: Int) throws -> UUID {
    let string = String(format: "00000000-0000-0000-0000-%012d", value)
    guard let uuid = UUID(uuidString: string) else {
        throw NSError(
            domain: "ClipEffectStackRenderGraphFidelityTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "invalid uuid \(value)"]
        )
    }
    return uuid
}
