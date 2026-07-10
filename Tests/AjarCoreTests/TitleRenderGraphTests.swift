// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-001 / ADR-0009 title render-graph content-hash behavior.
final class TitleRenderGraphTests: XCTestCase {
    func testFRTXT001FRTXT002StylingDiscriminatesTitleContentHash() throws {
        let fixture = try makeTitleProjectFixture(seed: 8_408)
        let sequence = try XCTUnwrap(
            fixture.project.sequences.first { $0.id == fixture.sequenceID }
        )
        let graph = try buildRenderGraph(
            for: sequence,
            at: try editTime(0),
            in: fixture.project
        )
        let titleNode = try firstTitleNode(in: graph)
        guard case .title(let payload) = titleNode.kind else {
            return XCTFail("expected title node")
        }
        XCTAssertEqual(payload.title, fixture.titleSource)
        XCTAssertEqual(payload.clipID, fixture.clipID)

        let edited = try EditReducer.apply(
            .setClipTitleSource(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                title: widerStrokeTitle(fixture.titleSource)
            ),
            to: fixture.project
        )
        let editedSequence = try XCTUnwrap(
            edited.sequences.first { $0.id == fixture.sequenceID }
        )
        let editedGraph = try buildRenderGraph(
            for: editedSequence,
            at: try editTime(0),
            in: edited
        )
        let editedTitleNode = try firstTitleNode(in: editedGraph)
        XCTAssertNotEqual(titleNode.contentHash, editedTitleNode.contentHash)
        XCTAssertNotEqual(graph.outputNode?.contentHash, editedGraph.outputNode?.contentHash)
    }

    private func firstTitleNode(in graph: RenderGraph) throws -> RenderNode {
        try XCTUnwrap(
            graph.nodes.first { node in
                if case .title = node.kind { return true }
                return false
            }
        )
    }

    private func widerStrokeTitle(_ source: TitleSource) -> TitleSource {
        let boxes = source.boxes.map { box in
            TitleTextBox(
                id: box.id,
                text: box.text,
                origin: box.origin,
                width: box.width,
                height: box.height,
                style: TitleTextStyle(
                    fontFamily: box.style.fontFamily,
                    fontSize: box.style.fontSize,
                    fontWeight: box.style.fontWeight,
                    color: box.style.color,
                    tracking: box.style.tracking,
                    leading: box.style.leading,
                    alignment: box.style.alignment,
                    stroke: TitleStrokeStyle(
                        width: RationalValue(3),
                        color: box.style.stroke?.color
                            ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero),
                        join: box.style.stroke?.join ?? .miter
                    ),
                    dropShadow: box.style.dropShadow,
                    gradientFill: box.style.gradientFill
                ),
                backgroundBox: box.backgroundBox
            )
        }
        return TitleSource(boxes: boxes)
    }
}
