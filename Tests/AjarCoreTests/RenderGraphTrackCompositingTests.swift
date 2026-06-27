// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class RenderGraphTrackCompositingTests: XCTestCase {
    func testFRCOMP006TrackBlendAndOpacityPropagateAndInvalidateCompositeHash() throws {
        let mediaID = try trackCompositingUUID(77)
        let clipID = try trackCompositingUUID(78)
        let trackID = try trackCompositingUUID(79)
        let clip = try makeTrackCompositingClip(
            id: clipID,
            mediaID: mediaID,
            durationFrames: 24
        )
        let defaultSequence = try makeTrackCompositingSequence(
            id: try trackCompositingUUID(91),
            track: Track(id: trackID, kind: .video, items: [.clip(clip)])
        )
        let compositingSequence = try makeTrackCompositingSequence(
            id: try trackCompositingUUID(92),
            track: try makeCompositingTrack(id: trackID, clip: clip)
        )
        let media = try makeTrackCompositingMediaRef(id: mediaID)
        let defaultProject = try makeTrackCompositingProject(
            media: media,
            sequence: defaultSequence
        )
        let compositingProject = try makeTrackCompositingProject(
            media: media,
            sequence: compositingSequence
        )

        let defaultGraph = try RenderGraphBuilder.build(
            for: defaultSequence,
            at: try trackCompositingTime(12),
            in: defaultProject
        )
        let compositingGraph = try RenderGraphBuilder.build(
            for: compositingSequence,
            at: try trackCompositingTime(12),
            in: compositingProject
        )
        let input = try XCTUnwrap(trackCompositingComposite(compositingGraph).inputs.first)

        XCTAssertEqual(input.trackOpacity, try RationalValue(numerator: 1, denominator: 2))
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
}

private func makeCompositingTrack(id: UUID, clip: Clip) throws -> Track {
    Track(
        id: id,
        kind: .video,
        items: [.clip(clip)],
        opacity: try Animatable(
            base: .one,
            keyframes: [
                Keyframe(time: try trackCompositingTime(0), value: .one, interpolation: .linear),
                Keyframe(
                    time: try trackCompositingTime(12),
                    value: try RationalValue(numerator: 1, denominator: 2),
                    interpolation: .hold
                )
            ]
        ),
        blendMode: .hardLight
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
    durationFrames: Int64
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try trackCompositingRange(durationFrames: durationFrames),
        timelineRange: try trackCompositingRange(durationFrames: durationFrames),
        kind: .video,
        name: "RenderGraph track compositing clip"
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
