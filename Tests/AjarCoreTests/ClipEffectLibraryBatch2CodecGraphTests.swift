// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-002 batch-2 typed codec and render-graph round-trip coverage.
final class ClipEffectLibraryBatch2CodecGraphTests: XCTestCase {
    func testFRFX002Batch2TypedStackCodableRoundTrip() throws {
        let stack = try representativeBatch2Stack()
        let encoded = try JSONEncoder().encode(stack)
        XCTAssertEqual(try JSONDecoder().decode(ClipEffectStack.self, from: encoded), stack)
    }

    func testFRFX002Batch2RenderGraphRoundTripPreservesKindsOrderAndParameters() throws {
        let expected = try representativeBatch2Stack()
        let graph = try batch2RenderGraph(stack: expected)
        let encoded = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(RenderGraph.self, from: encoded)
        guard case .composite(let composite) = decoded.outputNode?.kind else {
            return XCTFail("expected composite graph output")
        }
        let carried = try XCTUnwrap(composite.inputs.first?.effectStack)
        XCTAssertEqual(carried, expected)
        XCTAssertEqual(
            carried.nodes.map(\.kind),
            [.vignette, .mirror, .mosaic, .colorAdjust, .posterize, .invert]
        )
    }
}

private func representativeBatch2Stack() throws -> ClipEffectStack {
    ClipEffectStack(nodes: [
        ClipEffectNode(
            id: try editUUID(6_320),
            definition: .vignette(
                ClipVignetteParameters(
                    amount: try RationalValue(numerator: 3, denominator: 4),
                    radius: try RationalValue(numerator: 1, denominator: 2),
                    softness: try RationalValue(numerator: 1, denominator: 4)
                )
            )
        ),
        ClipEffectNode(
            id: try editUUID(6_321),
            definition: .mirror(ClipMirrorParameters(axis: .quad))
        ),
        ClipEffectNode(
            id: try editUUID(6_322),
            definition: .mosaic(ClipMosaicParameters(cellSize: RationalValue(12)))
        ),
        ClipEffectNode(
            id: try editUUID(6_323),
            definition: .colorAdjust(
                ClipColorAdjustParameters(
                    brightness: try RationalValue(numerator: 1, denominator: 10),
                    contrast: try RationalValue(numerator: 6, denominator: 5),
                    saturation: try RationalValue(numerator: 4, denominator: 5),
                    tint: try RationalValue(numerator: 1, denominator: 5)
                )
            )
        ),
        ClipEffectNode(
            id: try editUUID(6_324),
            definition: .posterize(ClipPosterizeParameters(levels: RationalValue(4)))
        ),
        ClipEffectNode(
            id: try editUUID(6_325),
            definition: .invert(ClipInvertParameters())
        )
    ])
}

private func batch2RenderGraph(stack: ClipEffectStack) throws -> RenderGraph {
    let mediaID = try editUUID(6_330)
    let media = try makeFXMediaRef(id: mediaID)
    let clip = Clip(
        id: try editUUID(6_331),
        source: .media(id: mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Batch 2 graph",
        effectStack: stack
    )
    let sequence = try makeFX002Sequence(
        id: try editUUID(6_332),
        trackID: try editUUID(6_333),
        clip: clip
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try makeFX002Settings(),
        mediaPool: [media],
        sequences: [sequence]
    )
    return try buildRenderGraph(
        for: sequence,
        at: try RationalTime.atFrame(0, frameRate: sequence.timebase),
        in: project
    )
}
