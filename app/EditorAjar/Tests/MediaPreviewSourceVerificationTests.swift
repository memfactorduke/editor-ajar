// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
extension MediaPreviewIdentityTests {
    func testDurableCacheHitRejectsURLWhoseBytesDoNotMatchClaimedHash() async throws {
        let root = try temporaryDirectory(named: "durable-cache-source-verification")
        let expectedData = Data("durable-expected".utf8)
        let expectedHash = ContentHash.sha256(data: expectedData)
        let validURL = root.appendingPathComponent("valid.mov")
        let mismatchedURL = root.appendingPathComponent("mismatched.mov")
        try writePlayableSource(expectedData, to: validURL)
        let mismatchedData = Data("durable-mismatched-bytes".utf8)
        try writePlayableSource(mismatchedData, to: mismatchedURL)
        let valid = try ordinaryMedia(sourceURL: validURL, contentHash: expectedHash)
        let mismatched = try ordinaryMedia(sourceURL: mismatchedURL, contentHash: expectedHash)
        let probe = PreviewExtractionProbe()
        let cache = MediaPreviewCache(packageURL: root) { _, _ in
            await probe.recordCall()
            return Self.minimalPNGData
        }

        _ = try await cache.data(for: valid, kind: .thumbnail)
        let validCachedData = await cache.cachedData(for: valid, kind: .thumbnail)
        let mismatchedCachedData = await cache.cachedData(for: mismatched, kind: .thumbnail)
        XCTAssertEqual(validCachedData, Self.minimalPNGData)
        XCTAssertNil(mismatchedCachedData)
        do {
            _ = try await cache.data(for: mismatched, kind: .thumbnail)
            XCTFail("a cache hit must independently verify the requesting source URL")
        } catch {
            XCTAssertEqual(
                error as? MediaSourceIdentityVerificationError,
                .playableContentHashMismatch(
                    url: mismatchedURL.standardizedFileURL,
                    expected: expectedHash,
                    actual: ContentHash.sha256(data: mismatchedData)
                )
            )
        }
        let extractionCount = await probe.callCount
        XCTAssertEqual(extractionCount, 1)
    }

    func testDurableCoalescingRejectsASecondURLWithMismatchedBytes() async throws {
        let root = try temporaryDirectory(named: "durable-coalesced-source-verification")
        let expectedData = Data("coalesced-expected".utf8)
        let expectedHash = ContentHash.sha256(data: expectedData)
        let validURL = root.appendingPathComponent("valid.mov")
        let mismatchedURL = root.appendingPathComponent("mismatched.mov")
        try writePlayableSource(expectedData, to: validURL)
        let mismatchedData = Data("coalesced-mismatched".utf8)
        try writePlayableSource(mismatchedData, to: mismatchedURL)
        let valid = try ordinaryMedia(sourceURL: validURL, contentHash: expectedHash)
        let mismatched = try ordinaryMedia(sourceURL: mismatchedURL, contentHash: expectedHash)
        let probe = ControlledPreviewProbe(blockedCalls: [1])
        let cache = MediaPreviewCache(packageURL: root) { media, kind in
            try await probe.extract(media: media, kind: kind)
        }

        let validRequest = Task { try await cache.data(for: valid, kind: .thumbnail) }
        try await waitUntil { await probe.hasStarted(call: 1) }
        do {
            _ = try await cache.data(for: mismatched, kind: .thumbnail)
            XCTFail("a second URL must prove its bytes before joining shared work")
        } catch {
            XCTAssertEqual(
                error as? MediaSourceIdentityVerificationError,
                .playableContentHashMismatch(
                    url: mismatchedURL.standardizedFileURL,
                    expected: expectedHash,
                    actual: ContentHash.sha256(data: mismatchedData)
                )
            )
        }
        let waiterCount = await cache.waiterCountForTesting(for: valid, kind: .thumbnail)
        XCTAssertEqual(waiterCount, 1)
        await probe.release(call: 1)
        _ = try await validRequest.value
        let extractionCount = await probe.extractionCount
        XCTAssertEqual(extractionCount, 1)
    }

    func testDurableCoalescedWaiterRejectsSourceReplacementAfterJoining() async throws {
        let root = try temporaryDirectory(named: "durable-coalesced-post-verification")
        let expectedData = Data("coalesced-stable".utf8)
        let expectedHash = ContentHash.sha256(data: expectedData)
        let firstURL = root.appendingPathComponent("first.mov")
        let secondURL = root.appendingPathComponent("second.mov")
        try writePlayableSource(expectedData, to: firstURL)
        try writePlayableSource(expectedData, to: secondURL)
        let first = try ordinaryMedia(sourceURL: firstURL, contentHash: expectedHash)
        let second = try ordinaryMedia(sourceURL: secondURL, contentHash: expectedHash)
        let probe = ControlledPreviewProbe(blockedCalls: [1])
        let cache = MediaPreviewCache(packageURL: root) { media, kind in
            try await probe.extract(media: media, kind: kind)
        }

        let firstRequest = Task { try await cache.data(for: first, kind: .thumbnail) }
        try await waitUntil { await probe.hasStarted(call: 1) }
        let secondRequest = Task { try await cache.data(for: second, kind: .thumbnail) }
        try await waitUntil {
            await cache.waiterCountForTesting(for: first, kind: .thumbnail) == 2
        }
        try writePlayableSource(Data("second-was-replaced".utf8), to: secondURL)
        await probe.release(call: 1)

        let firstData = try await firstRequest.value
        XCTAssertEqual(firstData, Data("thumbnail-1".utf8))
        do {
            _ = try await secondRequest.value
            XCTFail("each shared waiter must revalidate its own URL after extraction")
        } catch {
            XCTAssertEqual(
                error as? MediaSourceIdentityVerificationError,
                .sourceChangedDuringRead(secondURL.standardizedFileURL)
            )
        }
        let extractionCount = await probe.extractionCount
        XCTAssertEqual(extractionCount, 1)
    }
}
