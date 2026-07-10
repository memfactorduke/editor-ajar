// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-FX-001 render-graph round-trip for every transition kind (fade-tail + progress).
final class VideoTransitionRenderGraphTests: XCTestCase {
    func testFRFX001AllKindsEmitTransitionNodeAtMidProgress() throws {
        let kinds: [(ClipVideoTransitionKind, ClipVideoTransitionDirection)] = [
            (.crossDissolve, .left),
            (.dipToColor, .left),
            (.fade, .left),
            (.push, .right),
            (.slide, .top),
            (.wipe, .bottomLeft),
            (.zoom, .left)
        ]
        for (kind, direction) in kinds {
            let project = try makeVideoTransitionPairProject(
                kind: kind,
                direction: direction,
                durationFrames: 4
            )
            let sequence = try XCTUnwrap(project.sequences.first)
            // Cut at frame 10; region [10, 14); mid at frame 12 → progress 0.5.
            let time = try editTime(12)
            let graph = try RenderGraphBuilder.build(for: sequence, at: time, in: project)
            let transitionNode = graph.nodes.first { node in
                if case .transition = node.kind { return true }
                return false
            }
            XCTAssertNotNil(transitionNode, "expected transition node for \(kind)")
            guard case .transition(let payload) = transitionNode?.kind else {
                return XCTFail("payload for \(kind)")
            }
            XCTAssertEqual(payload.kind, kind)
            XCTAssertEqual(payload.direction, direction)
            // progress = 2/4 = 1/2
            XCTAssertEqual(payload.progress.numerator, 1)
            XCTAssertEqual(payload.progress.denominator, 2)
            XCTAssertEqual(transitionNode?.inputIDs.count, 2)
            // Two source nodes + transition + composite
            XCTAssertGreaterThanOrEqual(graph.nodes.count, 4)
        }
    }

    func testFRFX001ProgressQuarterAndThreeQuarter() throws {
        let project = try makeVideoTransitionPairProject(durationFrames: 4)
        let sequence = try XCTUnwrap(project.sequences.first)
        let graph25 = try RenderGraphBuilder.build(
            for: sequence,
            at: try editTime(11),
            in: project
        )
        let graph75 = try RenderGraphBuilder.build(
            for: sequence,
            at: try editTime(13),
            in: project
        )
        guard
            case .transition(let p25) = graph25.nodes.first(where: {
                if case .transition = $0.kind { return true }
                return false
            })?.kind,
            case .transition(let p75) = graph75.nodes.first(where: {
                if case .transition = $0.kind { return true }
                return false
            })?.kind
        else {
            return XCTFail("missing transition nodes")
        }
        // 1/4 and 3/4
        XCTAssertEqual(p25.progress.numerator, 1)
        XCTAssertEqual(p25.progress.denominator, 4)
        XCTAssertEqual(p75.progress.numerator, 3)
        XCTAssertEqual(p75.progress.denominator, 4)
    }

    func testFRFX001OutsideRegionHasNoTransitionNode() throws {
        let project = try makeVideoTransitionPairProject(durationFrames: 4)
        let sequence = try XCTUnwrap(project.sequences.first)
        // Frame 5 is entirely inside outgoing geometry, no fade-tail yet.
        let graph = try RenderGraphBuilder.build(
            for: sequence,
            at: try editTime(5),
            in: project
        )
        let hasTransition = graph.nodes.contains { node in
            if case .transition = node.kind { return true }
            return false
        }
        XCTAssertFalse(hasTransition)
    }

    func testFRFX001FadeTailMapsSourcePastOutPoint() throws {
        let project = try makeVideoTransitionPairProject(durationFrames: 4)
        let sequence = try XCTUnwrap(project.sequences.first)
        let graph = try RenderGraphBuilder.build(
            for: sequence,
            at: try editTime(12),
            in: project
        )
        let outgoingID = try VideoTransitionFixtureID.outgoingClip()
        let outgoingSource = graph.nodes.compactMap { node -> RenderSourceNode? in
            guard case .source(let source) = node.kind, source.clipID == outgoingID else {
                return nil
            }
            return source
        }.first
        let source = try XCTUnwrap(outgoingSource)
        // Outgoing geometry ends at 10 with source [0,10); at timeline 12 the tail maps to
        // source time 12 (2 frames past sourceRange.end exclusive boundary).
        XCTAssertEqual(source.sourceTime, try editTime(12))
    }

    /// One-sided trailing record (mirror stripped by direct mutation) must not throw
    /// `multipleActiveVideoClips` in [T, T+D); the live incoming clip renders alone.
    func testFRFX001BrokenPairDropsTailAndRendersIncomingAlone() throws {
        let project = try makeBrokenPairProjectByDirectMutation()
        let sequence = try XCTUnwrap(project.sequences.first)
        let incomingID = try VideoTransitionFixtureID.incomingClip()
        // Frame 12 is inside the 4-frame fade-tail window after the cut at 10.
        let graph = try RenderGraphBuilder.build(
            for: sequence,
            at: try editTime(12),
            in: project
        )
        let hasTransition = graph.nodes.contains { node in
            if case .transition = node.kind { return true }
            return false
        }
        XCTAssertFalse(hasTransition, "broken pair must not emit a transition node")
        let sources = graph.nodes.compactMap { node -> RenderSourceNode? in
            if case .source(let source) = node.kind { return source }
            return nil
        }
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.clipID, incomingID)
        // Taxonomy still fails validation (typed model diagnostic channel).
        XCTAssertFalse(projectVideoTransitionErrors(in: project).isEmpty)
    }
}

/// Valid geometry with only the outgoing trailing record set (incoming mirror nil).
/// Bypasses edit maintenance so the invalid pair survives into graph build.
private func makeBrokenPairProjectByDirectMutation() throws -> Project {
    let outgoingID = try VideoTransitionFixtureID.outgoingClip()
    let incomingID = try VideoTransitionFixtureID.incomingClip()
    var outgoingSpec = VideoTransitionClipSpec()
    outgoingSpec.trailingTransition = try makeTrailingTransition(
        partner: incomingID,
        durationFrames: 4
    )
    var incomingSpec = VideoTransitionClipSpec()
    incomingSpec.timelineStartFrame = 10
    // Deliberately no leadingTransition mirror.
    return try makeVideoTransitionProject(items: [
        .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
        .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
    ])
}
