// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

final class CompoundRenderGraphTests: XCTestCase {
    func testFRTL013CompoundClipBuildsNestedRenderGraphAsCompositeInput() throws {
        let mediaID = try uuid(59)
        let targetSequenceID = try uuid(60)
        let clipID = try uuid(61)
        let innerClipID = try uuid(62)
        let compoundClip = try makeClip(
            id: clipID,
            source: .sequence(id: targetSequenceID),
            timelineStartFrame: 10,
            sourceStartFrame: 2
        )
        let innerClip = try makeClip(
            id: innerClipID,
            mediaID: mediaID,
            timelineStartFrame: 0,
            sourceStartFrame: 4
        )
        let sequence = try makeSequence(with: compoundClip)
        let targetSequence = try makeEmptySequence(
            id: targetSequenceID,
            videoTracks: [Track(id: try uuid(63), kind: .video, items: [.clip(innerClip)])]
        )
        let project = try makeProject(
            mediaPool: [makeMediaRef(id: mediaID)],
            sequences: [sequence, targetSequence]
        )

        let graph = try buildRenderGraph(for: sequence, at: try time(13), in: project)
        let compoundNode = try compoundNode(in: graph)
        let compound = try compoundPayload(in: graph)
        let output = try XCTUnwrap(graph.outputNode)
        let nestedSource = try sourceNode(in: compound.graph)

        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(output.inputIDs, [compoundNode.id])
        XCTAssertEqual(compoundNode.inputIDs, [compound.graph.outputNodeID])
        XCTAssertEqual(compound.clipID, clipID)
        XCTAssertEqual(compound.sequenceID, targetSequenceID)
        XCTAssertEqual(compound.sequenceTime, try time(5))

        guard case .source(let source) = nestedSource.kind else {
            return XCTFail("Expected nested media source")
        }
        XCTAssertEqual(source.mediaID, mediaID)
        XCTAssertEqual(source.clipID, innerClipID)
        XCTAssertEqual(source.sourceTime, try time(9))
    }

    func testFRTL013InnerSequenceEditInvalidatesCompoundAndOuterHashes() throws {
        let mediaID = try uuid(64)
        let targetSequenceID = try uuid(65)
        let clipID = try uuid(66)
        let firstInnerClip = try makeClip(
            id: try uuid(67),
            mediaID: mediaID,
            sourceStartFrame: 0
        )
        let secondInnerClip = try makeClip(
            id: try uuid(67),
            mediaID: mediaID,
            sourceStartFrame: 1
        )
        let compoundClip = try makeClip(
            id: clipID,
            source: .sequence(id: targetSequenceID),
            timelineStartFrame: 0,
            sourceStartFrame: 0
        )
        let outerSequence = try makeSequence(with: compoundClip)
        let firstInnerSequence = try makeEmptySequence(
            id: targetSequenceID,
            videoTracks: [Track(id: try uuid(68), kind: .video, items: [.clip(firstInnerClip)])]
        )
        let secondInnerSequence = try makeEmptySequence(
            id: targetSequenceID,
            videoTracks: [Track(id: try uuid(68), kind: .video, items: [.clip(secondInnerClip)])]
        )
        let media = try makeMediaRef(id: mediaID)
        let firstProject = try makeProject(
            mediaPool: [media],
            sequences: [outerSequence, firstInnerSequence]
        )
        let secondProject = try makeProject(
            mediaPool: [media],
            sequences: [outerSequence, secondInnerSequence]
        )

        let firstGraph = try buildRenderGraph(for: outerSequence, at: try time(0), in: firstProject)
        let secondGraph = try buildRenderGraph(
            for: outerSequence,
            at: try time(0),
            in: secondProject
        )

        XCTAssertNotEqual(
            try compoundPayload(in: firstGraph).graph.outputNode?.contentHash,
            try compoundPayload(in: secondGraph).graph.outputNode?.contentHash
        )
        XCTAssertNotEqual(
            try compoundNode(in: firstGraph).contentHash,
            try compoundNode(in: secondGraph).contentHash
        )
        XCTAssertNotEqual(firstGraph.outputNode?.contentHash, secondGraph.outputNode?.contentHash)
    }

