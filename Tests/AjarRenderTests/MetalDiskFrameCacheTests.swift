// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import XCTest

final class MetalDiskFrameCacheTests: XCTestCase {
    private var cacheDirectoryURL: URL?

    override func tearDown() {
        if let cacheDirectoryURL {
            try? FileManager.default.removeItem(at: cacheDirectoryURL)
        }
        cacheDirectoryURL = nil
        super.tearDown()
    }

    func testFRPLAY005ProcessRestartServesWarmDiskEntryWithCorrectPixels() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let graph = try makeDiskCacheTestGraph()
        let contentHash = try XCTUnwrap(graph.outputNode).contentHash
        let output = makeOutput()
        let expectedPixels = try await persistWarmEntry(
            device: device,
            directory: directory,
            graph: graph,
            output: output
        )

        // Simulated process restart: a brand-new executor and cache over the same directory.
        let restartedCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let restartedExecutor = try MetalRenderExecutor(device: device, diskCache: restartedCache)
        restartedExecutor.prefetchCachedFrame(contentHash: contentHash, output: output)
        restartedCache.waitUntilIdle()

        XCTAssertEqual(restartedCache.diskHitCount, 1)
        XCTAssertEqual(restartedExecutor.diskPopulatedFrameCount, 1)

        let warmFrame = try restartedExecutor.render(
            graph: graph,
            output: output,
            sourceProvider: ClosureRenderSourceTextureProvider { _ in
                throw DiskCacheTestError.unexpectedSourceRequest
            }
        )
        XCTAssertTrue(warmFrame.cacheHit)
        XCTAssertEqual(warmFrame.cacheDisposition, .ramHit)
        XCTAssertEqual(
            try readDiskCacheBGRA8(texture: warmFrame.texture, device: device),
            expectedPixels
        )
    }

    func testFRPLAY005RenderPathMissIsTypedAndConsultsDiskAsynchronously() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let graph = try makeDiskCacheTestGraph()
        let output = makeOutput()
        _ = try await persistWarmEntry(
            device: device,
            directory: directory,
            graph: graph,
            output: output
        )

        let restartedCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let restartedExecutor = try MetalRenderExecutor(device: device, diskCache: restartedCache)
        let provider = CountingDiskCacheSourceProvider(
            texture: try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])
        )

        // The RAM miss returns a typed miss and renders normally instead of stalling on disk.
        let missFrame = try restartedExecutor.render(
            graph: graph,
            output: output,
            sourceProvider: provider
        )
        XCTAssertEqual(missFrame.cacheDisposition, .missRenderedDiskLookupScheduled)
        XCTAssertFalse(missFrame.cacheHit)
        try waitForDiskCacheRender(missFrame)

        restartedCache.waitUntilIdle()
        XCTAssertEqual(restartedExecutor.diskPopulatedFrameCount, 1)

        let warmFrame = try restartedExecutor.render(
            graph: graph,
            output: output,
            sourceProvider: provider
        )
        XCTAssertEqual(warmFrame.cacheDisposition, .ramHit)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testFRPLAY005MissWithoutDiskTierIsTypedAsPlainMiss() throws {
        let device = try diskCacheTestDevice()
        let graph = try makeDiskCacheTestGraph()
        let executor = try MetalRenderExecutor(device: device)

        let frame = try executor.render(
            graph: graph,
            output: makeOutput(),
            sourceProvider: ClosureRenderSourceTextureProvider { [device] _ in
                try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])
            }
        )

        XCTAssertEqual(frame.cacheDisposition, .missRendered)
        try waitForDiskCacheRender(frame)
    }

    func testFRCMP006EditChangedContentHashMakesOldDiskEntryUnreachable() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let graph = try makeDiskCacheTestGraph(positionX: 0)
        let editedGraph = try makeDiskCacheTestGraph(positionX: 1)
        let contentHash = try XCTUnwrap(graph.outputNode).contentHash
        let editedContentHash = try XCTUnwrap(editedGraph.outputNode).contentHash
        XCTAssertNotEqual(contentHash, editedContentHash)

        let output = makeOutput()
        _ = try await persistWarmEntry(
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
        let output = makeOutput()
        _ = try await persistWarmEntry(
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
        let output = makeOutput()
        _ = try await persistWarmEntry(
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
        _ = try await persistWarmEntry(
            device: device,
            directory: directory,
            graph: graph,
            output: makeOutput()
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

    func testFRPLAY005DiskEvictionRespectsByteBudgetDeterministically() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let output = makeOutput()
        let entrySize = try makeEntryByteCount(graphPositionX: 0)
        let diskCache = try MetalDiskFrameCache(
            device: device,
            directoryURL: directory,
            byteBudget: entrySize * 2
        )
        let executor = try MetalRenderExecutor(device: device, diskCache: diskCache)

        for positionX in Int64(0)...2 {
            try await renderAndPersist(
                positionX: positionX,
                device: device,
                executor: executor,
                diskCache: diskCache,
                output: output
            )
        }

        // Three same-sized entries against a two-entry budget: the oldest is evicted.
        XCTAssertEqual(diskCache.storedEntryCount, 2)
        XCTAssertEqual(diskCache.storedByteCount, entrySize * 2)
        XCTAssertEqual(
            try diskCacheEntryFileNames(in: directory),
            try expectedEntryFileNames(graphPositionsX: [1, 2])
        )

        // A disk hit refreshes recency, so the next insert evicts the untouched entry.
        let refreshedHash = try XCTUnwrap(
            try makeDiskCacheTestGraph(positionX: 1).outputNode
        ).contentHash
        let freshExecutor = try MetalRenderExecutor(device: device, diskCache: diskCache)
        freshExecutor.prefetchCachedFrame(contentHash: refreshedHash, output: output)
        diskCache.waitUntilIdle()
        try await renderAndPersist(
            positionX: 3,
            device: device,
            executor: executor,
            diskCache: diskCache,
            output: output
        )

        XCTAssertEqual(
            try diskCacheEntryFileNames(in: directory),
            try expectedEntryFileNames(graphPositionsX: [1, 3])
        )
    }

    func testNFRSTAB004ConcurrentRenderPersistAndPrefetchSynchronize() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let output = makeOutput()
        let diskCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let executor = try MetalRenderExecutor(device: device, diskCache: diskCache)
        let sourceTexture = try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for iteration in 0..<24 {
                group.addTask {
                    let graph = try makeDiskCacheTestGraph(positionX: Int64(iteration % 4))
                    let contentHash = graph.outputNode?.contentHash
                    let frame = try executor.render(
                        graph: graph,
                        output: output,
                        sourceProvider: ClosureRenderSourceTextureProvider { _ in sourceTexture }
                    )
                    try await diskCache.persist(frame: frame, output: output)
                    if let contentHash {
                        executor.prefetchCachedFrame(contentHash: contentHash, output: output)
                    }
                }
            }
            try await group.waitForAll()
        }
        diskCache.waitUntilIdle()

        XCTAssertEqual(diskCache.storedEntryCount, 4)
        let finalFrame = try executor.render(
            graph: try makeDiskCacheTestGraph(positionX: 0),
            output: output,
            sourceProvider: ClosureRenderSourceTextureProvider { _ in sourceTexture }
        )
        try waitForDiskCacheRender(finalFrame)
        XCTAssertEqual(
            try readDiskCacheBGRA8(texture: finalFrame.texture, device: device).count,
            4
        )
    }

}

