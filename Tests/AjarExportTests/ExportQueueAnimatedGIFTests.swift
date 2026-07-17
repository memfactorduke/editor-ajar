// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

final class ExportQueueAnimatedGIFTests: XCTestCase {
    func testFREXP005And006MixedMovieGIFMovieQueueIsStrictlySerial() async throws {
        let directory = try makeGIFQueueDirectory(prefix: "mixed")
        defer { try? FileManager.default.removeItem(at: directory) }

        let tracker = MixedSessionTracker()
        let queue = makeMixedQueue(tracker: tracker, frameDelayNanoseconds: 2_000_000)
        let movieA = try ExportQueueFixtures.makeRequest(
            destinationURL: directory.appendingPathComponent("a.mp4"),
            frameCount: 3
        )
        let gif = try makeGIFQueueRequest(
            destinationURL: directory.appendingPathComponent("b.gif"),
            frameCount: 3
        )
        let movieC = try ExportQueueFixtures.makeRequest(
            destinationURL: directory.appendingPathComponent("c.mp4"),
            frameCount: 3
        )
        let ids = [UUID(), UUID(), UUID()]

        let stream = await queue.snapshotStream()
        let progress = MixedProgressSamples()
        let collector = Task {
            for await snapshots in stream {
                progress.record(snapshots)
                if snapshots.count == 3, snapshots.allSatisfy({ $0.state == .done }) {
                    break
                }
            }
        }

        try await queue.enqueue(request: movieA, displayName: "movie-a", id: ids[0])
        try await queue.enqueue(animatedGIFRequest: gif, displayName: "gif-b", id: ids[1])
        try await queue.enqueue(request: movieC, displayName: "movie-c", id: ids[2])

        let finished = await ExportQueueFixtures.waitUntil(timeout: 5) {
            let snapshots = await queue.snapshots()
            return snapshots.count == 3 && snapshots.allSatisfy { $0.state == .done }
        }
        XCTAssertTrue(finished)
        await collector.value

        XCTAssertEqual(tracker.startedJobIDs, ids)
        XCTAssertEqual(tracker.peakConcurrentSessions, 1)
        XCTAssertEqual(tracker.completedJobIDs, ids)

        let snapshots = await queue.snapshots()
        XCTAssertEqual(snapshots.map(\.id), ids)
        XCTAssertEqual(snapshots.map(\.kind), [.movie, .animatedGIF, .movie])
        XCTAssertTrue(snapshots.allSatisfy { $0.progress.fractionCompleted == 1 })
        let gifProgress = progress.values(for: ids[1])
        XCTAssertTrue(gifProgress.contains { $0 > 0 && $0 < 1 })
        XCTAssertFalse(
            zip(gifProgress, gifProgress.dropFirst()).contains { $1 < $0 },
            "GIF queue progress must never move backward"
        )

        let movieRequestA = await queue.request(for: ids[0])
        let gifRequestA = await queue.animatedGIFRequest(for: ids[0])
        let movieRequestB = await queue.request(for: ids[1])
        let gifRequestB = await queue.animatedGIFRequest(for: ids[1])
        let movieRequestC = await queue.request(for: ids[2])
        XCTAssertNotNil(movieRequestA)
        XCTAssertNil(gifRequestA)
        XCTAssertNil(movieRequestB)
        XCTAssertEqual(gifRequestB?.destinationURL, gif.destinationURL)
        XCTAssertNotNil(movieRequestC)
    }

