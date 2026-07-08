// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarRender

/// Read-time integrity of the disk frame cache tier: invalid entries always read as a miss and
/// are quarantined — never wrong pixels (FR-PLAY-005, FR-CMP-006).
final class MetalDiskFrameCacheIntegrityTests: XCTestCase {
    private var cacheDirectoryURL: URL?

    override func tearDown() {
        if let cacheDirectoryURL {
            try? FileManager.default.removeItem(at: cacheDirectoryURL)
        }
        cacheDirectoryURL = nil
        super.tearDown()
    }

    func testFRCMP006EditChangedContentHashMakesOldDiskEntryUnreachable() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let graph = try makeDiskCacheTestGraph(positionX: 0)
        let editedGraph = try makeDiskCacheTestGraph(positionX: 1)
        let contentHash = try XCTUnwrap(graph.outputNode).contentHash
        let editedContentHash = try XCTUnwrap(editedGraph.outputNode).contentHash
        XCTAssertNotEqual(contentHash, editedContentHash)

        let output = makeDiskCacheOutput()
        _ = try await persistDiskCacheWarmEntry(
            device: device,
            directory: directory,
            graph: graph,
            output: output
        )

        let restartedCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let restartedExecutor = try MetalRenderExecutor(device: device, diskCache: restartedCache)
        restartedExecutor.prefetchCachedFrame(contentHash: editedContentHash, output: output)
        restartedCache.waitUntilIdle()

        XCTAssertEqual(restartedCache.diskMissCount, 1)
        XCTAssertEqual(restartedExecutor.diskPopulatedFrameCount, 0)
        XCTAssertEqual(try diskCacheEntryFileURLs(in: directory).count, 1)
    }

    func testFRPLAY005CorruptDiskEntryReadsAsMissAndIsQuarantined() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let graph = try makeDiskCacheTestGraph()
        let contentHash = try XCTUnwrap(graph.outputNode).contentHash
        let output = makeDiskCacheOutput()
        _ = try await persistDiskCacheWarmEntry(
            device: device,
            directory: directory,
            graph: graph,
            output: output
        )

        let entryURL = try XCTUnwrap(try diskCacheEntryFileURLs(in: directory).first)
        var entryData = try Data(contentsOf: entryURL)
        let lastIndex = entryData.index(before: entryData.endIndex)
        entryData[lastIndex] = entryData[lastIndex] &+ 1
        try entryData.write(to: entryURL)

        let restartedCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let restartedExecutor = try MetalRenderExecutor(device: device, diskCache: restartedCache)
        restartedExecutor.prefetchCachedFrame(contentHash: contentHash, output: output)
        restartedCache.waitUntilIdle()

        XCTAssertEqual(restartedCache.quarantinedEntryCount, 1)
        XCTAssertEqual(restartedCache.diskMissCount, 1)
        XCTAssertEqual(restartedExecutor.diskPopulatedFrameCount, 0)
        XCTAssertEqual(try diskCacheEntryFileURLs(in: directory).count, 0)
        XCTAssertEqual(restartedCache.storedEntryCount, 0)
    }

    func testFRPLAY005TruncatedDiskEntryReadsAsMissAndIsQuarantined() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let graph = try makeDiskCacheTestGraph()
        let contentHash = try XCTUnwrap(graph.outputNode).contentHash
        let output = makeDiskCacheOutput()
        _ = try await persistDiskCacheWarmEntry(
            device: device,
            directory: directory,
            graph: graph,
            output: output
        )

        let entryURL = try XCTUnwrap(try diskCacheEntryFileURLs(in: directory).first)
        let entryData = try Data(contentsOf: entryURL)
        try Data(entryData.prefix(10)).write(to: entryURL)

        let restartedCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let restartedExecutor = try MetalRenderExecutor(device: device, diskCache: restartedCache)
        restartedExecutor.prefetchCachedFrame(contentHash: contentHash, output: output)
        restartedCache.waitUntilIdle()

        XCTAssertEqual(restartedCache.quarantinedEntryCount, 1)
        XCTAssertEqual(try diskCacheEntryFileURLs(in: directory).count, 0)
    }

    func testFRPLAY005MismatchedIdentityEntryIsQuarantinedNotServed() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let graph = try makeDiskCacheTestGraph()
        let contentHash = try XCTUnwrap(graph.outputNode).contentHash
        _ = try await persistDiskCacheWarmEntry(
            device: device,
            directory: directory,
            graph: graph,
            output: makeDiskCacheOutput()
        )

        // Masquerade the 1x1 entry as the 2x2 identity's file.
        let entryURL = try XCTUnwrap(try diskCacheEntryFileURLs(in: directory).first)
        let masqueradedName = entryURL.lastPathComponent
            .replacingOccurrences(of: "-1x1.ajarframe", with: "-2x2.ajarframe")
        XCTAssertNotEqual(masqueradedName, entryURL.lastPathComponent)
        try FileManager.default.copyItem(
            at: entryURL,
            to: directory.appendingPathComponent(masqueradedName)
        )

        let restartedCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let restartedExecutor = try MetalRenderExecutor(device: device, diskCache: restartedCache)
        let mismatchedOutput = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 2, height: 2)
        )
        restartedExecutor.prefetchCachedFrame(contentHash: contentHash, output: mismatchedOutput)
        restartedCache.waitUntilIdle()

        XCTAssertEqual(restartedCache.quarantinedEntryCount, 1)
        XCTAssertEqual(restartedExecutor.diskPopulatedFrameCount, 0)
        XCTAssertEqual(try diskCacheEntryFileURLs(in: directory).count, 1)
    }

    func testFRPLAY005RestridedEntryWithValidChecksumIsQuarantined() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let graph = try makeDiskCacheTestGraph()
        let contentHash = try XCTUnwrap(graph.outputNode).contentHash

        // A fully checksummed, identity-matching entry whose row stride is not the canonical
        // 4 bytes for 1x1 BGRA8. It decodes cleanly but must never upload as garbled pixels.
        let identity = diskCacheEntryIdentity(contentHash: contentHash)
        let restridedEntry = RenderFrameDiskCacheEntry(
            identity: identity,
            bytesPerRow: 8,
            payload: Data([255, 0, 0, 255, 0, 255, 0, 255])
        )
        try restridedEntry.encoded().write(
            to: directory.appendingPathComponent(identity.entryFileName)
        )
        XCTAssertNoThrow(try RenderFrameDiskCacheEntry.decode(restridedEntry.encoded()))

        let diskCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let executor = try MetalRenderExecutor(device: device, diskCache: diskCache)
        executor.prefetchCachedFrame(contentHash: contentHash, output: makeDiskCacheOutput())
        diskCache.waitUntilIdle()

        XCTAssertEqual(diskCache.quarantinedEntryCount, 1)
        XCTAssertEqual(executor.diskPopulatedFrameCount, 0)
        XCTAssertEqual(try diskCacheEntryFileURLs(in: directory).count, 0)
    }

    private func makeTrackedDirectory() throws -> URL {
        let directory = try makeDiskCacheTestDirectory()
        cacheDirectoryURL = directory
        return directory
    }
}
