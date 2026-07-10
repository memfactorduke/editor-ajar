// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

final class ExportQueueTests: XCTestCase {
    func testFREXP005QueueDrainsSequentiallyOneJobAtATime() async throws {
        let directory = try makeTempDirectory(prefix: "seq")
        defer { try? FileManager.default.removeItem(at: directory) }

        let tracker = ConcurrentEncodeTracker()
        let queue = ExportQueue { jobID, request, onProgress in
            ExportSession(
                id: jobID,
                request: request,
                frameProvider: ControllableFrameProvider(sleepNanoseconds: 1_000_000),
                writerFactory: { temporaryURL, _ in
                    TrackingLifecycleWriter(outputURL: temporaryURL, tracker: tracker)
                },
                onFrameProgress: onProgress
            )
        }

        for index in 0..<3 {
            let request = try ExportQueueFixtures.makeRequest(
                destinationURL: directory.appendingPathComponent("job-\(index).mp4"),
                frameCount: 3
            )
            _ = await queue.enqueue(request: request, displayName: "job-\(index)")
        }

        let finished = await ExportQueueFixtures.waitUntil(timeout: 5) {
            let snaps = await queue.snapshots()
            return snaps.count == 3 && snaps.allSatisfy { $0.state == .done }
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(tracker.peakConcurrentStarts, 1)
        XCTAssertEqual(tracker.completedCount, 3)
    }

    func testFREXP005CancelMidWriteLeavesNoPartialOutput() async throws {
        let directory = try makeTempDirectory(prefix: "cancel-mid")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionBox = WeakSessionBox()
        let writer = LifecycleWriter(outputURL: directory.appendingPathComponent("out.mp4"))
        writer.onAppendVideo = {
            sessionBox.value?.cancel()
        }
        let request = try ExportQueueFixtures.makeRequest(
            destinationURL: directory.appendingPathComponent("out.mp4"),
            frameCount: 4
        )
        let queue = ExportQueue { jobID, jobRequest, onProgress in
            let session = ExportSession(
                id: jobID,
                request: jobRequest,
                frameProvider: LifecycleFrameProvider(),
                writerFactory: { temporaryURL, _ in
                    writer.outputURL = temporaryURL
                    return writer
                },
                onFrameProgress: onProgress
            )
            sessionBox.value = session
            return session
        }

        let jobID = await queue.enqueue(request: request, displayName: "cancel-me")
        let cancelled = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .cancelled
        }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destinationURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains("ajar-partial") }))
        XCTAssertTrue(writer.didCancel)
    }

    func testFREXP005QueueCancelAPIAbortsTransaction() async throws {
        let directory = try makeTempDirectory(prefix: "api-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Slow frames so cancel is observed between appends (session checks between frames).
        let provider = ControllableFrameProvider(sleepNanoseconds: 40_000_000)
        let writer = LifecycleWriter(outputURL: directory.appendingPathComponent("out.mp4"))
        let request = try ExportQueueFixtures.makeRequest(
            destinationURL: directory.appendingPathComponent("out.mp4"),
            frameCount: 8
        )
        let queue = ExportQueue { jobID, jobRequest, onProgress in
            ExportSession(
                id: jobID,
                request: jobRequest,
                frameProvider: provider,
                writerFactory: { temporaryURL, _ in
                    writer.outputURL = temporaryURL
                    return writer
                },
                onFrameProgress: onProgress
            )
        }

        let jobID = await queue.enqueue(request: request, displayName: "slow")
        let running = await ExportQueueFixtures.waitUntil {
            await queue.state(for: jobID) == .running
        }
        XCTAssertTrue(running)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await queue.cancel(jobID: jobID)

        let cancelled = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .cancelled
        }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destinationURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains("ajar-partial") }))
    }

    func testFREXP005PauseRestartsFromScratchOnResume() async throws {
        let directory = try makeTempDirectory(prefix: "pause")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = ControllableFrameProvider(sleepNanoseconds: 30_000_000)
        let writers = WriterBox()
        let request = try ExportQueueFixtures.makeRequest(
            destinationURL: directory.appendingPathComponent("out.mp4"),
            frameCount: 4
        )
        let queue = ExportQueue { jobID, jobRequest, onProgress in
            ExportSession(
                id: jobID,
                request: jobRequest,
                frameProvider: provider,
                writerFactory: { temporaryURL, _ in
                    let writer = LifecycleWriter(outputURL: temporaryURL)
                    writers.append(writer)
                    return writer
                },
                onFrameProgress: onProgress
            )
        }

        let jobID = await queue.enqueue(request: request, displayName: "pause-me")
        let running = await ExportQueueFixtures.waitUntil {
            await queue.state(for: jobID) == .running
        }
        XCTAssertTrue(running)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await queue.pause(jobID: jobID)

        let paused = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .pausedWillRestart
        }
        XCTAssertTrue(paused)
        let framesBeforeResume = provider.renderedFrameCount
        XCTAssertGreaterThan(framesBeforeResume, 0)
        XCTAssertLessThan(framesBeforeResume, 4)

        try await queue.resume(jobID: jobID)

        let done = await ExportQueueFixtures.waitUntil(timeout: 5) {
            await queue.state(for: jobID) == .done
        }
        XCTAssertTrue(done)
        // Full restart: total rendered frames exceed a single uninterrupted 4-frame pass.
        XCTAssertGreaterThan(provider.renderedFrameCount, 4)
        XCTAssertEqual(writers.count, 2, "resume must start a new session/writer")
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.destinationURL.path))
    }

    func testFREXP005QueueProgressIsMonotonicDuringRun() async throws {
        let directory = try makeTempDirectory(prefix: "prog")
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = try ExportQueueFixtures.makeRequest(
            destinationURL: directory.appendingPathComponent("out.mp4"),
            frameCount: 5
        )
        let queue = ExportQueue { jobID, jobRequest, onProgress in
            ExportSession(
                id: jobID,
                request: jobRequest,
                frameProvider: LifecycleFrameProvider(),
                writerFactory: { temporaryURL, _ in
                    LifecycleWriter(outputURL: temporaryURL)
                },
                onFrameProgress: onProgress
            )
        }

        let fractions = FractionCollector()
        let jobID = await queue.enqueue(request: request, displayName: "prog")
        let stream = await queue.snapshotStream()
        let collector = Task {
            for await snaps in stream {
                if let job = snaps.first(where: { $0.id == jobID }) {
                    fractions.append(job.progress.fractionCompleted)
                    if job.state == .done || job.state == .failed || job.state == .cancelled {
                        break
                    }
                }
            }
        }

        let done = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .done
        }
        XCTAssertTrue(done)
        collector.cancel()

        let values = fractions.values()
        XCTAssertFalse(values.isEmpty)
        for index in 1..<values.count {
            XCTAssertGreaterThanOrEqual(
                values[index],
                values[index - 1],
                "progress must be monotonic within a run"
            )
        }
        XCTAssertEqual(values.last ?? 0, 1.0, accuracy: 0.000_1)
    }

    func testFREXP005PendingCancelBeforeStart() async throws {
        let directory = try makeTempDirectory(prefix: "pending")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = ControllableFrameProvider(holdUntilRelease: true)
        let queue = ExportQueue { jobID, jobRequest, onProgress in
            ExportSession(
                id: jobID,
                request: jobRequest,
                frameProvider: provider,
                writerFactory: { temporaryURL, _ in
                    LifecycleWriter(outputURL: temporaryURL)
                },
                onFrameProgress: onProgress
            )
        }

        let first = try ExportQueueFixtures.makeRequest(
            destinationURL: directory.appendingPathComponent("a.mp4"),
            frameCount: 4
        )
        let second = try ExportQueueFixtures.makeRequest(
            destinationURL: directory.appendingPathComponent("b.mp4"),
            frameCount: 2
        )
        let firstID = await queue.enqueue(request: first, displayName: "a")
        let secondID = await queue.enqueue(request: second, displayName: "b")

        let firstRunning = await ExportQueueFixtures.waitUntil {
            await queue.state(for: firstID) == .running
        }
        XCTAssertTrue(firstRunning)
        let secondWhileFirstRuns = await queue.state(for: secondID)
        XCTAssertEqual(secondWhileFirstRuns, .pending)

        try await queue.cancel(jobID: secondID)
        let secondAfterCancel = await queue.state(for: secondID)
        XCTAssertEqual(secondAfterCancel, .cancelled)

        provider.releaseAll()
        let firstDone = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: firstID) == .done
        }
        XCTAssertTrue(firstDone)
        let secondFinal = await queue.state(for: secondID)
        XCTAssertEqual(secondFinal, .cancelled)
    }
}

