// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class RenderGraphAnimatedTransformTests: XCTestCase {
    func testFRKEY001FRXFORM008RenderGraphUsesEvaluatedTransformAnimation() throws {
        let mediaID = try uuid(34)
        let clip = try makeClip(
            id: try uuid(35),
            mediaID: mediaID,
            transformAnimation: positionAnimation()
        )
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(
            mediaPool: [makeMediaRef(id: mediaID)],
            sequences: [sequence]
        )

        let graph = try buildRenderGraph(for: sequence, at: try time(4), in: project)
        let input = try compositeInput(in: graph)

        XCTAssertEqual(
            input.transform.position,
            CanvasPoint(x: RationalValue(4), y: RationalValue(8))
        )
    }

    func testFRKEY001FRKEY003AnimatedTransformInvalidatesCompositeHashOverTime() throws {
        let mediaID = try uuid(36)
        let clip = try makeClip(
            id: try uuid(37),
            mediaID: mediaID,
            transformAnimation: positionAnimation()
        )
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(
            mediaPool: [makeMediaRef(id: mediaID)],
            sequences: [sequence]
        )

        let startGraph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let midGraph = try buildRenderGraph(for: sequence, at: try time(4), in: project)
        let startInput = try compositeInput(in: startGraph)
        let midInput = try compositeInput(in: midGraph)

        XCTAssertNotEqual(startInput.transform, midInput.transform)
        XCTAssertNotEqual(startGraph.outputNode?.contentHash, midGraph.outputNode?.contentHash)
    }

    func testFRKEY003EvaluatedTransformContributesToCompositeHashAtSameSourceFrame() throws {
        let mediaID = try uuid(38)
        let clipID = try uuid(39)
        let media = try makeMediaRef(id: mediaID)
        let firstClip = try makeClip(id: clipID, mediaID: mediaID, transformAnimation: .identity)
        let secondClip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            transformAnimation: positionAnimation()
        )
        let firstSequence = try makeSequence(with: firstClip)
        let secondSequence = try makeSequence(with: secondClip)
        let firstProject = try makeProject(mediaPool: [media], sequences: [firstSequence])
        let secondProject = try makeProject(mediaPool: [media], sequences: [secondSequence])

        let firstGraph = try buildRenderGraph(for: firstSequence, at: try time(4), in: firstProject)
        let secondGraph = try buildRenderGraph(
            for: secondSequence,
            at: try time(4),
            in: secondProject
        )

        XCTAssertEqual(
            try sourceNode(in: firstGraph).contentHash,
            try sourceNode(in: secondGraph).contentHash
        )
        XCTAssertNotEqual(firstGraph.outputNode?.contentHash, secondGraph.outputNode?.contentHash)
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

private func compositeInput(in graph: RenderGraph) throws -> RenderCompositeInput {
    let output = try XCTUnwrap(graph.outputNode)
    guard case .composite(let composite) = output.kind else {
        throw RenderGraphAnimatedTransformTestError.expectedComposite
    }
    return try XCTUnwrap(composite.inputs.first)
}

private enum RenderGraphAnimatedTransformTestError: Error {
    case expectedComposite
}

private func makeProject(mediaPool: [MediaRef], sequences: [Sequence]) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: .rec709,
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
        name: "RenderGraph animated transform sequence",
        videoTracks: [track],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try time(240),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeClip(
    id: UUID,
    mediaID: UUID,
    transformAnimation: AnimatableClipTransform
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try range(startFrame: 0, durationFrames: 10),
        timelineRange: try range(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "RenderGraph animated transform clip",
        transformAnimation: transformAnimation
    )
}

private func positionAnimation() throws -> AnimatableClipTransform {
    try AnimatableClipTransform(
        position: Animatable(
            base: .zero,
            keyframes: [
                Keyframe(time: time(0), value: .zero, interpolation: .linear),
                Keyframe(
                    time: time(8),
                    value: CanvasPoint(x: RationalValue(8), y: RationalValue(16)),
                    interpolation: .hold
                )
            ]
        )
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
