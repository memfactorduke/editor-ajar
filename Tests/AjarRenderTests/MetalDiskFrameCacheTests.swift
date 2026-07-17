// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Darwin
import Dispatch
import Foundation
import Metal
import XCTest

// @testable grants access to the disk cache's internal suspendIO/resumeIO test hooks, used to
// force deterministic cross-thread orderings.
@testable import AjarRender

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
        let output = makeDiskCacheOutput()
        let expectedPixels = try await persistDiskCacheWarmEntry(
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
        let output = makeDiskCacheOutput()
        _ = try await persistDiskCacheWarmEntry(
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

        // Suspend the cache queue so the disk lookup deterministically completes only after the
        // render populated the RAM tier.
        restartedCache.suspendIO()
        let missFrame = try restartedExecutor.render(
            graph: graph,
            output: output,
            sourceProvider: provider
        )
        // The RAM miss returns a typed miss and renders normally instead of stalling on disk.
        XCTAssertEqual(missFrame.cacheDisposition, .missRenderedDiskLookupScheduled)
        XCTAssertFalse(missFrame.cacheHit)
        try waitForDiskCacheRender(missFrame)
        restartedCache.resumeIO()
        restartedCache.waitUntilIdle()

        // The disk hit arrived after the render stored its texture: the render-target-usable
        // rendered texture must not be replaced by the shader-read-only disk texture.
        XCTAssertEqual(restartedCache.diskHitCount, 1)
        XCTAssertEqual(restartedExecutor.diskPopulatedFrameCount, 0)

        let warmFrame = try restartedExecutor.render(
            graph: graph,
            output: output,
            sourceProvider: provider
        )
        XCTAssertEqual(warmFrame.cacheDisposition, .ramHit)
        XCTAssertTrue(warmFrame.texture === missFrame.texture)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testFRPLAY005DiskLookupIsScheduledAtMostOncePerKey() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let output = makeDiskCacheOutput()
        let diskCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        // RAM tier bounded to one entry so re-rendering a key reproduces a RAM miss.
        let executor = try MetalRenderExecutor(
            device: device,
            maximumCacheEntryCount: 1,
            diskCache: diskCache
        )
        let provider = ClosureRenderSourceTextureProvider { _ in
            try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])
        }

        let firstMiss = try executor.render(
            graph: try makeDiskCacheTestGraph(positionX: 0),
            output: output,
            sourceProvider: provider
        )
        XCTAssertEqual(firstMiss.cacheDisposition, .missRenderedDiskLookupScheduled)
        let evictingMiss = try executor.render(
            graph: try makeDiskCacheTestGraph(positionX: 1),
            output: output,
            sourceProvider: provider
        )
        XCTAssertEqual(evictingMiss.cacheDisposition, .missRenderedDiskLookupScheduled)
        diskCache.waitUntilIdle()
        XCTAssertEqual(diskCache.diskMissCount, 2)

        // The first key was evicted from RAM, but its negative disk result is remembered: the
        // playback path never schedules a second lookup for the same key.
        let repeatedMiss = try executor.render(
            graph: try makeDiskCacheTestGraph(positionX: 0),
            output: output,
            sourceProvider: provider
        )
        XCTAssertEqual(repeatedMiss.cacheDisposition, .missRendered)
        diskCache.waitUntilIdle()
        XCTAssertEqual(diskCache.diskMissCount, 2)
        try waitForDiskCacheRender(repeatedMiss)
    }

    func testFRPLAY005CacheResetDropsStaleDiskLookupResults() async throws {
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

        let restartedCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let restartedExecutor = try MetalRenderExecutor(device: device, diskCache: restartedCache)

        // Suspend the cache queue, schedule a lookup, then reset the executor cache before the
        // lookup can run: the stale result must be dropped, not repopulate a cleared cache.
        restartedCache.suspendIO()
        restartedExecutor.prefetchCachedFrame(contentHash: contentHash, output: output)
        restartedExecutor.removeAllCachedFrames()
        restartedCache.resumeIO()
        restartedCache.waitUntilIdle()

        XCTAssertEqual(restartedCache.diskHitCount, 1)
        XCTAssertEqual(restartedExecutor.diskPopulatedFrameCount, 0)
        XCTAssertEqual(restartedExecutor.cacheEntryCount, 0)
    }

    func testFRPLAY005MissWithoutDiskTierIsTypedAsPlainMiss() throws {
        let device = try diskCacheTestDevice()
        let graph = try makeDiskCacheTestGraph()
        let executor = try MetalRenderExecutor(device: device)

        let frame = try executor.render(
            graph: graph,
            output: makeDiskCacheOutput(),
            sourceProvider: ClosureRenderSourceTextureProvider { _ in
                try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])
            }
        )

        XCTAssertEqual(frame.cacheDisposition, .missRendered)
        try waitForDiskCacheRender(frame)
    }

    func testFRPLAY005DiskEvictionRespectsByteBudgetDeterministically() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let output = makeDiskCacheOutput()
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
        let output = makeDiskCacheOutput()
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

    func testNFRSTAB001CancelledQueuedPersistDoesNotPublishEntry() async throws {
        let device = try diskCacheTestDevice()
        let directory = try makeTrackedDirectory()
        let output = makeDiskCacheOutput()
        let diskCache = try MetalDiskFrameCache(device: device, directoryURL: directory)
        let executor = try MetalRenderExecutor(device: device, diskCache: diskCache)
        let frame = try executor.render(
            graph: try makeDiskCacheTestGraph(),
            output: output,
            sourceProvider: ClosureRenderSourceTextureProvider { _ in
                try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])
            }
        )

        // Hold the final serial boundary, wait until persistence is definitely queued behind it,
        // then cancel. The queued closure must observe cancellation before atomic publication.
        diskCache.suspendIO()
        var didResumeIO = false
        defer {
            if !didResumeIO {
                diskCache.resumeIO()
            }
        }
        let persistTask = Task {
            try await diskCache.persist(frame: frame, output: output)
        }
        await diskCache.waitUntilWriteQueuedForTesting()
        persistTask.cancel()
        diskCache.resumeIO()
        didResumeIO = true

        do {
            try await persistTask.value
            XCTFail("Cancelled queued persist unexpectedly published")
        } catch is CancellationError {
            // Expected lifecycle invalidation.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        diskCache.waitUntilIdle()

        XCTAssertEqual(diskCache.storedEntryCount, 0)
        XCTAssertEqual(try diskCacheEntryFileURLs(in: directory), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

}

final class MetalDiskFrameCacheCancellationTests: XCTestCase {
    func testNFRSTAB001CancellationWaitsForCommitThatAlreadyWon() async throws {
        let commitEntered = DispatchSemaphore(value: 0)
        let releaseCommit = DispatchSemaphore(value: 0)
        let cancelAttempted = DispatchSemaphore(value: 0)
        let events = PersistenceCommitEventRecorder()
        let cancellation = MetalDiskCacheWriteCancellation(
            cancelAttemptObserverForTesting: {
                cancelAttempted.signal()
            }
        )

        let commitTask = Task.detached {
            try cancellation.commit {
                commitEntered.signal()
                releaseCommit.wait()
                events.append("published")
            }
        }
        XCTAssertEqual(commitEntered.wait(timeout: .now() + 2), .success)

        let cancelTask = Task.detached {
            cancellation.cancel()
            events.append("cancel-returned")
        }
        XCTAssertEqual(cancelAttempted.wait(timeout: .now() + 2), .success)
        releaseCommit.signal()

        try await commitTask.value
        await cancelTask.value
        XCTAssertEqual(events.snapshot(), ["published", "cancel-returned"])
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testNFRSTAB001StartupRemovesOnlyStagingFilesOwnedByDeadProcesses() throws {
        let directory = try makeDiskCacheTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadProcessID = pid_t.max
        let staleURL = directory.appendingPathComponent(
            MetalDiskFrameCache.writeStagingFileName(ownerProcessID: deadProcessID)
        )
        let liveURL = directory.appendingPathComponent(
            MetalDiskFrameCache.writeStagingFileName()
        )
        try Data(repeating: 0xA5, count: 64).write(to: staleURL)
        try Data(repeating: 0x5A, count: 64).write(to: liveURL)

        _ = try MetalDiskFrameCache(
            device: diskCacheTestDevice(),
            directoryURL: directory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveURL.path))
    }
}

// MARK: - Helpers

extension MetalDiskFrameCacheTests {
    private func makeTrackedDirectory() throws -> URL {
        let directory = try makeDiskCacheTestDirectory()
        cacheDirectoryURL = directory
        return directory
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
            sourceProvider: ClosureRenderSourceTextureProvider { _ in
                try makeDiskCacheSolidTexture(device: device, bgra: [0, 0, 255, 255])
            }
        )
        try await diskCache.persist(frame: frame, output: output)
    }

    private func makeEntryByteCount(graphPositionX: Int64) throws -> Int {
        let contentHash = try XCTUnwrap(
            try makeDiskCacheTestGraph(positionX: graphPositionX).outputNode
        ).contentHash
        return RenderFrameDiskCacheEntry(
            identity: diskCacheEntryIdentity(contentHash: contentHash),
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
                return diskCacheEntryIdentity(contentHash: contentHash).entryFileName
            }
            .sorted()
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

private final class PersistenceCommitEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock {
            events.append(event)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}
