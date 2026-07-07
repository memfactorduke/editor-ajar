// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-002 render graph coverage: piecewise source-time resolution, freeze-span holds,
/// content-hash invalidation on keyframe edits, and compound clip composition.
final class ClipTimeRemapRenderGraphTests: XCTestCase {
    func testFRSPD002RampMapsRenderGraphSourceTimesPerSegment() throws {
        let mediaID = try remapUUID(4_400)
        let media = try makeRemapMediaRef(id: mediaID)
        let curve = try rampCurve()
        let clip = try makeRemapClip(
            clipSeed: 4_401,
            curve: curve,
            sourceDurationFrames: 36,
            mediaID: mediaID
        )
        let sequence = try makeRemapSequence(with: clip, seed: 4_402)
        let project = try makeRemapProject(mediaPool: [media], sequences: [sequence])

        // Segment one (slope 1x): timeline frame 16 is offset 6 -> source frame 6.
        let earlyPayload = try sourcePayload(
            in: buildRenderGraph(for: sequence, at: try editTime(16), in: project)
        )
        XCTAssertEqual(earlyPayload.sourceTime, try editTime(6))
        XCTAssertEqual(earlyPayload.timeRemap, curve)

        // Segment two (slope 2x): timeline frame 28 is offset 18 -> source frame 24, which a
        // constant-rate reading of the same clip (36 source over 24 timeline = 1.5x) would map
        // to source frame 27 instead.
        let latePayload = try sourcePayload(
            in: buildRenderGraph(for: sequence, at: try editTime(28), in: project)
        )
        XCTAssertEqual(latePayload.sourceTime, try editTime(24))
    }

    func testFRSPD002ZeroSlopeSpanHoldsSourceTimeAndCacheIdentity() throws {
        let mediaID = try remapUUID(4_410)
        let media = try makeRemapMediaRef(id: mediaID)
        let curve = try ClipTimeRemap(keyframes: [
            try remapKeyframe(0, 0),
            try remapKeyframe(6, 6),
            try remapKeyframe(18, 6),
            try remapKeyframe(24, 12)
        ])
        let clip = try makeRemapClip(
            clipSeed: 4_411,
            curve: curve,
            sourceDurationFrames: 12,
            mediaID: mediaID
        )
        let sequence = try makeRemapSequence(with: clip, seed: 4_412)
        let project = try makeRemapProject(mediaPool: [media], sequences: [sequence])

        let holdStart = try sourceRenderNode(
            in: buildRenderGraph(for: sequence, at: try editTime(17), in: project)
        )
        let holdEnd = try sourceRenderNode(
            in: buildRenderGraph(for: sequence, at: try editTime(27), in: project)
        )

        guard case .source(let startPayload) = holdStart.kind,
              case .source(let endPayload) = holdEnd.kind
        else {
            return XCTFail("Expected source nodes for the freeze span")
        }
        XCTAssertEqual(startPayload.sourceTime, try editTime(6))
        XCTAssertEqual(endPayload.sourceTime, try editTime(6))
        // Identical resolved params must produce the same cache identity across the span.
        XCTAssertEqual(holdStart.contentHash, holdEnd.contentHash)
    }

    func testADR0009FRSPD002ChangingKeyframesInvalidatesHashWhenSampledTimeUnchanged() throws {
        let mediaID = try remapUUID(4_420)
        let media = try makeRemapMediaRef(id: mediaID)
        // Both curves map timeline frame 16 (offset 6) to source frame 6, but the second curve
        // ends on a different keyframe, so only the stored curve distinguishes them.
        let rampToDouble = try rampCurve()
        let rampToTriple = try ClipTimeRemap(keyframes: [
            try remapKeyframe(0, 0),
            try remapKeyframe(12, 12),
            try remapKeyframe(24, 30)
        ])

        var graphs: [RenderGraph] = []
        for curve in [rampToDouble, rampToTriple] {
            let clip = try makeRemapClip(
                clipSeed: 4_421,
                curve: curve,
                sourceDurationFrames: 36,
                mediaID: mediaID
            )
            let sequence = try makeRemapSequence(with: clip, seed: 4_422)
            let project = try makeRemapProject(mediaPool: [media], sequences: [sequence])
            graphs.append(try buildRenderGraph(for: sequence, at: try editTime(16), in: project))
        }

        XCTAssertEqual(
            try sourcePayload(in: graphs[0]).sourceTime,
            try sourcePayload(in: graphs[1]).sourceTime
        )
        XCTAssertNotEqual(
            try sourceRenderNode(in: graphs[0]).contentHash,
            try sourceRenderNode(in: graphs[1]).contentHash
        )
        XCTAssertNotEqual(
            graphs[0].outputNode?.contentHash,
            graphs[1].outputNode?.contentHash
        )
    }