    func testFRTL013OuterCompoundTransformDoesNotInvalidateNestedGraphHash() throws {
        let mediaID = try uuid(69)
        let targetSequenceID = try uuid(70)
        let baseCompoundClip = try makeClip(
            id: try uuid(71),
            source: .sequence(id: targetSequenceID),
            timelineStartFrame: 0,
            sourceStartFrame: 0
        )
        let transformedCompoundClip = try makeClip(
            id: try uuid(71),
            source: .sequence(id: targetSequenceID),
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            transform: ClipTransform(position: CanvasPoint(x: RationalValue(4), y: .zero))
        )
        let innerSequence = try makeEmptySequence(
            id: targetSequenceID,
            videoTracks: [
                Track(
                    id: try uuid(72),
                    kind: .video,
                    items: [.clip(try makeClip(id: try uuid(73), mediaID: mediaID))]
                )
            ]
        )
        let baseSequence = try makeSequence(with: baseCompoundClip)
        let transformedSequence = try makeSequence(with: transformedCompoundClip)
        let media = try makeMediaRef(id: mediaID)
        let baseProject = try makeProject(
            mediaPool: [media],
            sequences: [baseSequence, innerSequence]
        )
        let transformedProject = try makeProject(
            mediaPool: [media],
            sequences: [transformedSequence, innerSequence]
        )

        let baseGraph = try buildRenderGraph(for: baseSequence, at: try time(0), in: baseProject)
        let transformedGraph = try buildRenderGraph(
            for: transformedSequence,
            at: try time(0),
            in: transformedProject
        )

        XCTAssertEqual(
            try compoundPayload(in: baseGraph).graph.outputNode?.contentHash,
            try compoundPayload(in: transformedGraph).graph.outputNode?.contentHash
        )
        XCTAssertEqual(
            try compoundNode(in: baseGraph).contentHash,
            try compoundNode(in: transformedGraph).contentHash
        )
        XCTAssertNotEqual(
            baseGraph.outputNode?.contentHash,
            transformedGraph.outputNode?.contentHash
        )
    }

    func testNFRSTAB003MissingCompoundSequenceReturnsTypedRenderGraphError() throws {
        let missingSequenceID = try uuid(74)
        let clipID = try uuid(75)
        let clip = try makeClip(
            id: clipID,
            source: .sequence(id: missingSequenceID),
            timelineStartFrame: 0,
            sourceStartFrame: 0
        )
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(mediaPool: [], sequences: [sequence])

        XCTAssertThrowsError(
            try buildRenderGraph(for: sequence, at: try time(0), in: project)
        ) { error in
            XCTAssertEqual(
                error as? RenderGraphBuildError,
                .missingSequenceReference(clipID: clipID, sequenceID: missingSequenceID)
            )
        }
    }

    func testNFRSTAB003CompoundNestingDepthBoundReturnsTypedRenderGraphError() throws {
        let sequenceID = try uuid(76)
        let clipID = try uuid(77)
        let clip = try makeClip(
            id: clipID,
            source: .sequence(id: sequenceID),
            timelineStartFrame: 0,
            sourceStartFrame: 0
        )
        let sequence = try makeSequence(with: clip, id: sequenceID)
        let project = try makeProject(mediaPool: [], sequences: [sequence])

        XCTAssertThrowsError(
            try buildRenderGraph(for: sequence, at: try time(0), in: project)
        ) { error in
            XCTAssertEqual(
                error as? RenderGraphBuildError,
                .maximumCompoundNestingDepthExceeded(
                    clipID: clipID,
                    depth: RenderGraphBuilder.maximumCompoundNestingDepth
                )
            )
        }
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

private func compoundNode(in graph: RenderGraph) throws -> RenderNode {
    try XCTUnwrap(
        graph.nodes.first { node in
            if case .compound = node.kind {
                return true
            }
            return false
        }
    )
}

private func compoundPayload(in graph: RenderGraph) throws -> RenderCompoundNode {
    let node = try compoundNode(in: graph)
    guard case .compound(let compound) = node.kind else {
        throw CompoundRenderGraphTestError.expectedCompoundNode
    }
    return compound
}

private enum CompoundRenderGraphTestError: Error {
    case expectedCompoundNode
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

private func makeSequence(with clip: Clip, id: UUID? = nil) throws -> Sequence {
    let track = Track(id: try uuid(800), kind: .video, items: [.clip(clip)])
    return try makeEmptySequence(id: id ?? uuid(801), videoTracks: [track])
}

private func makeEmptySequence(
    id: UUID,
    videoTracks: [Track] = []
) throws -> Sequence {
    Sequence(
        id: id,
        name: "RenderGraph sequence",
        videoTracks: videoTracks,
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeMediaRef(
    id: UUID,
    colorSpace: MediaColorSpace = .rec709
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

private func makeClip(
    id: UUID,
    mediaID: UUID,
    timelineStartFrame: Int64 = 0,
    sourceStartFrame: Int64 = 0,
    durationFrames: Int64 = 10,
    transform: ClipTransform = .identity,
    effects: ClipEffects = .none
) throws -> Clip {
    try makeClip(
        id: id,
        source: .media(id: mediaID),
        timelineStartFrame: timelineStartFrame,
        sourceStartFrame: sourceStartFrame,
        durationFrames: durationFrames,
        transform: transform,
        effects: effects
    )
}

private func makeClip(
    id: UUID,
    source: ClipSource,
    timelineStartFrame: Int64,
    sourceStartFrame: Int64,
    durationFrames: Int64 = 10,
    transform: ClipTransform = .identity,
    effects: ClipEffects = .none
) throws -> Clip {
    Clip(
        id: id,
        source: source,
        sourceRange: try range(startFrame: sourceStartFrame, durationFrames: durationFrames),
        timelineRange: try range(startFrame: timelineStartFrame, durationFrames: durationFrames),
        kind: .video,
        name: "RenderGraph clip",
        transform: transform,
        effects: effects
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