// MARK: - Helpers

extension MetalDiskFrameCacheTests {
    private func makeTrackedDirectory() throws -> URL {
        let directory = try makeDiskCacheTestDirectory()
        cacheDirectoryURL = directory
        return directory
    }

    private func makeOutput() -> RenderOutputDescriptor {
        RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1))
    }

    /// Renders the graph once and persists it through the offline population route, returning
    /// the rendered pixels for later comparison.
    private func persistWarmEntry(
        device: MTLDevice,
        directory: URL,
        graph: RenderGraph,
        output: RenderOutputDescriptor
    ) async throws -> [UInt8] {
        let diskCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let executor = try MetalRenderExecutor(device: device, diskCache: diskCache)
        let frame = try executor.render(
            graph: graph,
            output: output,
            sourceProvider: ClosureRenderSourceTextureProvider { [device] _ in
                try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])
            }
        )
        try await diskCache.persist(frame: frame, output: output)
        return try readDiskCacheBGRA8(texture: frame.texture, device: device)
    }

    private func renderAndPersist(
        positionX: Int64,
        device: MTLDevice,
        executor: MetalRenderExecutor,
        diskCache: MetalDiskFrameCache,
        output: RenderOutputDescriptor
    ) async throws {
        let frame = try executor.render(
            graph: try makeDiskCacheTestGraph(positionX: positionX),
            output: output,
            sourceProvider: ClosureRenderSourceTextureProvider { [device] _ in
                try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])
            }
        )
        try await diskCache.persist(frame: frame, output: output)
    }

    private func makeEntryByteCount(graphPositionX: Int64) throws -> Int {
        let contentHash = try XCTUnwrap(
            try makeDiskCacheTestGraph(positionX: graphPositionX).outputNode
        ).contentHash
        let identity = RenderFrameCacheIdentity(
            contentHash: contentHash,
            colorModeRawValue: 0,
            pixelFormatRawValue: UInt32(clamping: MTLPixelFormat.bgra8Unorm.rawValue),
            width: 1,
            height: 1
        )
        return RenderFrameDiskCacheEntry(
            identity: identity,
            bytesPerRow: 4,
            payload: Data([0, 0, 0, 0])
        ).encoded().count
    }

    private func expectedEntryFileNames(graphPositionsX: [Int64]) throws -> [String] {
        try graphPositionsX
            .map { positionX -> String in
                let contentHash = try XCTUnwrap(
                    try makeDiskCacheTestGraph(positionX: positionX).outputNode
                ).contentHash
                return RenderFrameCacheIdentity(
                    contentHash: contentHash,
                    colorModeRawValue: 0,
                    pixelFormatRawValue: UInt32(clamping: MTLPixelFormat.bgra8Unorm.rawValue),
                    width: 1,
                    height: 1
                ).entryFileName
            }
            .sorted()
    }

    private func diskCacheEntryFileNames(in directory: URL) throws -> [String] {
        try diskCacheEntryFileURLs(in: directory).map(\.lastPathComponent)
    }
}

private final class CountingDiskCacheSourceProvider: RenderSourceTextureProvider {
    private let texture: MTLTexture
    private let lock = NSLock()
    private var requestCountValue = 0

    init(texture: MTLTexture) {
        self.texture = texture
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCountValue
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        lock.lock()
        requestCountValue += 1
        lock.unlock()
        return texture
    }
}
