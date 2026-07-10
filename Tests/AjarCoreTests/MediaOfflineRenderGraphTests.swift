// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class MediaOfflineRenderGraphTests: XCTestCase {
    func testFRMED007OfflineAndRelinkedMediaInvalidateSourceCacheIdentity() throws {
        let mediaID = UUID()
        let clip = try offlineGraphClip(mediaID: mediaID)
        let sequence = try offlineGraphSequence(clip: clip)
        let available = try offlineGraphMedia(id: mediaID)
        let offline = available.withAvailability(.offline)
        let relinked = MediaRef(
            id: available.id,
            sourceURL: URL(fileURLWithPath: "/relinked/source.mov"),
            contentHash: ContentHash.sha256(data: Data("new source bytes".utf8)),
            metadata: available.metadata,
            availability: .available
        )

        let availableGraph = try offlineGraph(media: available, sequence: sequence)
        let offlineStateGraph = try offlineGraph(media: offline, sequence: sequence)
        let relinkedGraph = try offlineGraph(media: relinked, sequence: sequence)
        let availableHash = try offlineSourceHash(in: availableGraph)

        XCTAssertNotEqual(availableHash, try offlineSourceHash(in: offlineStateGraph))
        XCTAssertNotEqual(availableHash, try offlineSourceHash(in: relinkedGraph))
        XCTAssertNotEqual(
            offlineStateGraph.outputNode?.contentHash,
            relinkedGraph.outputNode?.contentHash
        )
    }

    func testFRMED007OfflineSlateDimensionsInvalidateSourceCacheIdentity() throws {
        let mediaID = UUID()
        let clip = try offlineGraphClip(mediaID: mediaID)
        let sequence = try offlineGraphSequence(clip: clip)
        let first = try offlineGraphMedia(id: mediaID).withAvailability(.offline)
        let second = MediaRef(
            id: first.id,
            sourceURL: first.sourceURL,
            contentHash: first.contentHash,
            metadata: MediaMetadata(
                codecID: first.metadata.codecID,
                pixelDimensions: PixelDimensions(width: 128, height: 72),
                frameRate: first.metadata.frameRate,
                duration: first.metadata.duration,
                colorSpace: first.metadata.colorSpace,
                audioChannelLayout: first.metadata.audioChannelLayout,
                isVariableFrameRate: first.metadata.isVariableFrameRate,
                conformedFrameRate: first.metadata.conformedFrameRate
            ),
            availability: .offline
        )

        let firstGraph = try offlineGraph(media: first, sequence: sequence)
        let secondGraph = try offlineGraph(media: second, sequence: sequence)

        XCTAssertNotEqual(
            try offlineSourceHash(in: firstGraph),
            try offlineSourceHash(in: secondGraph)
        )
    }

    private func offlineGraph(media: MediaRef, sequence: Sequence) throws -> RenderGraph {
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: sequence.timebase,
                resolution: PixelDimensions(width: 64, height: 36),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
        return try buildRenderGraph(for: sequence, at: .zero, in: project)
    }
}

private func offlineSourceHash(in graph: RenderGraph) throws -> ContentHash {
    let node = try XCTUnwrap(
        graph.nodes.first { node in
            if case .source = node.kind {
                return true
            }
            return false
        })
    return node.contentHash
}

private func offlineGraphMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/source.mov"),
        contentHash: ContentHash.sha256(data: Data("source bytes".utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 64, height: 36),
            frameRate: try FrameRate(frames: 24),
            duration: try RationalTime(value: 1, timescale: 1),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func offlineGraphClip(mediaID: UUID) throws -> Clip {
    Clip(
        id: UUID(),
        source: .media(id: mediaID),
        sourceRange: try TimeRange(
            start: .zero,
            duration: RationalTime(value: 1, timescale: 1)
        ),
        timelineRange: try TimeRange(
            start: .zero,
            duration: RationalTime(value: 1, timescale: 1)
        ),
        kind: .video,
        name: "Offline cache identity"
    )
}

private func offlineGraphSequence(clip: Clip) throws -> Sequence {
    Sequence(
        id: UUID(),
        name: "Offline cache identity",
        videoTracks: [Track(id: UUID(), kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}
