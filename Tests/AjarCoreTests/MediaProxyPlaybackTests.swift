// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-MED-004 pure resolution matrix, hash-tier distinction, and nested-legacy decode.
final class MediaProxyPlaybackTests: XCTestCase {
    private struct ResolutionCase {
        let prefer: Bool
        let state: MediaProxyState
        let exists: Bool
        let tier: MediaSourceTier
        let reenqueue: Bool
    }

    func testFRMED004ResolutionMatrixToggleReadinessFileExists() {
        let ready = MediaProxyState.ready(relativePath: "caches/proxies/m-hash-960x540.mov")
        let cases: [ResolutionCase] = [
            ResolutionCase(
                prefer: false, state: .none, exists: false, tier: .original, reenqueue: false
            ),
            ResolutionCase(
                prefer: false, state: ready, exists: true, tier: .original, reenqueue: false
            ),
            ResolutionCase(
                prefer: true, state: .none, exists: false, tier: .original, reenqueue: true
            ),
            ResolutionCase(
                prefer: true, state: .generating, exists: false, tier: .original, reenqueue: false
            ),
            ResolutionCase(
                prefer: true,
                state: .failed(message: "disk"),
                exists: false,
                tier: .original,
                reenqueue: true
            ),
            ResolutionCase(
                prefer: true, state: ready, exists: true, tier: .proxy, reenqueue: false
            ),
            ResolutionCase(
                prefer: true, state: ready, exists: false, tier: .original, reenqueue: true
            )
        ]
        for testCase in cases {
            let decision = MediaProxyPlaybackResolver.resolve(
                preferProxy: testCase.prefer,
                proxyState: testCase.state,
                proxyFileExists: testCase.exists
            )
            XCTAssertEqual(decision.tier, testCase.tier)
            XCTAssertEqual(decision.shouldReenqueueGeneration, testCase.reenqueue)
        }
    }

    func testFRMED004ProxyTierDistinguishesRenderSourceContentHash() throws {
        let mediaID = UUID()
        let clip = try proxyGraphClip(mediaID: mediaID)
        let sequence = try proxyGraphSequence(clip: clip)
        let media = try proxyGraphMedia(
            id: mediaID,
            proxyState: .ready(relativePath: "caches/proxies/x.mov")
        )

        let originalProject = try proxyGraphProject(
            media: media,
            sequence: sequence,
            preferProxy: false
        )
        let proxyProject = try proxyGraphProject(
            media: media,
            sequence: sequence,
            preferProxy: true
        )

        let originalGraph = try buildRenderGraph(
            for: sequence,
            at: .zero,
            in: originalProject,
            proxyFileExists: { _ in true }
        )
        let proxyGraph = try buildRenderGraph(
            for: sequence,
            at: .zero,
            in: proxyProject,
            proxyFileExists: { _ in true }
        )
        let missingProxyGraph = try buildRenderGraph(
            for: sequence,
            at: .zero,
            in: proxyProject,
            proxyFileExists: { _ in false }
        )

        let originalHash = try sourceHash(in: originalGraph)
        let proxyHash = try sourceHash(in: proxyGraph)
        let missingHash = try sourceHash(in: missingProxyGraph)

        XCTAssertNotEqual(originalHash, proxyHash, "proxy tier must invalidate cache identity")
        XCTAssertEqual(originalHash, missingHash, "missing proxy falls back to original identity")

        let proxyNode = try sourceNode(in: proxyGraph)
        if case .source(let source) = proxyNode.kind {
            XCTAssertEqual(source.mediaSourceTier, .proxy)
        } else {
            XCTFail("expected source node")
        }
        let originalNode = try sourceNode(in: originalGraph)
        if case .source(let source) = originalNode.kind {
            XCTAssertNil(source.mediaSourceTier)
        } else {
            XCTFail("expected source node")
        }
    }

    func testFRMED004ProxyResolutionPolicyHalfResMin640() {
        let half = MediaProxyResolutionPolicy.proxyDimensions(
            for: PixelDimensions(width: 1_920, height: 1_080)
        )
        XCTAssertEqual(half.width, 960)
        XCTAssertEqual(half.height, 540)

        let small = MediaProxyResolutionPolicy.proxyDimensions(
            for: PixelDimensions(width: 800, height: 450)
        )
        XCTAssertEqual(small.width, 640)
        XCTAssertGreaterThanOrEqual(small.height, 2)
        XCTAssertEqual(small.width % 2, 0)
        XCTAssertEqual(small.height % 2, 0)
    }

