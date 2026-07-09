// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-002 batch-1 Codable, nested legacy decode, and render-graph eligibility.
final class ClipEffectLibraryFX002CodecGraphTests: XCTestCase {
    func testFRFX002CodableRoundTripForLibraryKinds() throws {
        let nodes = try [
            ClipEffectNode(
                id: editUUID(6_110),
                definition: .gaussianBlur(ClipGaussianBlurParameters(radius: RationalValue(4)))
            ),
            ClipEffectNode(
                id: editUUID(6_111),
                definition: .boxBlur(ClipBoxBlurParameters(radius: RationalValue(3)))
            ),
            ClipEffectNode(
                id: editUUID(6_112),
                definition: .zoomBlur(
                    ClipZoomBlurParameters(
                        amount: try RationalValue(numerator: 2, denominator: 5),
                        centerX: try RationalValue(numerator: 1, denominator: 3),
                        centerY: try RationalValue(numerator: 2, denominator: 3)
                    )
                )
            ),
            ClipEffectNode(
                id: editUUID(6_113),
                definition: .sharpen(
                    ClipSharpenParameters(
                        amount: try RationalValue(numerator: 1, denominator: 2),
                        radius: RationalValue(2)
                    )
                )
            ),
            ClipEffectNode(
                id: editUUID(6_114),
                definition: .glow(
                    ClipGlowParameters(
                        radius: RationalValue(6),
                        amount: try RationalValue(numerator: 1, denominator: 4)
                    )
                )
            )
        ]
        let stack = ClipEffectStack(nodes: nodes)
        let encoded = try JSONEncoder().encode(stack)
        let decoded = try JSONDecoder().decode(ClipEffectStack.self, from: encoded)
        XCTAssertEqual(decoded, stack)
    }

    func testFRFX002NestedCompoundLegacyDecodeForGaussianBlur() throws {
        let ids = try FX002NestedIDs()
        let nestedClip = Clip(
            id: ids.nestedClipID,
            source: .media(id: ids.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Nested blur",
            effectStack: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: ids.nodeID,
                        definition: .gaussianBlur(
                            ClipGaussianBlurParameters(radius: RationalValue(5))
                        )
                    )
                ]
            )
        )
        let project = try makeFX002NestedProject(ids: ids, nestedClip: nestedClip)
        XCTAssertTrue(project.validate().isValid)

        let package = try AjarProjectCodec.encodeNewDocument(project)
        let stripped = try clearGaussianBlurParameters(in: package.projectJSON)
        let loaded = try fx002EditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: stripped,
                mediaJSON: package.mediaJSON
            )
        )
        let nested = try nestedEffectClip(
            nestedClipID: ids.nestedClipID,
            nestedSequenceID: ids.nestedSequenceID,
            in: loaded
        )
        XCTAssertEqual(nested.effectStack.nodes.count, 1)
        XCTAssertEqual(nested.effectStack.nodes[0].kind, .gaussianBlur)
        guard case .gaussianBlur(let parameters) = nested.effectStack.nodes[0].definition else {
            return XCTFail("expected gaussianBlur definition")
        }
        XCTAssertEqual(parameters.radius, .zero)
    }

    func testFRFX002RenderGraphIncludesOrderedEffectStack() throws {
        let mediaID = try editUUID(6_140)
        let firstID = try editUUID(6_142)
        let secondID = try editUUID(6_143)
        let stack = try orderedBlurSharpenStack(firstID: firstID, secondID: secondID)
        let media = try makeFXMediaRef(id: mediaID)
        let clip = try fx002MediaClip(
            id: try editUUID(6_141),
            mediaID: mediaID,
            name: "Ordered stack",
            effectStack: stack
        )
        let sequence = try makeFX002Sequence(
            id: try editUUID(6_144),
            trackID: try editUUID(6_145),
            clip: clip
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try makeFX002Settings(),
            mediaPool: [media],
            sequences: [sequence]
        )
        let graph = try buildRenderGraph(
            for: sequence,
            at: try RationalTime.atFrame(0, frameRate: try FrameRate(frames: 24)),
            in: project
        )
        guard case .composite(let composite) = graph.outputNode?.kind else {
            return XCTFail("expected composite output")
        }
        let resolved = try XCTUnwrap(composite.inputs.first?.effectStack)
        XCTAssertEqual(resolved.nodes.map(\.id), [firstID, secondID])
        XCTAssertEqual(resolved.nodes.map(\.kind), [.gaussianBlur, .sharpen])
        try assertEmptyStackOmitsGraphField(media: media, mediaID: mediaID)
    }
}

private func orderedBlurSharpenStack(firstID: UUID, secondID: UUID) throws -> ClipEffectStack {
    ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: firstID,
                definition: .gaussianBlur(ClipGaussianBlurParameters(radius: RationalValue(2)))
            ),
            ClipEffectNode(
                id: secondID,
                definition: .sharpen(
                    ClipSharpenParameters(
                        amount: try RationalValue(numerator: 1, denominator: 2),
                        radius: .one
                    )
                )
            )
        ]
    )
}

private func assertEmptyStackOmitsGraphField(media: MediaRef, mediaID: UUID) throws {
    let emptyClip = try fx002MediaClip(
        id: try editUUID(6_141),
        mediaID: mediaID,
        name: "Empty stack",
        effectStack: .empty
    )
    let emptySequence = try makeFX002Sequence(
        id: try editUUID(6_146),
        trackID: try editUUID(6_147),
        clip: emptyClip
    )
    let emptyGraph = try buildRenderGraph(
        for: emptySequence,
        at: try RationalTime.atFrame(0, frameRate: try FrameRate(frames: 24)),
        in: Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: try makeFX002Settings(),
            mediaPool: [media],
            sequences: [emptySequence]
        )
    )
    guard case .composite(let emptyComposite) = emptyGraph.outputNode?.kind else {
        return XCTFail("expected composite")
    }
    XCTAssertNil(emptyComposite.inputs.first?.effectStack)
}

private func fx002MediaClip(
    id: UUID,
    mediaID: UUID,
    name: String,
    effectStack: ClipEffectStack
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: name,
        effectStack: effectStack
    )
}
