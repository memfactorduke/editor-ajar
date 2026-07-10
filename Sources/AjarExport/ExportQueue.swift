// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Sequential background export queue (FR-EXP-005).
///
/// ## Execution model
/// Drains **one hardware-encode job at a time**. VideoToolbox / AVAssetWriter sessions contend
/// for the hardware encoder; parallel encodes are rejected by design for v1. Work runs off the
/// main actor inside this `actor` (session `run()` is async). The pure job state machine is
/// `ExportJobStateMachine`; this type owns scheduling, progress aggregation, and session cancel.
///
/// ## Pause
/// Pause cooperatively cancels the active session (`pausedWillRestart`). Resume requeues the job
/// as `pending` and restarts encode from frame zero — not a true mid-GOP pause.
///
/// ## Persistence
/// Jobs are in-memory only; they are **not** restored after app relaunch.
public actor ExportQueue {
    private enum StopIntent: Equatable, Sendable {
        case none
        case cancel
        case pause
    }

    private struct JobRecord: Sendable {
        var job: ExportJob
        var state: ExportJobState
        var progress: ExportProgressEstimate
        var estimator: ExportProgressEstimator
        var failure: ExportError?
        var result: ExportResult?
    }

    private let sessionFactory: ExportSessionFactory
    private var records: [UUID: JobRecord] = [:]
    private var order: [UUID] = []
    private var activeJobID: UUID?
    private var activeSession: ExportSession?
    private var stopIntent: StopIntent = .none
    private var drainTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<[ExportJobSnapshot]>.Continuation] = [:]

    /// Creates a queue that builds sessions through `sessionFactory`.
    public init(sessionFactory: @escaping ExportSessionFactory) {
        self.sessionFactory = sessionFactory
    }

    /// Ordered job snapshots for UI and tests.
    public func snapshots() -> [ExportJobSnapshot] {
        order.compactMap { id in
            records[id].map(Self.makeSnapshot)
        }
    }

    /// Stream of full ordered snapshots after every state/progress change.
    public func snapshotStream() -> AsyncStream<[ExportJobSnapshot]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(snapshots())
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeObserver(id) }
            }
        }
    }

    /// Enqueues an export. `request.project` must already be the immutable snapshot to encode.
    @discardableResult
    public func enqueue(_ job: ExportJob) -> UUID {
        let record = JobRecord(
            job: job,
            state: .pending,
            progress: .zero,
            estimator: ExportProgressEstimator(),
            failure: nil,
            result: nil
        )
        records[job.id] = record
        order.append(job.id)
        publish()
        ensureDrain()
        return job.id
    }

    /// Convenience: builds a job id and enqueues.
    @discardableResult
    public func enqueue(
        request: ExportRequest,
        displayName: String,
        id: UUID = UUID(),
        enqueuedAt: Date = Date()
    ) -> UUID {
        enqueue(
            ExportJob(
                id: id,
                displayName: displayName,
                request: request,
                enqueuedAt: enqueuedAt
            )
        )
    }

    /// Cancels a pending, running, or paused job. Mid-write cancel aborts the output transaction.
    public func cancel(jobID: UUID) throws {
        guard var record = records[jobID] else {
            throw ExportQueueError.jobNotFound(jobID)
        }
        switch record.state {
        case .pending, .pausedWillRestart:
            record.state = try apply(record.state, .cancel)
            records[jobID] = record
            publish()
        case .running:
            guard activeJobID == jobID else {
                throw ExportQueueError.concurrentEncodeInvariantViolated
            }
            stopIntent = .cancel
            activeSession?.cancel()
        case .cancelled, .failed, .done:
            throw ExportQueueError.illegalJobTransition(
                .illegalTransition(from: record.state, event: .cancel)
            )
        }
    }

    /// Pauses the running job (graceful stop; resume restarts from scratch).
    public func pause(jobID: UUID) throws {
        guard let record = records[jobID] else {
            throw ExportQueueError.jobNotFound(jobID)
        }
        guard record.state == .running else {
            throw ExportQueueError.illegalJobTransition(
                .illegalTransition(from: record.state, event: .pause)
            )
        }
        guard activeJobID == jobID else {
            throw ExportQueueError.concurrentEncodeInvariantViolated
        }
        stopIntent = .pause
        activeSession?.cancel()
    }

    /// Resumes a paused job by requeueing it as `pending` for a full restart.
    public func resume(jobID: UUID) throws {
        guard var record = records[jobID] else {
            throw ExportQueueError.jobNotFound(jobID)
        }
        record.state = try apply(record.state, .resume)
        record.progress = .zero
        record.estimator.reset()
        record.failure = nil
        record.result = nil
        records[jobID] = record
        publish()
        ensureDrain()
    }

    /// Captured request for snapshot-isolation tests (returns nil if unknown).
    public func request(for jobID: UUID) -> ExportRequest? {
        records[jobID]?.job.request
    }

    /// Job state for tests and polling adapters.
    public func state(for jobID: UUID) -> ExportJobState? {
        records[jobID]?.state
    }

    // MARK: - Drain

    private func ensureDrain() {
        guard drainTask == nil else {
            return
        }
        drainTask = Task { await self.drainLoop() }
    }

    private func drainLoop() async {
        while let jobID = nextPendingJobID() {
            await runJob(jobID)
        }
        drainTask = nil
        // A resume/enqueue may have raced the clear; restart if work remains.
        if nextPendingJobID() != nil {
            ensureDrain()
        }
    }

    private func nextPendingJobID() -> UUID? {
        order.first { id in
            records[id]?.state == .pending
        }
    }

    private func runJob(_ jobID: UUID) async {
        guard var record = records[jobID], record.state == .pending else {
            return
        }
        if activeJobID != nil {
            // Invariant: only one hardware encode. Leave job pending for a later drain pass.
            return
        }

        do {
            record.state = try apply(record.state, .start)
        } catch {
            return
        }
        record.progress = .zero
        record.estimator.reset()
        records[jobID] = record
        activeJobID = jobID
        stopIntent = .none
        publish()

        let session = sessionFactory(jobID, record.job.request) { [weak self] progress in
            Task { [weak self] in await self?.handleProgress(jobID: jobID, progress: progress) }
        }
        activeSession = session

        do {
            let result = try await session.run()
            finishSuccess(jobID: jobID, result: result)
        } catch let error as ExportError {
            finishExportError(jobID: jobID, error: error)
        } catch {
            finishExportError(
                jobID: jobID,
                error: ExportError.writerFailed(String(describing: error))
            )
        }
    }

    private func handleProgress(jobID: UUID, progress: ExportProgress) {
        guard var record = records[jobID], record.state == .running else {
            return
        }
        record.progress = record.estimator.update(progress: progress)
        records[jobID] = record
        publish()
    }

    private func finishSuccess(jobID: UUID, result: ExportResult) {
        // Match finishExportError: clear stop intent so a later job never inherits it.
        stopIntent = .none
        guard var record = records[jobID] else {
            clearActive()
            return
        }
        // Pause/cancel may have already flipped the state while run() was unwinding.
        if record.state == .running {
            if let next = try? apply(record.state, .complete) {
                record.state = next
                record.result = result
                record.progress = record.estimator.update(
                    progress: ExportProgress(
                        framesWritten: result.videoFrameCount,
                        totalFrames: result.videoFrameCount
                    )
                )
                records[jobID] = record
            }
        }
        clearActive()
        publish()
    }

    private func finishExportError(jobID: UUID, error: ExportError) {
        guard var record = records[jobID] else {
            clearActive()
            return
        }
        let intent = stopIntent
        stopIntent = .none

        if record.state == .running {
            switch (error, intent) {
            case (.cancelled, .pause):
                if let next = try? apply(record.state, .pause) {
                    record.state = next
                    record.progress = .zero
                    record.estimator.reset()
                }
            case (.cancelled, _), (_, .cancel):
                if let next = try? apply(record.state, .cancel) {
                    record.state = next
                }
            default:
                if let next = try? apply(record.state, .fail) {
                    record.state = next
                    record.failure = error
                }
            }
            records[jobID] = record
        }
        clearActive()
        publish()
    }

    private func clearActive() {
        activeSession = nil
        activeJobID = nil
    }

    private func apply(
        _ state: ExportJobState,
        _ event: ExportJobEvent
    ) throws -> ExportJobState {
        switch ExportJobStateMachine.apply(state: state, event: event) {
        case .success(let next):
            next
        case .failure(let error):
            throw ExportQueueError.illegalJobTransition(error)
        }
    }

    private func publish() {
        let snapshot = snapshots()
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private static func makeSnapshot(_ record: JobRecord) -> ExportJobSnapshot {
        ExportJobSnapshot(
            id: record.job.id,
            displayName: record.job.displayName,
            destinationURL: record.job.request.destinationURL,
            state: record.state,
            progress: record.progress,
            failure: record.failure,
            result: record.result,
            enqueuedAt: record.job.enqueuedAt,
            snapshotSequenceID: record.job.request.sequenceID
        )
    }
}
