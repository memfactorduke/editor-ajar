// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarExport

/// FR-EXP-007 last-frame golden triangulation (title fixture, 12 frames @ 30 fps).
final class ExportGoldenLastFrameTests: XCTestCase {
    /// Graph construction is half-open and hash-stable: no last-frame clip/background drop.
    func testFREXP007TitleGraphPresentAndHashStableThroughLastFrame() throws {
        let context = try makeTitleGraphContext(frameCount: 12)
        var hashes: [ContentHash] = []
        for index in 0..<context.frameCount {
            let time = try context.range.start.adding(
                context.frameRate.duration(ofFrames: index)
            )
            XCTAssertTrue(
                try context.videoClip.timelineRange.contains(time),
                "frame \(index) at \(time) must stay inside half-open timelineRange"
            )
            let graph = try buildRenderGraph(
                for: context.sequence,
                at: time,
                in: context.project
            )
            try assertTitleCompositeGraph(graph, frameIndex: Int(index))
            hashes.append(try XCTUnwrap(graph.outputNode).contentHash)
        }
        XCTAssertEqual(
            Set(hashes).count,
            1,
            "static title must hash-identical for every export sample time (cache key stable)"
        )
    }

    func testFREXP007FlattenOverOpaqueBlackForcesAlphaWithoutChangingRGB() {
        let transparent = ExportDecodedBGRAFrame(
            width: 1,
            height: 1,
            bgra8: Data([0, 0, 0, 0])
        )
        XCTAssertEqual(transparent.flattenedOverOpaqueBlack().bgra8, Data([0, 0, 0, 255]))

        let edge = ExportDecodedBGRAFrame(
            width: 1,
            height: 1,
            bgra8: Data([10, 20, 30, 128])
        )
        XCTAssertEqual(edge.flattenedOverOpaqueBlack().bgra8, Data([10, 20, 30, 255]))
    }

    func testFREXP007FlattenedExpectationMatchesOpaqueDecodeBand() {
        // Title canvas is transparent pre-flatten; non-alpha codec decode is opaque black.
        let expectedTransparent = ExportDecodedBGRAFrame(
            width: 2,
            height: 1,
            bgra8: Data([0, 0, 0, 0, 255, 255, 255, 255])
        )
        let decodedOpaque = ExportDecodedBGRAFrame(
            width: 2,
            height: 1,
            bgra8: Data([0, 0, 0, 255, 255, 255, 255, 255])
        )
        let unflattened = ExportGoldenComparator.compare(
            actual: decodedOpaque,
            expected: expectedTransparent,
            tolerance: .proRes422NearLossless
        )
        XCTAssertFalse(unflattened.passed)
        XCTAssertEqual(unflattened.maximumChannelDelta, 255)

        let flattened = ExportGoldenComparator.compare(
            actual: decodedOpaque,
            expected: expectedTransparent.flattenedOverOpaqueBlack(),
            tolerance: .proRes422NearLossless
        )
        XCTAssertTrue(flattened.passed)
        XCTAssertEqual(flattened.maximumChannelDelta, 0)
    }

    func testFREXP007ExpectedFramesConsistentAndFlattenedWhenMetalAvailable() async throws {
        try requireMetal()
        let fixture = try ExportGoldenFixture(frameCount: 12, width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let expected = try await fixture.renderExpectedBGRAFrames()
        XCTAssertEqual(expected.count, 12)
        for (index, frame) in expected.enumerated() {
            XCTAssertEqual(frame.width, 64)
            XCTAssertEqual(frame.height, 64)
            assertFullyOpaque(frame, label: "expected[\(index)]")
            // Corner is clear title canvas → opaque black after flatten.
            XCTAssertEqual(
                bgra(frame, x: 0, y: 0),
                [0, 0, 0, 255],
                "expected[\(index)] corner not opaque black"
            )
        }
        // Static title + content-hash cache: every sample time must produce identical delivery.
        for index in 1..<expected.count {
            XCTAssertEqual(
                expected[index].bgra8,
                expected[0].bgra8,
                "expected frame \(index) must match frame 0 (same graph hash)"
            )
        }
    }

    // MARK: - Helpers

    private struct TitleGraphContext {
        let frameCount: Int64
        let frameRate: FrameRate
        let range: TimeRange
        let videoClip: Clip
        let sequence: Sequence
        let project: Project
    }

    private func makeTitleGraphContext(frameCount: Int64) throws -> TitleGraphContext {
        let frameRate = try FrameRate(frames: 30)
        let duration = try frameRate.duration(ofFrames: frameCount)
        let range = try TimeRange(start: .zero, duration: duration)
        let title = TitleSource(boxes: [
            TitleTextBox(
                id: UUID(),
                text: "EXP7",
                origin: CanvasPoint(x: RationalValue(4), y: RationalValue(4)),
                width: RationalValue(56),
                height: RationalValue(24),
                style: TitleTextStyle(fontSize: RationalValue(14))
            )
        ])
        let videoClip = Clip(
            id: UUID(),
            source: .title(title),
            sourceRange: range,
            timelineRange: range,
            kind: .video,
            name: "FR-EXP-007 title"
        )
        let sequence = Sequence(
            id: UUID(),
            name: "FR-EXP-007 export golden",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.clip(videoClip)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 64, height: 64),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: [sequence]
        )
        return TitleGraphContext(
            frameCount: frameCount,
            frameRate: frameRate,
            range: range,
            videoClip: videoClip,
            sequence: sequence,
            project: project
        )
    }

    private func assertTitleCompositeGraph(_ graph: RenderGraph, frameIndex: Int) throws {
        let hasTitle = graph.nodes.contains { node in
            if case .title = node.kind { return true }
            return false
        }
        XCTAssertTrue(hasTitle, "title node missing at frame \(frameIndex)")
        XCTAssertEqual(graph.nodes.count, 2, "title + composite at frame \(frameIndex)")
        guard case .composite(let composite) = graph.outputNode?.kind else {
            return XCTFail("expected composite output at frame \(frameIndex)")
        }
        XCTAssertEqual(composite.inputs.count, 1)
        XCTAssertEqual(composite.background, .transparent)
    }

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
    }

    private func assertFullyOpaque(_ frame: ExportDecodedBGRAFrame, label: String) {
        frame.bgra8.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            let count = frame.width * frame.height
            for index in 0..<count {
                XCTAssertEqual(
                    pixels[index * 4 + 3],
                    255,
                    "\(label) alpha at pixel \(index)"
                )
            }
        }
    }

    private func bgra(_ frame: ExportDecodedBGRAFrame, x: Int, y: Int) -> [UInt8] {
        let offset = (y * frame.width + x) * 4
        return [
            frame.bgra8[offset],
            frame.bgra8[offset + 1],
            frame.bgra8[offset + 2],
            frame.bgra8[offset + 3]
        ]
    }
}
