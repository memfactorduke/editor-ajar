// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import XCTest

@testable import AjarCore
@testable import AjarMedia

final class VideoFrameDecoderConcurrencyTests: XCTestCase {
    func testNFRSTAB001ConcurrentDecodesBeyondDispatchSoftLimitStayBounded() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let url = try temporaryMovieURL()
        try SyntheticMovieWriter.writeMovie(
            to: url,
            width: 16,
            height: 16,
            frameCount: 3,
            frameRate: 24
        )

        XCTAssertEqual(VideoFrameDecoder.maximumConcurrentVideoDecodes, 4)

        // The old unbounded GCD queue could create one blocked worker per request and cross the
        // process soft limit (70 on macOS). Keep this count above that regression threshold.
        let failures = try await withTimeout(seconds: 30) {
            await Self.decodeConcurrently(
                count: 80,
                device: device,
                sourceURL: url
            )
        }

        XCTAssertTrue(failures.isEmpty, "Decode failures: \(failures)")
    }

    func testNFRSTAB001BlockingDecodeExecutorNeverExceedsConfiguredWidth() async throws {
        let maximumConcurrentCount = 2
        let executor = BoundedVideoDecodeExecutor(
            label: "org.editorajar.video-frame-decode-tests",
            maximumConcurrentOperationCount: maximumConcurrentCount
        )
        let tracker = BlockingWorkTracker(saturationCount: maximumConcurrentCount)
        let release = DispatchSemaphore(value: 0)
        let workCount = 8

        let tasks = (0..<workCount).map { _ in
            Task {
                try await executor.run { _ in
                    tracker.enter()
                    defer { tracker.leave() }
                    release.wait()
                }
            }
        }

        await fulfillment(of: [tracker.saturated], timeout: 2)
        XCTAssertEqual(tracker.peakActiveCount, maximumConcurrentCount)
        for _ in 0..<workCount {
            release.signal()
        }
        for task in tasks {
            try await task.value
        }

        XCTAssertEqual(executor.maximumConcurrentOperationCount, maximumConcurrentCount)
        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertEqual(tracker.peakActiveCount, maximumConcurrentCount)
    }

    func testNFRSTAB001CancellationWaitsForActiveBlockingWorkToLeaveSafeBoundary() async {
        let executor = BoundedVideoDecodeExecutor(
            label: "org.editorajar.video-frame-cancellation-tests",
            maximumConcurrentOperationCount: 1
        )
        let workStarted = expectation(description: "blocking work started")
        let release = DispatchSemaphore(value: 0)
        let tracker = BlockingWorkTracker(saturationCount: 1)

        let task = Task {
            try await executor.run { cancellation in
                tracker.enter()
                defer { tracker.leave() }
                workStarted.fulfill()
                release.wait()
                try cancellation.checkCancellation()
            }
        }

        await fulfillment(of: [workStarted], timeout: 2)
        task.cancel()
        XCTAssertEqual(tracker.activeCount, 1)
        release.signal()

        switch await task.result {
        case .success:
            XCTFail("Cancelled blocking decode unexpectedly succeeded")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(tracker.activeCount, 0)
    }

    func testNFRSTAB001CancellationSkipsQueuedBlockingWork() async throws {
        let executor = BoundedVideoDecodeExecutor(
            label: "org.editorajar.video-frame-queued-cancellation-tests",
            maximumConcurrentOperationCount: 1
        )
        let firstWorkStarted = expectation(description: "first blocking work started")
        let releaseFirstWork = DispatchSemaphore(value: 0)
        let queuedWorkRan = LockedBoolean()
        let tracker = BlockingWorkTracker(saturationCount: 1)

        let firstTask = Task {
            try await executor.run { _ in
                tracker.enter()
                defer { tracker.leave() }
                firstWorkStarted.fulfill()
                releaseFirstWork.wait()
            }
        }
        await fulfillment(of: [firstWorkStarted], timeout: 2)

        let queuedTask = Task {
            try await executor.run { _ in
                queuedWorkRan.setTrue()
            }
        }
        queuedTask.cancel()
        let queuedCancellationCompleted = expectation(
            description: "queued cancellation completed behind active work"
        )
        let queuedResult = Task {
            let result = await queuedTask.result
            queuedCancellationCompleted.fulfill()
            return result
        }
        await fulfillment(of: [queuedCancellationCompleted], timeout: 2)
        switch await queuedResult.value {
        case .success:
            XCTFail("Cancelled queued decode unexpectedly succeeded")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(tracker.activeCount, 1)
        XCTAssertFalse(queuedWorkRan.value)

        releaseFirstWork.signal()
        try await firstTask.value
        XCTAssertEqual(tracker.activeCount, 0)
    }

    private static func decodeConcurrently(
        count: Int,
        device: MTLDevice,
        sourceURL: URL
    ) async -> [String] {
        await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        let decoder = try VideoFrameDecoder(device: device)
                        _ = try await decoder.decodeFrame(
                            from: sourceURL,
                            at: try RationalTime(value: 0, timescale: 24)
                        )
                        return nil
                    } catch {
                        return String(describing: error)
                    }
                }
            }

            var failures: [String] = []
            for await failure in group {
                if let failure {
                    failures.append(failure)
                }
            }
            return failures
        }
    }

    private func withTimeout<Result: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw VideoFrameDecoderConcurrencyTestError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw VideoFrameDecoderConcurrencyTestError.timeout
            }
            return first
        }
    }

    private func temporaryMovieURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-media-concurrency-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("synthetic.mov")
    }
}

private final class BlockingWorkTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var storedActiveCount = 0
    private var storedPeakActiveCount = 0
    private let saturationCount: Int
    let saturated: XCTestExpectation

    init(saturationCount: Int) {
        self.saturationCount = saturationCount
        saturated = XCTestExpectation(description: "executor reached configured width")
    }

    var activeCount: Int {
        lock.withLock { storedActiveCount }
    }

    var peakActiveCount: Int {
        lock.withLock { storedPeakActiveCount }
    }

    func enter() {
        let reachedSaturation = lock.withLock {
            storedActiveCount += 1
            storedPeakActiveCount = max(storedPeakActiveCount, storedActiveCount)
            return storedActiveCount == saturationCount
        }
        if reachedSaturation {
            saturated.fulfill()
        }
    }

    func leave() {
        lock.withLock {
            storedActiveCount -= 1
        }
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.withLock { storedValue }
    }

    func setTrue() {
        lock.withLock {
            storedValue = true
        }
    }
}

private enum VideoFrameDecoderConcurrencyTestError: Error {
    case timeout
}
