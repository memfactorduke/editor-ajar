// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class RenderGraphTrackCompositingTests: XCTestCase {
    func testFRCOMP006TrackOpacityPropagatesAndInvalidatesCompositeHashOnly() throws {
        let mediaID = try trackCompositingUUID(77)
        let clipID = try trackCompositingUUID(78)
        let trackID = try trackCompositingUUID(79)
        let clip = try makeTrackCompositingClip(
            id: clipID,
            mediaID: mediaID,
            durationFrames: 24
        )
        let defaultTrack = Track(id: trackID, kind: .video, items: [.clip(clip)])
        let compositingTrack = try makeCompositingTrack(
            id: trackID,
            clip: clip,
            opacity: makeCompositingOpacity()
        )
        let media = try makeTrackCompositingMediaRef(id: mediaID)

        let defaultGraph = try makeTrackCompositingGraph(track: defaultTrack, media: media)
        let compositingGraph = try makeTrackCompositingGraph(
            track: compositingTrack,
            media: media
        )
        let input = try XCTUnwrap(trackCompositingComposite(compositingGraph).inputs.first)

        XCTAssertEqual(input.trackOpacity, try RationalValue(numerator: 1, denominator: 2))
        XCTAssertEqual(input.trackBlendMode, .normal)
        XCTAssertEqual(
            try trackCompositingSourceNode(defaultGraph).contentHash,
            try trackCompositingSourceNode(compositingGraph).contentHash
        )
        XCTAssertNotEqual(
            defaultGraph.outputNode?.contentHash,
            compositingGraph.outputNode?.contentHash
        )
    }

    func testFRCOMP006TrackBlendModePropagatesAndInvalidatesCompositeHashOnly() throws {
        let mediaID = try trackCompositingUUID(80)
        let clipID = try trackCompositingUUID(81)
        let trackID = try trackCompositingUUID(82)
        let clip = try makeTrackCompositingClip(
            id: clipID,
            mediaID: mediaID,
            durationFrames: 24
        )
        let defaultTrack = Track(id: trackID, kind: .video, items: [.clip(clip)])
        let compositingTrack = try makeCompositingTrack(
            id: trackID,
            clip: clip,
            blendMode: .hardLight
        )
        let media = try makeTrackCompositingMediaRef(id: mediaID)

        let defaultGraph = try makeTrackCompositingGraph(track: defaultTrack, media: media)
        let compositingGraph = try makeTrackCompositingGraph(
            track: compositingTrack,
            media: media
        )
        let input = try XCTUnwrap(trackCompositingComposite(compositingGraph).inputs.first)

        XCTAssertEqual(input.trackOpacity, .one)
        XCTAssertEqual(input.trackBlendMode, .hardLight)
        XCTAssertEqual(
            try trackCompositingSourceNode(defaultGraph).contentHash,
            try trackCompositingSourceNode(compositingGraph).contentHash
        )
        XCTAssertNotEqual(
            defaultGraph.outputNode?.contentHash,
            compositingGraph.outputNode?.contentHash
        )
    }

    func testFRCOMP006ClipBlendModeInvalidatesCompositeHashOnly() throws {
        let mediaID = try trackCompositingUUID(83)
        let defaultClip = try makeTrackCompositingClip(
            id: try trackCompositingUUID(84),
            mediaID: mediaID,
            durationFrames: 24
        )
        let blendedClip = try makeTrackCompositingClip(
            id: defaultClip.id,
            mediaID: mediaID,
            durationFrames: 24,
            transform: ClipTransform(blendMode: .softLight)
        )
        let defaultTrack = Track(
            id: try trackCompositingUUID(85),
            kind: .video,
            items: [.clip(defaultClip)]
        )
        let blendedTrack = Track(id: defaultTrack.id, kind: .video, items: [.clip(blendedClip)])
        let media = try makeTrackCompositingMediaRef(id: mediaID)

        let defaultGraph = try makeTrackCompositingGraph(track: defaultTrack, media: media)
        let compositingGraph = try makeTrackCompositingGraph(track: blendedTrack, media: media)

        XCTAssertEqual(
            try trackCompositingSourceNode(defaultGraph).contentHash,
            try trackCompositingSourceNode(compositingGraph).contentHash
        )
        XCTAssertNotEqual(
            defaultGraph.outputNode?.contentHash,
            compositingGraph.outputNode?.contentHash
        )
    }
}

private func makeCompositingTrack(
    id: UUID,
    clip: Clip,
    opacity: Animatable<RationalValue> = .constant(.one),
    blendMode: ClipBlendMode = .normal
) throws -> Track {
    Track(
        id: id,
        kind: .video,
        items: [.clip(clip)],
        opacity: opacity,
        blendMode: blendMode
    )
}

private func makeCompositingOpacity() throws -> Animatable<RationalValue> {
    try Animatable(
        base: .one,
        keyframes: [
            Keyframe(time: try trackCompositingTime(0), value: .one, interpolation: .linear),
            Keyframe(
                time: try trackCompositingTime(12),
                value: try RationalValue(numerator: 1, denominator: 2),
                interpolation: .hold
            )
        ]
    )
}

private func makeTrackCompositingGraph(track: Track, media: MediaRef) throws -> RenderGraph {
    let sequence = try makeTrackCompositingSequence(
        id: try trackCompositingUUID(91),
        track: track
    )
    let project = try makeTrackCompositingProject(media: media, sequence: sequence)
    return try RenderGraphBuilder.build(
        for: sequence,
        at: try trackCompositingTime(12),
        in: project
    )
}

private func makeTrackCompositingProject(media: MediaRef, sequence: Sequence) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [media],
        sequences: [sequence]
    )
}

private func makeTrackCompositingSequence(id: UUID, track: Track) throws -> Sequence {
    Sequence(
        id: id,
        name: "RenderGraph track compositing",
        videoTracks: [track],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeTrackCompositingClip(
    id: UUID,
    mediaID: UUID,
    durationFrames: Int64,
    transform: ClipTransform = .identity
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try trackCompositingRange(durationFrames: durationFrames),
        timelineRange: try trackCompositingRange(durationFrames: durationFrames),
        kind: .video,
        name: "RenderGraph track compositing clip",
        transform: transform
    )
}

private func makeTrackCompositingMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try trackCompositingTime(240),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func trackCompositingComposite(_ graph: RenderGraph) throws -> RenderCompositeNode {
    let outputNode = try XCTUnwrap(graph.outputNode)
    guard case .composite(let composite) = outputNode.kind else {
        throw TrackCompositingRenderGraphTestError.expectedComposite
    }
    return composite
}

private func trackCompositingSourceNode(_ graph: RenderGraph) throws -> RenderNode {
    try XCTUnwrap(
        graph.nodes.first { node in
            if case .source = node.kind {
                return true
            }
            return false
        }
    )
}

private func trackCompositingRange(durationFrames: Int64) throws -> TimeRange {
    try TimeRange(
        start: try trackCompositingTime(0),
        duration: try trackCompositingTime(durationFrames)
    )
}

private func trackCompositingTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func trackCompositingUUID(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}

private enum TrackCompositingRenderGraphTestError: Error {
    case expectedComposite
}