    func testFRMED004SchemaIncludesProxyFieldsAndLaterImportCommand() {
        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 14)
    }

    func testFRMED004NestedLegacyMediaJSONWithoutProxyKeysLoads() throws {
        let mediaID = UUID()
        let media = try proxyGraphMedia(id: mediaID, proxyState: .none)
        let sequence = try proxyGraphSequence(clip: try proxyGraphClip(mediaID: mediaID))
        let project = try proxyGraphProject(
            media: media,
            sequence: sequence,
            preferProxy: false
        )
        let package = try AjarProjectCodec.encodeNewDocument(project)

        let mediaObject = try JSONSerialization.jsonObject(with: package.mediaJSON)
            as? [String: Any]
        var mediaRoot = try XCTUnwrap(mediaObject)
        var mediaList = try XCTUnwrap(mediaRoot["media"] as? [[String: Any]])
        mediaList = mediaList.map { entry in
            var copy = entry
            copy.removeValue(forKey: "proxyState")
            return copy
        }
        mediaRoot["media"] = mediaList
        mediaRoot["schemaMinor"] = 10
        let strippedMedia = try JSONSerialization.data(withJSONObject: mediaRoot)

        var projectRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: package.projectJSON) as? [String: Any]
        )
        var settings = try XCTUnwrap(projectRoot["settings"] as? [String: Any])
        settings.removeValue(forKey: "preferProxyPlayback")
        projectRoot["settings"] = settings
        projectRoot["schemaMinor"] = 10
        let strippedProject = try JSONSerialization.data(withJSONObject: projectRoot)

        let loaded = try AjarProjectCodec.decode(
            projectJSON: strippedProject,
            mediaJSON: strippedMedia
        )
        XCTAssertEqual(loaded.project.mediaPool.first?.proxyState, MediaProxyState.none)
        XCTAssertFalse(loaded.project.settings.preferProxyPlayback)
        XCTAssertEqual(loaded.project.schemaMinor, 10)
    }

    func testFRMED004MediaRefCopyHelpersPreserveProxyState() throws {
        let media = try proxyGraphMedia(
            id: UUID(),
            proxyState: .ready(relativePath: "caches/proxies/a.mov")
        )
        let offline = media.withAvailability(.offline)
        XCTAssertEqual(offline.proxyState, media.proxyState)
        let generating = media.withProxyState(.generating)
        XCTAssertEqual(generating.proxyState, .generating)
        XCTAssertEqual(generating.availability, media.availability)
    }

    func testFRMED004RelinkResetsProxyState() throws {
        let media = try proxyGraphMedia(
            id: UUID(),
            proxyState: .ready(relativePath: "caches/proxies/a.mov")
        )
        let candidate = MediaRelinkCandidate(
            sourceURL: URL(fileURLWithPath: "/new/source.mov"),
            contentHash: ContentHash.sha256(data: Data("new".utf8))
        )
        let relinked = media.relinked(to: candidate)
        XCTAssertEqual(relinked.proxyState, MediaProxyState.none)
    }

    func testFRMED004ConsolidatePreservesProxyState() throws {
        let media = try proxyGraphMedia(
            id: UUID(),
            proxyState: .ready(relativePath: "caches/proxies/a.mov")
        )
        let candidate = MediaRelinkCandidate(
            sourceURL: URL(fileURLWithPath: "/package/media/a.mov"),
            contentHash: media.contentHash,
            bookmark: Data("bookmark".utf8)
        )
        let consolidated = media.consolidated(to: candidate)
        XCTAssertEqual(consolidated.proxyState, media.proxyState)
        XCTAssertEqual(consolidated.sourceURL, candidate.sourceURL)
        XCTAssertEqual(consolidated.bookmark, candidate.bookmark)
        // Genuine relink still resets.
        let relinked = media.relinked(to: candidate)
        XCTAssertEqual(relinked.proxyState, MediaProxyState.none)
    }

    func testFRMED004ProxyStateReadyAndPreferProxySurviveEncodeDecode() throws {
        let mediaID = UUID()
        let relativePath = "caches/proxies/\(mediaID.uuidString.lowercased())-hash-960x540.mov"
        let media = try proxyGraphMedia(
            id: mediaID,
            proxyState: .ready(relativePath: relativePath)
        )
        let sequence = try proxyGraphSequence(clip: try proxyGraphClip(mediaID: mediaID))
        let project = try proxyGraphProject(
            media: media,
            sequence: sequence,
            preferProxy: true
        )
        let package = try AjarProjectCodec.encodeNewDocument(project)
        let loaded = try AjarProjectCodec.decode(
            projectJSON: package.projectJSON,
            mediaJSON: package.mediaJSON
        )
        XCTAssertTrue(loaded.project.settings.preferProxyPlayback)
        XCTAssertEqual(
            loaded.project.mediaPool.first?.proxyState,
            MediaProxyState.ready(relativePath: relativePath)
        )
    }

    // MARK: - Helpers

    private func sourceHash(in graph: RenderGraph) throws -> ContentHash {
        try sourceNode(in: graph).contentHash
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

    private func proxyGraphMedia(id: UUID, proxyState: MediaProxyState) throws -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: URL(fileURLWithPath: "/media/source.mov"),
            contentHash: ContentHash.sha256(data: Data("source".utf8)),
            metadata: MediaMetadata(
                codecID: "h264",
                pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
                frameRate: try FrameRate(frames: 24),
                duration: try RationalTime(value: 1, timescale: 1),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            ),
            proxyState: proxyState
        )
    }

    private func proxyGraphClip(mediaID: UUID) throws -> Clip {
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
            name: "Proxy"
        )
    }

    private func proxyGraphSequence(clip: Clip) throws -> Sequence {
        Sequence(
            id: UUID(),
            name: "Proxy",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.clip(clip)])],
            audioTracks: [],
            markers: [],
            timebase: try FrameRate(frames: 24)
        )
    }

    private func proxyGraphProject(
        media: MediaRef,
        sequence: Sequence,
        preferProxy: Bool
    ) throws -> Project {
        Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: sequence.timebase,
                resolution: PixelDimensions(width: 64, height: 36),
                colorSpace: .rec709,
                audioSampleRate: 48_000,
                preferProxyPlayback: preferProxy
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
    }
}