// MARK: - Helpers

private func makeTempDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ajar-export-queue-\(prefix)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class ConcurrentEncodeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peakConcurrentStarts = 0
    private(set) var completedCount = 0

    func begin() {
        lock.lock()
        active += 1
        peakConcurrentStarts = max(peakConcurrentStarts, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        if active > 0 {
            active -= 1
        }
        completedCount += 1
        lock.unlock()
    }
}

private final class WriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var writers: [LifecycleWriter] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return writers.count
    }

    func append(_ writer: LifecycleWriter) {
        lock.lock()
        writers.append(writer)
        lock.unlock()
    }
}

private final class FractionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        raw.append(value)
        lock.unlock()
    }

    func values() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}

/// Writer that records concurrent encode peaks around start→finish/cancel.
private final class TrackingLifecycleWriter: ExportWriting {
    private let inner: LifecycleWriter
    private let tracker: ConcurrentEncodeTracker
    private let lock = NSLock()
    private var ended = false

    init(outputURL: URL, tracker: ConcurrentEncodeTracker) {
        inner = LifecycleWriter(outputURL: outputURL)
        self.tracker = tracker
    }

    func start() throws {
        tracker.begin()
        try inner.start()
    }

    func makeVideoPixelBuffer() throws -> CVPixelBuffer {
        try inner.makeVideoPixelBuffer()
    }

    func appendVideoIfReady(
        _ pixelBuffer: CVPixelBuffer,
        at time: CMTime
    ) throws -> Bool {
        try inner.appendVideoIfReady(pixelBuffer, at: time)
    }

    func appendAudioIfReady(
        _ buffer: RenderedAudioBuffer,
        frames: Range<Int>
    ) throws -> Bool {
        try inner.appendAudioIfReady(buffer, frames: frames)
    }

    func checkForFailure() throws {
        try inner.checkForFailure()
    }

    func finish(at endTime: CMTime) async throws {
        defer { markEnded() }
        try await inner.finish(at: endTime)
    }

    func cancel() {
        inner.cancel()
        markEnded()
    }

    private func markEnded() {
        lock.lock()
        let shouldEnd = !ended
        ended = true
        lock.unlock()
        if shouldEnd {
            tracker.end()
        }
    }
}
