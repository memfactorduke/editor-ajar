// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Background queue for proxy / optimized-media generation (FR-MED-004).
///
/// ## Why a second queue (not ExportQueue)
/// `ExportQueue` drains one hardware-encode job at a time for user exports. Proxy jobs are
/// ProRes offline transcodes of original media. Running them on the same drain would either
/// block user exports behind long proxy batches or force awkward priority preemption. A
/// dedicated actor reuses ``ExportJobStateMachine`` / progress estimators while keeping
/// export and proxy work independent (ADR-0012 background class).
///
/// Jobs and generation **progress** are in-memory only (not restored after relaunch). Durable
/// per-media state lives on `MediaRef.proxyState`.
public actor ProxyGenerationQueue {
    private struct JobRecord: Sendable {
        var job: ProxyGenerationJob
        var state: ExportJobState
        var progress: ExportProgressEstimate
        var estimator: ExportProgressEstimator
        var failure: ExportError?
        var result: ProxyGenerationResult?
    }

    private let sessionFactory: ProxySessionFactory
    private var records: [UUID: JobRecord] = [:]
    private var order: [UUID] = []
    private var activeJobID: UUID?
    private var activeSession: ProxyGenerationSession?
    private var cancelActive = false
    private var drainTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<[ProxyJobSnapshot]>.Continuation] = [:]

    /// Creates a queue that builds sessions through `sessionFactory`.
    public init(sessionFactory: @escaping ProxySessionFactory) {
        self.sessionFactory = sessionFactory
    }

    /// Ordered job snapshots for UI and tests.
    public func snapshots() -> [ProxyJobSnapshot] {
        order.compactMap { id in
            records[id].map(Self.makeSnapshot)
        }
    }

    /// Stream of full ordered snapshots after every state/progress change.
    public func snapshotStream() -> AsyncStream<[ProxyJobSnapshot]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(snapshots())
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeObserver(id) }
            }
        }
    }

    /// Enqueues a proxy generation job.
    @discardableResult
    public func enqueue(_ job: ProxyGenerationJob) -> UUID {
        // Deduplicate: if the same media already has a pending/running job, keep that one.
        if let existing = order.first(where: { id in
            guard let record = records[id] else {
                return false
            }
            return record.job.mediaID == job.mediaID
                && (record.state == .pending || record.state == .running)
        }) {
            return existing
        }

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

    /// Cancels a pending or running proxy job.
    public func cancel(jobID: UUID) throws {
        guard var record = records[jobID] else {
            throw ExportQueueError.jobNotFound(jobID)
        }
        switch record.state {
        case .pending:
            record.state = try apply(record.state, .cancel)
            records[jobID] = record
            publish()
        case .running:
            guard activeJobID == jobID else {
                throw ExportQueueError.concurrentEncodeInvariantViolated
            }
            cancelActive = true
            activeSession?.cancel()
        case .pausedWillRestart, .cancelled, .failed, .done:
            throw ExportQueueError.illegalJobTransition(
                .illegalTransition(from: record.state, event: .cancel)
            )
        }
    }

    /// Job state for tests and polling.
    public func state(for jobID: UUID) -> ExportJobState? {
        records[jobID]?.state
    }

    /// Result for a completed job.
    public func result(for jobID: UUID) -> ProxyGenerationResult? {
        records[jobID]?.result
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
        cancelActive = false
        publish()

        let session = sessionFactory(jobID, record.job.request) { [weak self] progress in
            Task { [weak self] in await self?.handleProgress(jobID: jobID, progress: progress) }
        }
        activeSession = session

        do {
            let result = try await session.run()
            finishSuccess(jobID: jobID, result: result)
        } catch let error as ExportError {
            finishError(jobID: jobID, error: error)
        } catch {
            finishError(
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

    private func finishSuccess(jobID: UUID, result: ProxyGenerationResult) {
        cancelActive = false
        guard var record = records[jobID] else {
            clearActive()
            return
        }
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

    private func finishError(jobID: UUID, error: ExportError) {
        let wasCancel = cancelActive || error == .cancelled
        cancelActive = false
        guard var record = records[jobID] else {
            clearActive()
            return
        }
        if record.state == .running {
            if wasCancel {
                if let next = try? apply(record.state, .cancel) {
                    record.state = next
                }
            } else if let next = try? apply(record.state, .fail) {
                record.state = next
                record.failure = error
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

    private static func makeSnapshot(_ record: JobRecord) -> ProxyJobSnapshot {
        ProxyJobSnapshot(
            id: record.job.id,
            mediaID: record.job.mediaID,
            displayName: record.job.displayName,
            state: record.state,
            progress: record.progress,
            failure: record.failure,
            result: record.result,
            enqueuedAt: record.job.enqueuedAt
        )
    }
}
