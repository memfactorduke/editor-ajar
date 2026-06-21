// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class RenderGraphTests: XCTestCase {
    func testADR0009FRPLAY005BuildsSingleClipSourceAndCompositeGraph() throws {
        let mediaID = try uuid(1)
        let clipID = try uuid(2)
        let media = try makeMediaRef(id: mediaID)
        let clip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            timelineStartFrame: 24,
            sourceStartFrame: 48
        )
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(mediaPool: [media], sequences: [sequence])

        let graph = try buildRenderGraph(for: sequence, at: try time(30), in: project)
        let source = try sourceNode(in: graph)
        let output = try XCTUnwrap(graph.outputNode)

        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(source.inputIDs, [])
        XCTAssertEqual(output.inputIDs, [source.id])
        XCTAssertEqual(output.contentHash, graph.outputNode?.contentHash)

        guard case .source(let payload) = source.kind else {
            return XCTFail("Expected source node")
        }

        XCTAssertEqual(payload.mediaID, mediaID)
        XCTAssertEqual(payload.clipID, clipID)
        XCTAssertEqual(payload.sourceTime, try time(54))

        guard case .composite(let composite) = output.kind else {
            return XCTFail("Expected composite output")
        }
        XCTAssertEqual(composite.inputs, [
            RenderCompositeInput(sourceNodeID: source.id, transform: clip.transform)
        ])
    }

    func testADR0009RenderGraphCodableRoundTripPreservesHashes() throws {
        let mediaID = try uuid(10)
        let clip = try makeClip(id: try uuid(11), mediaID: mediaID)
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(
            mediaPool: [makeMediaRef(id: mediaID)],
            sequences: [sequence]
        )
        let graph = try buildRenderGraph(for: sequence, at: try time(3), in: project)

        let encoded = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(RenderGraph.self, from: encoded)

        XCTAssertEqual(decoded, graph)
        XCTAssertEqual(decoded.outputNode?.contentHash, graph.outputNode?.contentHash)
    }

    func testADR0009FRPLAY005SameProjectAndTimePropertyProducesIdenticalGraphAndHashes() throws {
        let mediaID = try uuid(20)
        let clip = try makeClip(id: try uuid(21), mediaID: mediaID, durationFrames: 12)
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(
            mediaPool: [makeMediaRef(id: mediaID)],
            sequences: [sequence]
        )

        for frame in 0..<12 {
            let first = try buildRenderGraph(
                for: sequence,
                at: try time(Int64(frame)),
                in: project
            )
            let second = try buildRenderGraph(
                for: sequence,
                at: try time(Int64(frame)),
                in: project
            )

            XCTAssertEqual(first, second)
            XCTAssertEqual(first.outputNode?.contentHash, second.outputNode?.contentHash)
        }
    }

    func testFRPLAY005ChangingClipSourceRangeChangesSourceAndCompositeHashes() throws {
        let mediaID = try uuid(30)
        let clipID = try uuid(31)
        let media = try makeMediaRef(id: mediaID)
        let firstClip = try makeClip(id: clipID, mediaID: mediaID, sourceStartFrame: 0)
        let secondClip = try makeClip(id: clipID, mediaID: mediaID, sourceStartFrame: 1)
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

        XCTAssertNotEqual(
            try sourceNode(in: firstGraph).contentHash,
            try sourceNode(in: secondGraph).contentHash
        )
        XCTAssertNotEqual(firstGraph.outputNode?.contentHash, secondGraph.outputNode?.contentHash)
    }

    func testFRXFORM001To005ChangingTransformInvalidatesCompositeButNotSourceHash() throws {
        let mediaID = try uuid(32)
        let clipID = try uuid(33)
        let media = try makeMediaRef(id: mediaID)
        let firstClip = try makeClip(id: clipID, mediaID: mediaID, transform: .identity)
        let secondClip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            transform: ClipTransform(
                position: CanvasPoint(x: RationalValue(4), y: RationalValue(2)),
                opacity: try RationalValue(numerator: 1, denominator: 2),
                blendMode: .screen,
                crop: ClipCropInsets(left: 1, top: 2, right: 3, bottom: 4),
                flip: ClipFlip(horizontal: true, vertical: false)
            )
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

    func testFRCOMP001ClipEffectsPropagateToCompositeAndInvalidateCompositeHash() throws {
        let mediaID = try uuid(34)
        let clipID = try uuid(35)
        let media = try makeMediaRef(id: mediaID)
        let effects = try makeChromaKeyEffects()
        let firstClip = try makeClip(id: clipID, mediaID: mediaID, effects: .none)
        let secondClip = try makeClip(id: clipID, mediaID: mediaID, effects: effects)
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
        let secondOutput = try XCTUnwrap(secondGraph.outputNode)

        guard case .composite(let composite) = secondOutput.kind else {
            return XCTFail("Expected composite output")
        }

        XCTAssertEqual(composite.inputs.first?.effects, effects)
        XCTAssertEqual(
            try sourceNode(in: firstGraph).contentHash,
            try sourceNode(in: secondGraph).contentHash
        )
        XCTAssertNotEqual(firstGraph.outputNode?.contentHash, secondGraph.outputNode?.contentHash)
    }

    func testADR0009NoActiveClipYieldsTransparentCompositeGraph() throws {
        let mediaID = try uuid(40)
        let clip = try makeClip(id: try uuid(41), mediaID: mediaID, timelineStartFrame: 10)
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(
            mediaPool: [makeMediaRef(id: mediaID)],
            sequences: [sequence]
        )

        let graph = try buildRenderGraph(for: sequence, at: try time(0), in: project)
        let output = try XCTUnwrap(graph.outputNode)

        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(output.inputIDs, [])

        guard case .composite(let payload) = output.kind else {
            return XCTFail("Expected composite output")
        }

        XCTAssertEqual(payload.background, .transparent)
    }

    func testFRTL002CompositeInputOrderFollowsVideoTrackStackingBottomToTop() throws {
        let bottomMediaID = try uuid(70)
        let topMediaID = try uuid(71)
        let bottomClipID = try uuid(72)
        let topClipID = try uuid(73)
        let bottomClip = try makeClip(id: bottomClipID, mediaID: bottomMediaID)
        let topClip = try makeClip(id: topClipID, mediaID: topMediaID)
        let sequence = try makeEmptySequence(
            id: try uuid(74),
            videoTracks: [
                Track(
                    id: try uuid(75),
                    kind: .video,
                    items: [.clip(bottomClip)]
                ),
                Track(
                    id: try uuid(76),
                    kind: .video,
                    items: [.clip(topClip)]
                )
            ]
        )
        let project = try makeProject(
            mediaPool: [makeMediaRef(id: bottomMediaID), makeMediaRef(id: topMediaID)],
            sequences: [sequence]
        )

        let graph = try buildRenderGraph(for: sequence, at: try time(0), in: project)

        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(
            graph.outputNode?.inputIDs.map(\.rawValue),
            [
                "source:\(bottomClipID.uuidString)",
                "source:\(topClipID.uuidString)"
            ]
        )
    }

    func testFRTL001FRTL002HiddenAndDisabledTracksAreOmittedFromComposite() throws {
        let visibleMediaID = try uuid(80)
        let hiddenMediaID = try uuid(81)
        let disabledMediaID = try uuid(82)
        let visibleClipID = try uuid(83)
        let visibleClip = try makeClip(id: visibleClipID, mediaID: visibleMediaID)
        let hiddenClip = try makeClip(id: try uuid(84), mediaID: hiddenMediaID)
        let disabledClip = try makeClip(id: try uuid(85), mediaID: disabledMediaID)
        let sequence = try makeEmptySequence(
            id: try uuid(86),
            videoTracks: [
                Track(
                    id: try uuid(87),
                    kind: .video,
                    items: [.clip(visibleClip)]
                ),
                Track(
                    id: try uuid(88),
                    kind: .video,
                    items: [.clip(hiddenClip)],
                    hidden: true
                ),
                Track(
                    id: try uuid(89),
                    kind: .video,
                    items: [.clip(disabledClip)],
                    enabled: false
                )
            ]
        )
        let project = try makeProject(
            mediaPool: [
                makeMediaRef(id: visibleMediaID),
                makeMediaRef(id: hiddenMediaID),
                makeMediaRef(id: disabledMediaID)
            ],
            sequences: [sequence]
        )

        let graph = try buildRenderGraph(for: sequence, at: try time(0), in: project)

        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(
            graph.outputNode?.inputIDs,
            [RenderNodeID(rawValue: "source:\(visibleClipID.uuidString)")]
        )
    }

    func testNFRSTAB003MissingMediaReturnsTypedRenderGraphError() throws {
        let missingMediaID = try uuid(50)
        let clipID = try uuid(51)
        let clip = try makeClip(id: clipID, mediaID: missingMediaID)
        let sequence = try makeSequence(with: clip)
        let project = try makeProject(mediaPool: [], sequences: [sequence])

        XCTAssertThrowsError(
            try buildRenderGraph(for: sequence, at: try time(0), in: project)
        ) { error in
            XCTAssertEqual(
                error as? RenderGraphBuildError,
                .missingMediaReference(clipID: clipID, mediaID: missingMediaID)
            )
        }
    }

    func testNFRSTAB003UnsupportedSequenceClipSourceReturnsTypedRenderGraphError() throws {
        let targetSequenceID = try uuid(60)
        let clipID = try uuid(61)
        let clip = try makeClip(
            id: clipID,
            source: .sequence(id: targetSequenceID),
            timelineStartFrame: 0,
            sourceStartFrame: 0
        )
        let sequence = try makeSequence(with: clip)
        let targetSequence = try makeEmptySequence(id: targetSequenceID)
        let project = try makeProject(mediaPool: [], sequences: [sequence, targetSequence])

        XCTAssertThrowsError(
            try buildRenderGraph(for: sequence, at: try time(0), in: project)
        ) { error in
            XCTAssertEqual(
                error as? RenderGraphBuildError,
                .unsupportedClipSource(clipID: clipID, source: .sequence(id: targetSequenceID))
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
    return try makeEmptySequence(id: try uuid(801), videoTracks: [track])
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

private func makeChromaKeyEffects() throws -> ClipEffects {
    ClipEffects(
        chromaKey: ClipChromaKeySettings(
            enabled: true,
            keyColor: .green,
            tolerance: try RationalValue(numerator: 1, denominator: 5),
            edgeSoftness: try RationalValue(numerator: 1, denominator: 10),
            spillSuppression: try RationalValue(numerator: 3, denominator: 5)
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
