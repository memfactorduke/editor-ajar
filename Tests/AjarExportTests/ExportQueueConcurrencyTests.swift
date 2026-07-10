// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarExport

/// Concurrent stress over the queue actor (single-threaded green is not enough).
final class ExportQueueConcurrencyTests: XCTestCase {
    private static let legalRunningFinalStates: Set<ExportJobState> = [
        .cancelled,
        .failed,
        .done,
        .pausedWillRestart
    ]

    func testFREXP005ConcurrentEnqueueCancelAndSnapshotStress() async throws {
        let directory = try makeStressDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let queue = makeStressQueue()
        let jobIDs = try await enqueueStressJobs(on: queue, directory: directory, count: 24)
        XCTAssertEqual(jobIDs.count, 24)

        await stormControls(on: queue, jobIDs: jobIDs)

        let settled = await ExportQueueFixtures.waitUntil(timeout: 8) {
            let snaps = await queue.snapshots()
            return snaps.count == 24
                && snaps.allSatisfy { ExportJobStateMachine.isTerminal($0.state) }
        }
        XCTAssertTrue(settled, "all jobs must reach a terminal state under concurrent control")

        let snaps = await queue.snapshots()
        try assertStressTerminalClean(snaps: snaps, directory: directory)
    }

    /// Racy path: cancel/pause/resume/completion against a *running* session, not only PENDING.
    ///
    /// Holds the active encode open with `ControllableFrameProvider(holdUntilRelease:)`, then storms
    /// controls while the job is RUNNING and eventually releases so completion can race too.
    func testFREXP005RunningJobCancelPauseResumeCompletionInterleaveStress() async throws {
        let directory = try makeStressDirectory(prefix: "running-interleave")
        defer { try? FileManager.default.removeItem(at: directory) }

        for iteration in 0..<50 {
            try await runOneRunningJobInterleaveIteration(
                iteration: iteration,
                directory: directory
            )
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(
            names.contains(where: { $0.contains("ajar-partial") }),
            "no ajar-partial leftovers after running-job interleave stress"
        )
    }

    private func runOneRunningJobInterleaveIteration(
        iteration: Int,
        directory: URL
    ) async throws {
        let destination = directory.appendingPathComponent("iter-\(iteration).mp4")
        let provider = ControllableFrameProvider(holdUntilRelease: true)
        let queue = makeHeldFrameQueue(provider: provider)
        let request = try ExportQueueFixtures.makeRequest(
            destinationURL: destination,
            frameCount: 3
        )
        let jobID = await queue.enqueue(
            request: request,
            displayName: "running-stress-\(iteration)"
        )

        let observedStates = StateObservationBox()
        let observer = await startStateObserver(
            queue: queue,
            jobID: jobID,
            observedStates: observedStates
        )
        defer { observer.cancel() }

        let running = await ExportQueueFixtures.waitUntil(timeout: 3) {
            await queue.state(for: jobID) == .running
        }
        XCTAssertTrue(running, "iteration \(iteration): job must enter running under hold")

        await stormRunningJobControls(on: queue, jobID: jobID, provider: provider)

        // A late resume after pause can re-enter pending/running; release again and settle.
        provider.releaseAll()
        try await assertSettledLegalFinal(
            queue: queue,
            jobID: jobID,
            destination: destination,
            observedStates: observedStates,
            iteration: iteration
        )
    }

    private func makeHeldFrameQueue(provider: ControllableFrameProvider) -> ExportQueue {
        ExportQueue { jobID, request, onProgress in
            ExportSession(
                id: jobID,
                request: request,
                frameProvider: provider,
                writerFactory: { temporaryURL, _ in
                    LifecycleWriter(outputURL: temporaryURL)
                },
                onFrameProgress: onProgress
            )
        }
    }

    private func startStateObserver(
        queue: ExportQueue,
        jobID: UUID,
        observedStates: StateObservationBox
    ) async -> Task<Void, Never> {
        let legalFinals = Self.legalRunningFinalStates
        let stream = await queue.snapshotStream()
        return Task {
            for await snaps in stream {
                if let state = snaps.first(where: { $0.id == jobID })?.state {
                    observedStates.append(state)
                    if legalFinals.contains(state) {
                        // Keep reading briefly so a late illegal hop is still visible.
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
            }
        }
    }

    private func stormRunningJobControls(
        on queue: ExportQueue,
        jobID: UUID,
        provider: ControllableFrameProvider
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await queue.cancel(jobID: jobID) }
            group.addTask { try? await queue.pause(jobID: jobID) }
            group.addTask { try? await queue.resume(jobID: jobID) }
            group.addTask { try? await queue.cancel(jobID: jobID) }
            group.addTask { try? await queue.pause(jobID: jobID) }
            group.addTask { try? await queue.resume(jobID: jobID) }
            group.addTask {
                // Completion path: release held frames so the active session can finish
                // if cancel/pause did not already abort it.
                try? await Task.sleep(nanoseconds: 5_000_000)
                provider.releaseAll()
            }
            group.addTask {
                _ = await queue.snapshots()
                _ = await queue.state(for: jobID)
            }
        }
    }

    private func assertSettledLegalFinal(
        queue: ExportQueue,
        jobID: UUID,
        destination: URL,
        observedStates: StateObservationBox,
        iteration: Int
    ) async throws {
        let legalFinals = Self.legalRunningFinalStates
        let settled = await ExportQueueFixtures.waitUntil(timeout: 4) {
            guard let state = await queue.state(for: jobID) else {
                return false
            }
            return legalFinals.contains(state)
        }
        let lastObserved = await queue.state(for: jobID)
        let lastDescription = String(describing: lastObserved)
        XCTAssertTrue(
            settled,
            "iteration \(iteration): expected legal final/paused state, last=\(lastDescription)"
        )

        guard let finalState = lastObserved else {
            XCTFail("iteration \(iteration): missing final state")
            return
        }
        XCTAssertTrue(
            legalFinals.contains(finalState),
            "iteration \(iteration): illegal final state \(finalState)"
        )

        let isNonSuccess = finalState == .cancelled
            || finalState == .failed
            || finalState == .pausedWillRestart
        if isNonSuccess {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path),
                "iteration \(iteration): non-success must not leave destination partial"
            )
        }