    func testFREXP005QueueReservesNonterminalDestinationAcrossOutputKinds() async throws {
        let directory = try makeGIFQueueDirectory(prefix: "destination-reservation")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = ControllableFrameProvider(sleepNanoseconds: 30_000_000)
        let queue = makeGIFControlQueue(provider: provider, writerCount: LockedCounter())
        let destination = directory.appendingPathComponent("shared-output.gif")
        let movie = try ExportQueueFixtures.makeRequest(
            destinationURL: destination,
            frameCount: 8
        )
        let gif = try makeGIFQueueRequest(
            destinationURL: destination,
            frameCount: 2
        )

        let movieID = try await queue.enqueue(request: movie, displayName: "reserved-movie")
        let running = await ExportQueueFixtures.waitUntil {
            await queue.state(for: movieID) == .running
        }
        XCTAssertTrue(running)

        do {
            _ = try await queue.enqueue(
                animatedGIFRequest: gif,
                displayName: "colliding-gif"
            )
            XCTFail("a nonterminal job must retain exclusive ownership of its destination")
        } catch let error as ExportQueueError {
            XCTAssertEqual(error, .destinationAlreadyQueued(destination))
        }
        let snapshotsAfterRefusal = await queue.snapshots()
        XCTAssertEqual(snapshotsAfterRefusal.count, 1)

        try await queue.pause(jobID: movieID)
        let paused = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: movieID) == .pausedWillRestart
        }
        XCTAssertTrue(paused)

        do {
            _ = try await queue.enqueue(
                animatedGIFRequest: gif,
                displayName: "colliding-with-paused-movie"
            )
            XCTFail("a paused job must retain exclusive ownership of its destination")
        } catch let error as ExportQueueError {
            XCTAssertEqual(error, .destinationAlreadyQueued(destination))
        }

        try await queue.cancel(jobID: movieID)
        let cancelled = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: movieID) == .cancelled
        }
        XCTAssertTrue(cancelled)

        let gifID = try await queue.enqueue(
            animatedGIFRequest: gif,
            displayName: "released-gif"
        )
        let completed = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: gifID) == .done
        }
        XCTAssertTrue(completed)
    }

    func testFREXP005And006GIFPauseResumesFromFrameZero() async throws {
        let directory = try makeGIFQueueDirectory(prefix: "pause")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = ControllableFrameProvider(sleepNanoseconds: 30_000_000)
        let writerCount = LockedCounter()
        let queue = makeGIFControlQueue(provider: provider, writerCount: writerCount)
        let request = try makeGIFQueueRequest(
            destinationURL: directory.appendingPathComponent("paused.gif"),
            frameCount: 4
        )
        let existingDestination = Data("existing-pause-destination".utf8)
        try existingDestination.write(to: request.destinationURL)

        let jobID = try await queue.enqueue(
            animatedGIFRequest: request,
            displayName: "pause-gif"
        )
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
        XCTAssertEqual(try Data(contentsOf: request.destinationURL), existingDestination)

        try await queue.resume(jobID: jobID)
        let completed = await ExportQueueFixtures.waitUntil(timeout: 5) {
            await queue.state(for: jobID) == .done
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(writerCount.value, 2)
        XCTAssertGreaterThan(provider.renderedFrameCount, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.destinationURL.path))
        let snapshotKind = await queue.snapshots().first?.kind
        XCTAssertEqual(snapshotKind, .animatedGIF)
    }

    func testFREXP005And006GIFCancelRemovesPartialOutput() async throws {
        let directory = try makeGIFQueueDirectory(prefix: "cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = ControllableFrameProvider(sleepNanoseconds: 30_000_000)
        let queue = makeGIFControlQueue(provider: provider, writerCount: LockedCounter())
        let request = try makeGIFQueueRequest(
            destinationURL: directory.appendingPathComponent("cancelled.gif"),
            frameCount: 8
        )
        let existingDestination = Data("existing-cancel-destination".utf8)
        try existingDestination.write(to: request.destinationURL)

        let jobID = try await queue.enqueue(
            animatedGIFRequest: request,
            displayName: "cancel-gif"
        )
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
        XCTAssertEqual(try Data(contentsOf: request.destinationURL), existingDestination)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.contains("ajar-partial") })
    }

    private func makeMixedQueue(
        tracker: MixedSessionTracker,
        frameDelayNanoseconds: UInt64
    ) -> ExportQueue {
        ExportQueue(
            sessionFactory: { jobID, request, onProgress in
                ExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: ControllableFrameProvider(
                        sleepNanoseconds: frameDelayNanoseconds
                    ),
                    writerFactory: { temporaryURL, _ in
                        TrackingMovieQueueWriter(
                            outputURL: temporaryURL,
                            jobID: jobID,
                            tracker: tracker
                        )
                    },
                    onFrameProgress: onProgress
                )
            },
            animatedGIFSessionFactory: { jobID, request, onProgress in
                AnimatedGIFExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: ControllableFrameProvider(
                        sleepNanoseconds: frameDelayNanoseconds
                    ),
                    writerFactory: { temporaryURL, _, _ in
                        try TrackingGIFQueueWriter(
                            outputURL: temporaryURL,
                            jobID: jobID,
                            tracker: tracker
                        )
                    },
                    onFrameProgress: onProgress
                )
            }
        )
    }

    private func makeGIFControlQueue(
        provider: ControllableFrameProvider,
        writerCount: LockedCounter
    ) -> ExportQueue {
        ExportQueue(
            sessionFactory: { jobID, request, onProgress in
                ExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: provider,
                    writerFactory: { temporaryURL, _ in
                        LifecycleWriter(outputURL: temporaryURL)
                    },
                    onFrameProgress: onProgress
                )
            },
            animatedGIFSessionFactory: { jobID, request, onProgress in
                AnimatedGIFExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: provider,
                    writerFactory: { temporaryURL, _, _ in
                        writerCount.increment()
                        return try SuccessfulQueueGIFWriter(outputURL: temporaryURL)
                    },
                    onFrameProgress: onProgress
                )
            }
        )
    }
}

