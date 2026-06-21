// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class RenderGraphColorPipelineTests: XCTestCase {
    func testFRCOMP007SourceColorSpacePropagatesAndInvalidatesSourceHash() throws {
        let mediaID = try uuid(36)
        let clipID = try uuid(37)
        let clip = try makeClip(id: clipID, mediaID: mediaID)
        let sequence = try makeSequence(with: clip)
        let rec709Project = try makeProject(
            mediaPool: [makeMediaRef(id: mediaID, colorSpace: .rec709)],
            sequences: [sequence]
        )
        let displayP3Project = try makeProject(
            mediaPool: [makeMediaRef(id: mediaID, colorSpace: .displayP3)],
            sequences: [sequence]
        )

        let rec709Graph = try buildRenderGraph(for: sequence, at: try time(4), in: rec709Project)
        let displayP3Graph = try buildRenderGraph(
            for: sequence,
            at: try time(4),
            in: displayP3Project
        )
        let displayP3Source = try sourceNode(in: displayP3Graph)

        guard case .source(let source) = displayP3Source.kind else {
            return XCTFail("Expected source node")
        }

        XCTAssertEqual(source.colorSpace, .displayP3)
        XCTAssertNotEqual(
            try sourceNode(in: rec709Graph).contentHash,
            displayP3Source.contentHash
        )
        XCTAssertNotEqual(
            rec709Graph.outputNode?.contentHash,
            displayP3Graph.outputNode?.contentHash
        )
    }

    func testFRCOMP007OutputColorSpaceInvalidatesCompositeHashOnly() throws {
        let mediaID = try uuid(38)
        let clip = try makeClip(id: try uuid(39), mediaID: mediaID)
        let sequence = try makeSequence(with: clip)
        let media = try makeMediaRef(id: mediaID, colorSpace: .rec709)
        let rec709Project = try makeProject(
            colorSpace: .rec709,
            mediaPool: [media],
            sequences: [sequence]
        )
        let srgbProject = try makeProject(
            colorSpace: .sRGB,
            mediaPool: [media],
            sequences: [sequence]
        )

        let rec709Graph = try buildRenderGraph(for: sequence, at: try time(4), in: rec709Project)
        let srgbGraph = try buildRenderGraph(for: sequence, at: try time(4), in: srgbProject)
        let srgbOutput = try XCTUnwrap(srgbGraph.outputNode)

        guard case .composite(let composite) = srgbOutput.kind else {
            return XCTFail("Expected composite output")
        }

        XCTAssertEqual(composite.workingColorSpace, .sRGB)
        XCTAssertEqual(composite.outputColorSpace, .sRGB)
        XCTAssertEqual(
            try sourceNode(in: rec709Graph).contentHash,
            try sourceNode(in: srgbGraph).contentHash
        )
        XCTAssertNotEqual(rec709Graph.outputNode?.contentHash, srgbGraph.outputNode?.contentHash)
    }
}

private func sourceNode(in graph: RenderGraph) throws -> RenderNode {
    try XCTUnwrap(
        graph.nodes.first { node in
            if case .source = node.kind {
                return true
            }
            return false
        }
    )
}

private func makeProject(
    colorSpace: MediaColorSpace = .rec709,
    mediaPool: [MediaRef],
    sequences: [Sequence]
) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: colorSpace,
            audioSampleRate: 48_000
        ),
        mediaPool: mediaPool,
        sequences: sequences
    )
}

private func makeSequence(with clip: Clip) throws -> Sequence {
    let track = Track(id: try uuid(800), kind: .video, items: [.clip(clip)])
    return Sequence(
        id: try uuid(801),
        name: "RenderGraph color sequence",
        videoTracks: [track],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeMediaRef(
    id: UUID,
    colorSpace: MediaColorSpace
) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try time(240),
            colorSpace: colorSpace,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeClip(id: UUID, mediaID: UUID) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try range(startFrame: 0, durationFrames: 10),
        timelineRange: try range(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "RenderGraph color clip"
    )
}

private func range(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: try time(startFrame), duration: try time(durationFrames))
}

private func time(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func uuid(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}