        let history = observedStates.values()
        XCTAssertFalse(history.isEmpty, "iteration \(iteration): must observe state history")
        assertLegalStateHistory(history, iteration: iteration)
    }

    private func makeStressDirectory(prefix: String = "stress") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-export-queue-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStressQueue() -> ExportQueue {
        ExportQueue { jobID, request, onProgress in
            ExportSession(
                id: jobID,
                request: request,
                frameProvider: ControllableFrameProvider(sleepNanoseconds: 500_000),
                writerFactory: { temporaryURL, _ in
                    LifecycleWriter(outputURL: temporaryURL)
                },
                onFrameProgress: onProgress
            )
        }
    }

    private func enqueueStressJobs(
        on queue: ExportQueue,
        directory: URL,
        count: Int
    ) async throws -> [UUID] {
        let tasks = (0..<count).map { index in
            Task {
                let request = try ExportQueueFixtures.makeRequest(
                    destinationURL: directory.appendingPathComponent("s-\(index).mp4"),
                    frameCount: 2
                )
                return await queue.enqueue(request: request, displayName: "s-\(index)")
            }
        }
        var jobIDs: [UUID] = []
        for task in tasks {
            jobIDs.append(try await task.value)
        }
        return jobIDs
    }

    private func stormControls(on queue: ExportQueue, jobIDs: [UUID]) async {
        await withTaskGroup(of: Void.self) { group in
            for jobID in jobIDs {
                group.addTask {
                    if jobID.uuidString.hashValue % 2 == 0 {
                        try? await queue.cancel(jobID: jobID)
                    }
                    _ = await queue.snapshots()
                    _ = await queue.state(for: jobID)
                }
            }
            for _ in 0..<32 {
                group.addTask {
                    _ = await queue.snapshots()
                }
            }
        }
    }

    private func assertStressTerminalClean(
        snaps: [ExportJobSnapshot],
        directory: URL
    ) throws {
        for snap in snaps {
            XCTAssertTrue(ExportJobStateMachine.isTerminal(snap.state))
            if snap.state == .cancelled || snap.state == .failed {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: snap.destinationURL.path),
                    "terminal non-success must not leave partial output"
                )
            }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains("ajar-partial") }))
    }

    /// Every adjacent state hop must be explained by some legal event in `ExportJobStateMachine`.
    private func assertLegalStateHistory(_ history: [ExportJobState], iteration: Int) {
        guard history.count >= 2 else {
            return
        }
        for index in 1..<history.count {
            let from = history[index - 1]
            let to = history[index]
            if from == to {
                continue
            }
            let nextValues =
                ExportJobStateMachine.legalTransitions[from]?.values.map { $0 }
                ?? [ExportJobState]()
            let legalNext = Set(nextValues)
            let message =
                "iteration \(iteration): impossible transition "
                + "\(from.rawValue) → \(to.rawValue)"
            XCTAssertTrue(legalNext.contains(to), message)
        }
    }
}

/// Thread-safe state history for concurrent stress observers.
private final class StateObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [ExportJobState] = []

    func append(_ state: ExportJobState) {
        lock.lock()
        if raw.last != state {
            raw.append(state)
        }
        lock.unlock()
    }

    func values() -> [ExportJobState] {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}
