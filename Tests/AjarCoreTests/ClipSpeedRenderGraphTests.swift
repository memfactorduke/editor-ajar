// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class ClipSpeedRenderGraphTests: XCTestCase {
    func testFREDIT007ClipSpeedMapsRenderGraphSourceTime() throws {
        let mediaID = try uuid(130)
        let clipID = try uuid(131)
        let media = try makeMediaRef(id: mediaID)
        let fastClip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            durationFrames: 16,
            speed: RationalValue(2)
        )
        let fastSequence = try makeSequence(with: fastClip)
        let fastProject = try makeProject(mediaPool: [media], sequences: [fastSequence])
        let slowClip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            durationFrames: 16,
            speed: try RationalValue(numerator: 1, denominator: 2)
        )
        let slowSequence = try makeSequence(with: slowClip)
        let slowProject = try makeProject(mediaPool: [media], sequences: [slowSequence])

        let fastGraph = try buildRenderGraph(for: fastSequence, at: try time(2), in: fastProject)
        let slowGraph = try buildRenderGraph(for: slowSequence, at: try time(4), in: slowProject)

        guard case .source(let fastPayload) = try sourceNode(in: fastGraph).kind else {
            return XCTFail("Expected fast source node")
        }
        guard case .source(let slowPayload) = try sourceNode(in: slowGraph).kind else {
            return XCTFail("Expected slow source node")
        }

        XCTAssertEqual(fastPayload.speed, RationalValue(2))
        XCTAssertEqual(fastPayload.sourceTime, try time(4))
        XCTAssertEqual(slowPayload.speed, try RationalValue(numerator: 1, denominator: 2))
        XCTAssertEqual(slowPayload.sourceTime, try time(2))
    }

    func testADR0009FREDIT007ChangingSpeedInvalidatesSourceHashAtClipStart() throws {
        let mediaID = try uuid(132)
        let clipID = try uuid(133)
        let media = try makeMediaRef(id: mediaID)
        let normalClip = try makeClip(id: clipID, mediaID: mediaID)
        let fastClip = try makeClip(id: clipID, mediaID: mediaID, speed: RationalValue(2))
        let normalSequence = try makeSequence(with: normalClip)
        let fastSequence = try makeSequence(with: fastClip)
        let normalProject = try makeProject(mediaPool: [media], sequences: [normalSequence])
        let fastProject = try makeProject(mediaPool: [media], sequences: [fastSequence])

        let normalGraph = try buildRenderGraph(
            for: normalSequence,
            at: try time(0),
            in: normalProject
        )
        let fastGraph = try buildRenderGraph(
            for: fastSequence,
            at: try time(0),
            in: fastProject
        )

        XCTAssertNotEqual(
            try sourceNode(in: normalGraph).contentHash,
            try sourceNode(in: fastGraph).contentHash
        )
        XCTAssertNotEqual(normalGraph.outputNode?.contentHash, fastGraph.outputNode?.contentHash)
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
    mediaPool: [MediaRef],
    sequences: [Sequence]
) throws -> Project {
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
        name: "RenderGraph speed sequence",
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
    durationFrames: Int64 = 10,
    speed: RationalValue = .one
) throws -> Clip {
    let sourceDuration = try time(durationFrames)
    let timelineDuration = try Clip.timelineDuration(
        forSourceDuration: sourceDuration,
        speed: speed
    )
    return Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: time(0), duration: sourceDuration),
        timelineRange: try TimeRange(start: time(0), duration: timelineDuration),
        kind: .video,
        name: "RenderGraph speed clip",
        speed: speed
    )
}

private func time(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func uuid(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}