    func testFRSPD002CompoundClipTimeRemapMapsNestedSequenceTime() throws {
        let mediaID = try remapUUID(4_430)
        let media = try makeRemapMediaRef(id: mediaID)
        let innerClip = Clip(
            id: try remapUUID(4_431),
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: editTime(0), duration: editTime(36)),
            timelineRange: try TimeRange(start: editTime(0), duration: editTime(36)),
            kind: .video,
            name: "FR-SPD-002 nested clip"
        )
        let nestedSequence = try makeRemapSequence(with: innerClip, seed: 4_432)
        let curve = try rampCurve()
        let compoundClip = Clip(
            id: try remapUUID(4_435),
            source: .sequence(id: nestedSequence.id),
            sourceRange: try TimeRange(start: editTime(0), duration: editTime(36)),
            timelineRange: try TimeRange(start: editTime(10), duration: curve.duration),
            kind: .video,
            name: "FR-SPD-002 compound remap clip",
            timeRemap: curve
        )
        let outerSequence = try makeRemapSequence(with: compoundClip, seed: 4_436)
        let project = try makeRemapProject(
            mediaPool: [media],
            sequences: [outerSequence, nestedSequence]
        )

        let graph = try buildRenderGraph(for: outerSequence, at: try editTime(28), in: project)
        let compoundNode = try XCTUnwrap(
            graph.nodes.first { node in
                if case .compound = node.kind {
                    return true
                }
                return false
            }
        )
        guard case .compound(let payload) = compoundNode.kind else {
            return XCTFail("Expected compound node")
        }

        // Offset 18 through the 1x -> 2x ramp resolves nested sequence frame 24, and the
        // nested graph decodes the inner media at that same frame.
        XCTAssertEqual(payload.sequenceTime, try editTime(24))
        XCTAssertEqual(payload.timeRemap, curve)
        XCTAssertEqual(try sourcePayload(in: payload.graph).sourceTime, try editTime(24))
    }

    func testFRSPD002ConflictingRetimeFailsRenderGraphBuildWithTypedError() throws {
        let mediaID = try remapUUID(4_440)
        let media = try makeRemapMediaRef(id: mediaID)
        let clip = try makeRemapClip(
            clipSeed: 4_441,
            curve: try rampCurve(),
            sourceDurationFrames: 36,
            mediaID: mediaID,
            reverse: true
        )
        let sequence = try makeRemapSequence(with: clip, seed: 4_442)
        let project = try makeRemapProject(mediaPool: [media], sequences: [sequence])

        XCTAssertThrowsError(
            try buildRenderGraph(for: sequence, at: try editTime(16), in: project)
        ) { error in
            XCTAssertEqual(
                error as? RenderGraphBuildError,
                .clipSpeedMappingFailed(
                    clipID: clip.id,
                    error: .invalidTimeRemap(
                        .conflictingRetime(reverse: true, freezeFrame: false, speed: .one)
                    )
                )
            )
        }
    }
}

private func sourceRenderNode(in graph: RenderGraph) throws -> RenderNode {
    try XCTUnwrap(
        graph.nodes.first { node in
            if case .source = node.kind {
                return true
            }
            return false
        }
    )
}

private func sourcePayload(in graph: RenderGraph) throws -> RenderSourceNode {
    guard case .source(let payload) = try sourceRenderNode(in: graph).kind else {
        XCTFail("Expected source node payload")
        throw RenderGraphBuildError.contentHashEncodingFailed("missing source payload")
    }
    return payload
}

private func makeRemapProject(
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

private func makeRemapSequence(with clip: Clip, seed: Int) throws -> Sequence {
    let track = Track(id: try remapUUID(seed * 10), kind: .video, items: [.clip(clip)])
    return Sequence(
        id: try remapUUID((seed * 10) + 1),
        name: "FR-SPD-002 render graph sequence \(seed)",
        videoTracks: [track],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeRemapMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try editTime(240),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func remapUUID(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}
