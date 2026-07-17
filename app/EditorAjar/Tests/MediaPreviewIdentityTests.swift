// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarMedia
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class MediaPreviewIdentityTests: XCTestCase {
    func testDurableTranscodesCoalesceByPlayableHashAndSeparateChangedPlayableBytes() async throws {
        let root = try temporaryDirectory(named: "durable-playable-identity")
        let probe = PreviewExtractionProbe()
        let cache = MediaPreviewCache(packageURL: root, workerLimit: 2) { _, _ in
            await probe.recordCall()
            try await Task.sleep(for: .milliseconds(30))
            return Self.minimalPNGData
        }
        let originalHash = ContentHash.sha256(data: Data("same-original".utf8))
        let playableA = ContentHash.sha256(data: Data("playable-a".utf8))
        let playableB = ContentHash.sha256(data: Data("playable-b".utf8))
        let firstA = try transcodedMedia(
            sourceURL: root.appendingPathComponent("working-a.mov"),
            originalHash: originalHash,
            playableHash: playableA
        )
        let secondA = try transcodedMedia(
            sourceURL: root.appendingPathComponent("same-working-a.mov"),
            originalHash: originalHash,
            playableHash: playableA
        )
        let changedB = try transcodedMedia(
            sourceURL: root.appendingPathComponent("working-b.mov"),
            originalHash: originalHash,
            playableHash: playableB
        )

        async let first = cache.data(for: firstA, kind: .thumbnail)
        async let duplicate = cache.data(for: secondA, kind: .thumbnail)
        _ = try await (first, duplicate)
        _ = try await cache.data(for: changedB, kind: .thumbnail)

        let durableExtractionCount = await probe.callCount
        XCTAssertEqual(durableExtractionCount, 2)
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("thumbnails", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 2)
    }

    func testCancelingOneCoalescedWaiterPreservesTheSurvivor() async throws {
        let root = try temporaryDirectory(named: "coalesced-waiter-cancellation")
        let media = try ordinaryMedia(
            sourceURL: root.appendingPathComponent("shared.mov"),
            contentHash: ContentHash.sha256(data: Data("shared".utf8))
        )
        let probe = ControlledPreviewProbe(blockedCalls: [1])
        let cache = MediaPreviewCache(packageURL: root) { media, kind in
            try await probe.extract(media: media, kind: kind)
        }

        let canceledWaiter = Task { try await cache.data(for: media, kind: .thumbnail) }
        try await waitUntil { await probe.hasStarted(call: 1) }
        let survivingWaiter = Task { try await cache.data(for: media, kind: .thumbnail) }
        try await waitUntil {
            await cache.waiterCountForTesting(for: media, kind: .thumbnail) == 2
        }

        canceledWaiter.cancel()
        do {
            _ = try await canceledWaiter.value
            XCTFail("the canceled waiter must not receive the shared result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let survivingWaiterCount =
            await cache.waiterCountForTesting(for: media, kind: .thumbnail)
        XCTAssertEqual(survivingWaiterCount, 1)

        await probe.release(call: 1)
        let survivingData = try await survivingWaiter.value
        let extractionCount = await probe.extractionCount
        XCTAssertEqual(survivingData, Data("thumbnail-1".utf8))
        XCTAssertEqual(extractionCount, 1)
    }

    func testCancelingFinalWaiterCancelsUnderlyingExtraction() async throws {
        let root = try temporaryDirectory(named: "final-waiter-cancellation")
        let media = try ordinaryMedia(
            sourceURL: root.appendingPathComponent("only.mov"),
            contentHash: ContentHash.sha256(data: Data("only".utf8))
        )
        let probe = CancellationAwarePreviewProbe()
        let cache = MediaPreviewCache(packageURL: root) { media, kind in
            try await probe.extract(media: media, kind: kind)
        }

        let waiter = Task { try await cache.data(for: media, kind: .thumbnail) }
        try await waitUntil { await probe.hasStarted }
        try await waitUntil {
            await cache.waiterCountForTesting(for: media, kind: .thumbnail) == 1
        }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("the final canceled waiter must throw cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        try await waitUntil { await probe.wasCancelled }
        let remainingWaiterCount =
            await cache.waiterCountForTesting(for: media, kind: .thumbnail)
        XCTAssertEqual(remainingWaiterCount, 0)
    }

    func testLegacyTranscodeUsesFileRevisionAndNeverAliasesOriginalHash() async throws {
        let root = try temporaryDirectory(named: "legacy-revision-identity")
        let sourceURL = root.appendingPathComponent("legacy-working.mov")
        try Data("legacy-working-a".utf8).write(to: sourceURL)
        let originalHash = ContentHash.sha256(data: Data("legacy-original".utf8))
        let ordinary = try ordinaryMedia(
            sourceURL: root.appendingPathComponent("ordinary.mov"),
            contentHash: originalHash
        )
        let legacy = try transcodedMedia(
            sourceURL: sourceURL,
            originalHash: originalHash,
            playableHash: nil
        )
        let probe = PreviewExtractionProbe()
        let cache = MediaPreviewCache(packageURL: root, workerLimit: 1) { _, _ in
            await probe.recordCall()
            return Self.minimalPNGData
        }

        _ = try await cache.data(for: ordinary, kind: .thumbnail)
        _ = try await cache.data(for: legacy, kind: .thumbnail)
        _ = try await cache.data(for: legacy, kind: .thumbnail)
        let unchangedExtractionCount = await probe.callCount
        XCTAssertEqual(unchangedExtractionCount, 2, "unchanged revision must hit its cache")

        try Data("legacy-working-b-with-a-different-size".utf8).write(
            to: sourceURL,
            options: .atomic
        )
        _ = try await cache.data(for: legacy, kind: .thumbnail)

        let replacedExtractionCount = await probe.callCount
        XCTAssertEqual(replacedExtractionCount, 3, "atomic replacement must regenerate")
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("thumbnails", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 3, "ordinary, old legacy, and new legacy keys stay distinct")
    }

    func testProductionThumbnailVerificationRejectsReplacementDuringDecode() async throws {
        let root = try temporaryDirectory(named: "thumbnail-source-replacement")
        let sourceURL = root.appendingPathComponent("source.mov")
        let originalData = Data("thumbnail-source-before".utf8)
        try originalData.write(to: sourceURL)
        let media = try ordinaryMedia(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: originalData)
        )

        do {
            _ = try await MediaPreviewCache.extractVerifiedThumbnailPNG(
                media: media,
                at: .zero
            ) { _, _ in
                try Data("thumbnail-source-after-with-a-new-size".utf8).write(
                    to: sourceURL,
                    options: .atomic
                )
                return Self.minimalPNGData
            }
            XCTFail("a thumbnail decoded across a source replacement must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MediaSourceIdentityVerificationError,
                .sourceChangedDuringRead(sourceURL.standardizedFileURL)
            )
        }
    }

    func testTaskIdentityTracksURLAvailabilityPlayableHashAndLegacyState() throws {
        let mediaID = UUID()
        let originalHash = ContentHash.sha256(data: Data("identity-original".utf8))
        let playableA = ContentHash.sha256(data: Data("identity-a".utf8))
        let playableB = ContentHash.sha256(data: Data("identity-b".utf8))
        let normalizedURL = URL(fileURLWithPath: "/tmp/editor-ajar-preview.mov")
        let unnormalizedURL = URL(fileURLWithPath: "/tmp/folder/../editor-ajar-preview.mov")
        let first = try transcodedMedia(
            id: mediaID,
            sourceURL: unnormalizedURL,
            originalHash: originalHash,
            playableHash: playableA
        )
        let equivalentURL = try transcodedMedia(
            id: mediaID,
            sourceURL: normalizedURL,
            originalHash: originalHash,
            playableHash: playableA
        )
        let offline = try transcodedMedia(
            id: mediaID,
            sourceURL: normalizedURL,
            originalHash: originalHash,
            playableHash: playableA,
            availability: .offline
        )
        let changedPlayable = try transcodedMedia(
            id: mediaID,
            sourceURL: normalizedURL,
            originalHash: originalHash,
            playableHash: playableB
        )
        let legacy = try transcodedMedia(
            id: mediaID,
            sourceURL: normalizedURL,
            originalHash: originalHash,
            playableHash: nil
        )

        XCTAssertEqual(
            MediaPreviewTaskIdentity(media: first),
            MediaPreviewTaskIdentity(media: equivalentURL)
        )
        XCTAssertNotEqual(
            MediaPreviewTaskIdentity(media: first),
            MediaPreviewTaskIdentity(media: offline)
        )
        XCTAssertNotEqual(
            MediaPreviewTaskIdentity(media: first),
            MediaPreviewTaskIdentity(media: changedPlayable)
        )
        XCTAssertNotEqual(
            MediaPreviewTaskIdentity(media: first),
            MediaPreviewTaskIdentity(media: legacy)
        )
    }
}
