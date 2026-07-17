// SPDX-License-Identifier: GPL-3.0-or-later

import AjarRender
import Foundation
import Metal
import XCTest

@testable import EditorAjar

final class EditorAjarRenderPipelineCacheTests: XCTestCase {
    func testFRPLAY005FreshRenderWritesBehindAndReloadsAfterRAMEviction() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable")
        }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-disk-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let coordinator = DiskWriteBehindCoordinator(maximumConcurrentWrites: 2)
        let pipeline = try EditorAjarRenderPipeline(
            cacheDirectoryURL: cacheDirectory,
            writeBehindCoordinator: coordinator
        )
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)
        let output = RenderOutputDescriptor(pixelDimensions: project.settings.resolution)

        let first = try await pipeline.renderFrame(
            project: project,
            sequence: sequence,
            frame: 0
        )
        await pipeline.waitForDiskWriteBehindForTesting()
        pipeline.removeAllCachedFramesForTesting()
        pipeline.prefetchCachedFrameForTesting(contentHash: first.contentHash, output: output)
        pipeline.waitForDiskCacheIOForTesting()
        XCTAssertEqual(pipeline.diskPopulatedFrameCountForTesting, 1)

        let reloaded = try await pipeline.renderFrame(
            project: project,
            sequence: sequence,
            frame: 0,
            allowDiskWriteBehind: false
        )
        XCTAssertEqual(reloaded.cacheDisposition, .ramHit)
        await pipeline.shutdownDiskWriteBehind()
    }

    func testNFRSTAB001WriteBehindConcurrencyIsProcessWideAcrossPipelineTeardown() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-disk-cache-stress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DiskWriteBehindCoordinator(maximumConcurrentWrites: 2)
        let gate = DiskWriteBehindTestGate()
        let pipelineCount = 24
        var pipelines = try (0..<pipelineCount).map { index in
            try EditorAjarRenderPipeline(
                cacheDirectoryURL: root.appendingPathComponent("pipeline-\(index)"),
                writeBehindCoordinator: coordinator
            )
        }

        var acceptedCount = 0
        for pipeline in pipelines {
            let accepted = await pipeline.submitDiskWriteBehindForTesting { _ in
                await gate.run()
            }
            if accepted {
                acceptedCount += 1
            }
        }
        await gate.waitUntilStarted(2)

        var snapshot = await coordinator.snapshot()
        XCTAssertEqual(acceptedCount, 2)
        XCTAssertEqual(snapshot.activeWriteCount, 2)
        XCTAssertEqual(snapshot.peakActiveWriteCount, 2)
        XCTAssertEqual(snapshot.ownerCount, 2)
        XCTAssertEqual(snapshot.droppedWriteCount, pipelineCount - 2)

        // Releasing every pipeline exercises the synchronous deinit close. The coordinator still
        // owns the two physical tasks and reports idle only after both have actually returned.
        pipelines.removeAll()
        await gate.releaseAll()
        await coordinator.waitUntilIdleForTesting()

        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activeWriteCount, 0)
        XCTAssertEqual(snapshot.ownerCount, 0)
        XCTAssertEqual(snapshot.peakActiveWriteCount, 2)
    }

    func testNFRSTAB001ProjectReplacementCancelsObsoletePublication() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable")
        }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-disk-cache-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let coordinator = DiskWriteBehindCoordinator(maximumConcurrentWrites: 1)
        let pipeline = try EditorAjarRenderPipeline(
            cacheDirectoryURL: cacheDirectory,
            writeBehindCoordinator: coordinator
        )
        let gate = DiskWriteBehindTestGate()
        let publications = DiskWriteBehindPublicationProbe()

        let obsoleteAccepted = await pipeline.submitDiskWriteBehindForTesting { cancellation in
            await gate.run()
            if !cancellation.isCancelled {
                await publications.publish()
            }
        }
        XCTAssertTrue(obsoleteAccepted)
        await gate.waitUntilStarted(1)
        pipeline.beginNewProjectSession()
        await gate.releaseAll()
        await pipeline.waitForDiskWriteBehindForTesting()
        var publicationCount = await publications.count
        XCTAssertEqual(publicationCount, 0)

        // A replacement invalidates only the old generation; the reusable pipeline accepts work
        // for its new project immediately.
        let replacementAccepted = await pipeline.submitDiskWriteBehindForTesting { cancellation in
            if !cancellation.isCancelled {
                await publications.publish()
            }
        }
        XCTAssertTrue(replacementAccepted)
        await pipeline.waitForDiskWriteBehindForTesting()
        publicationCount = await publications.count
        XCTAssertEqual(publicationCount, 1)
        await pipeline.shutdownDiskWriteBehind()
    }

    func testNFRSTAB001RetiredGenerationRejectsWriteThatSubmitsAfterReplacement() async throws {
        let coordinator = DiskWriteBehindCoordinator(maximumConcurrentWrites: 1)
        let tracker = DiskWriteBehindTracker(coordinator: coordinator)
        let obsoleteSession = try XCTUnwrap(tracker.captureSession())
        let publications = DiskWriteBehindPublicationProbe()

        let cancelledCapture = Task {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                // Continue inside the cancelled render task to exercise the capture boundary.
            }
            return tracker.captureSession()
        }
        cancelledCapture.cancel()
        let capturedAfterCancellation = await cancelledCapture.value
        XCTAssertNil(capturedAfterCancellation)

        tracker.beginNewSession()
        let obsoleteAccepted = await tracker.submit(session: obsoleteSession) { _ in
            await publications.publish()
        }
        XCTAssertFalse(obsoleteAccepted)

        let replacementSession = try XCTUnwrap(tracker.captureSession())
        let replacementAccepted = await tracker.submit(session: replacementSession) { _ in
            await publications.publish()
        }
        XCTAssertTrue(replacementAccepted)
        await tracker.waitForAll()
        let publicationCount = await publications.count
        XCTAssertEqual(publicationCount, 1)
        await tracker.shutdownAndWait()
    }

    func testNFRSTAB001ShutdownRejectsLateWritesAndDrainsAcceptedWork() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable")
        }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-disk-cache-shutdown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let coordinator = DiskWriteBehindCoordinator(maximumConcurrentWrites: 1)
        let pipeline = try EditorAjarRenderPipeline(
            cacheDirectoryURL: cacheDirectory,
            writeBehindCoordinator: coordinator
        )
        let gate = DiskWriteBehindTestGate()
        let publications = DiskWriteBehindPublicationProbe()

        let accepted = await pipeline.submitDiskWriteBehindForTesting { cancellation in
            await gate.run()
            if !cancellation.isCancelled {
                await publications.publish()
            }
        }
        XCTAssertTrue(accepted)
        await gate.waitUntilStarted(1)
        pipeline.cancelDiskWriteBehind()
        let lateAccepted = await pipeline.submitDiskWriteBehindForTesting { _ in }
        XCTAssertFalse(lateAccepted)
        await gate.releaseAll()
        await pipeline.shutdownDiskWriteBehind()

        let publicationCount = await publications.count
        XCTAssertEqual(publicationCount, 0)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activeWriteCount, 0)
        XCTAssertEqual(snapshot.ownerCount, 0)
    }
}

private actor DiskWriteBehindTestGate {
    private var startedCount = 0
    private var isReleased = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func run() async {
        startedCount += 1
        resumeStartedWaiters()
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    func waitUntilStarted(_ count: Int) async {
        guard startedCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        isReleased = true
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeStartedWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in startedWaiters {
            if startedCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        startedWaiters = remaining
    }
}

private actor DiskWriteBehindPublicationProbe {
    private(set) var count = 0

    func publish() {
        count += 1
    }
}