private func makeGIFQueueDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ajar-export-queue-gif-\(prefix)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeGIFQueueRequest(
    destinationURL: URL,
    frameCount: Int64
) throws -> AnimatedGIFExportRequest {
    let template = try ExportQueueFixtures.makeRequest(
        destinationURL: destinationURL.deletingPathExtension().appendingPathExtension("mp4"),
        frameCount: frameCount
    )
    return try AnimatedGIFExportRequest(
        project: template.project,
        sequenceID: template.sequenceID,
        range: template.range,
        destinationURL: destinationURL,
        settings: AnimatedGIFExportSettings(
            resolution: PixelDimensions(width: 9, height: 7),
            frameRate: template.sequence.timebase
        )
    )
}

private final class MixedSessionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var started: [UUID] = []
    private var completed: [UUID] = []

    var peakConcurrentSessions: Int {
        lock.withLock { peak }
    }

    var startedJobIDs: [UUID] {
        lock.withLock { started }
    }

    var completedJobIDs: [UUID] {
        lock.withLock { completed }
    }

    func begin(_ jobID: UUID) {
        lock.withLock {
            active += 1
            peak = max(peak, active)
            started.append(jobID)
        }
    }

    func end(_ jobID: UUID) {
        lock.withLock {
            active -= 1
            completed.append(jobID)
        }
    }
}

private final class TrackingMovieQueueWriter: ExportWriting {
    private let inner: LifecycleWriter
    private let jobID: UUID
    private let tracker: MixedSessionTracker
    private let lock = NSLock()
    private var ended = false

    init(outputURL: URL, jobID: UUID, tracker: MixedSessionTracker) {
        inner = LifecycleWriter(outputURL: outputURL)
        self.jobID = jobID
        self.tracker = tracker
    }

    func start() throws {
        tracker.begin(jobID)
        try inner.start()
    }

    func makeVideoPixelBuffer() throws -> CVPixelBuffer {
        try inner.makeVideoPixelBuffer()
    }

    func appendVideoIfReady(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws -> Bool {
        try inner.appendVideoIfReady(pixelBuffer, at: time)
    }

    func appendAudioIfReady(
        _ buffer: RenderedAudioBuffer,
        frames: Range<Int>,
        presentationFrameOffset: Int
    ) throws -> Bool {
        try inner.appendAudioIfReady(
            buffer,
            frames: frames,
            presentationFrameOffset: presentationFrameOffset
        )
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
        let shouldEnd = lock.withLock {
            let shouldEnd = !ended
            ended = true
            return shouldEnd
        }
        if shouldEnd {
            tracker.end(jobID)
        }
    }
}

private final class TrackingGIFQueueWriter: AnimatedGIFWriting {
    private let jobID: UUID
    private let tracker: MixedSessionTracker

    init(outputURL: URL, jobID: UUID, tracker: MixedSessionTracker) throws {
        self.jobID = jobID
        self.tracker = tracker
        try Data("gif".utf8).write(to: outputURL)
        tracker.begin(jobID)
    }

    func append(
        pixelBuffer _: CVPixelBuffer,
        sourceColorSpace _: ExportColorSpace,
        colorConversionPolicy _: AnimatedGIFColorConversionPolicy,
        delayCentiseconds _: Int
    ) throws {}

    func finalize() throws {
        tracker.end(jobID)
    }
}

private final class SuccessfulQueueGIFWriter: AnimatedGIFWriting {
    init(outputURL: URL) throws {
        try Data("gif".utf8).write(to: outputURL)
    }

    func append(
        pixelBuffer _: CVPixelBuffer,
        sourceColorSpace _: ExportColorSpace,
        colorConversionPolicy _: AnimatedGIFColorConversionPolicy,
        delayCentiseconds _: Int
    ) throws {}

    func finalize() throws {}
}

private final class MixedProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [UUID: [Double]] = [:]

    func record(_ snapshots: [ExportJobSnapshot]) {
        lock.withLock {
            for snapshot in snapshots {
                samples[snapshot.id, default: []].append(snapshot.progress.fractionCompleted)
            }
        }
    }

    func values(for jobID: UUID) -> [Double] {
        lock.withLock { samples[jobID] ?? [] }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var rawValue = 0

    var value: Int {
        lock.withLock { rawValue }
    }

    func increment() {
        lock.withLock {
            rawValue += 1
        }
    }
}
