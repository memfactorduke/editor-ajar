// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Exactly-once continuation and ownership state for one queued blocking audio decode.
final class AudioDecodeJob<Output>: @unchecked Sendable {
    typealias Work = () throws -> Output

    private enum Phase: Equatable {
        case initial
        case queued
        case running
        case finished
    }

    private let lock = NSLock()
    private let cancellation: AudioPCMDecodeCancellation
    private var phase = Phase.initial
    private var cancellationRequested = false
    private var continuation: CheckedContinuation<Output, Error>?
    private var operation: BlockOperation?
    private var work: Work?

    init(cancellation: AudioPCMDecodeCancellation, work: @escaping Work) {
        self.cancellation = cancellation
        self.work = work
    }

    func submit(
        on queue: OperationQueue,
        continuation: CheckedContinuation<Output, Error>
    ) {
        var operationToSubmit: BlockOperation?
        var continuationToCancel: CheckedContinuation<Output, Error>?

        lock.withLock {
            guard phase == .initial, !cancellationRequested else {
                phase = .finished
                work = nil
                continuationToCancel = continuation
                return
            }

            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self] in
                self?.execute()
            }
            self.continuation = continuation
            self.operation = operation
            phase = .queued
            operationToSubmit = operation
        }

        if let continuationToCancel {
            continuationToCancel.resume(throwing: CancellationError())
        } else if let operationToSubmit {
            queue.addOperation(operationToSubmit)
        }
    }

    /// Queued jobs release their captured asset and resume immediately. Running jobs only set the
    /// cooperative flag; their worker remains the sole owner of AVAssetReader through teardown.
    func cancel() {
        cancellation.cancel()
        var operationToCancel: BlockOperation?
        var continuationToCancel: CheckedContinuation<Output, Error>?

        lock.withLock {
            guard phase != .finished else {
                return
            }
            cancellationRequested = true
            switch phase {
            case .initial:
                work = nil
            case .queued:
                phase = .finished
                work = nil
                operationToCancel = operation
                operation = nil
                continuationToCancel = continuation
                continuation = nil
            case .running, .finished:
                break
            }
        }

        operationToCancel?.cancel()
        continuationToCancel?.resume(throwing: CancellationError())
    }

    private func execute() {
        let workToRun: Work? = lock.withLock {
            guard phase == .queued, !cancellationRequested else {
                return nil
            }
            phase = .running
            operation = nil
            defer { work = nil }
            return work
        }
        guard let workToRun else {
            return
        }

        let result: Result<Output, Error>
        do {
            try cancellation.check()
            result = .success(try workToRun())
        } catch {
            result = .failure(error)
        }
        finish(result)
    }

    private func finish(_ result: Result<Output, Error>) {
        var continuationToResume: CheckedContinuation<Output, Error>?
        var resolvedResult = result

        lock.withLock {
            guard phase == .running else {
                return
            }
            phase = .finished
            if cancellationRequested {
                resolvedResult = .failure(CancellationError())
            }
            continuationToResume = continuation
            continuation = nil
            operation = nil
            work = nil
        }
        continuationToResume?.resume(with: resolvedResult)
    }
}

/// Fixed-width executor for AVAssetReader audio work that blocks its owning thread.
final class BoundedAudioDecodeExecutor: @unchecked Sendable {
    let maximumConcurrentOperationCount: Int
    private let queue: OperationQueue

    init(label: String, maximumConcurrentOperationCount: Int) {
        let boundedCount = max(1, maximumConcurrentOperationCount)
        self.maximumConcurrentOperationCount = boundedCount

        let queue = OperationQueue()
        queue.name = label
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = boundedCount
        self.queue = queue
    }

    var operationCountForTesting: Int {
        queue.operationCount
    }

    func run<Output>(
        cancellation: AudioPCMDecodeCancellation,
        _ work: @escaping () throws -> Output
    ) async throws -> Output {
        let job = AudioDecodeJob(cancellation: cancellation, work: work)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.submit(on: queue, continuation: continuation)
            }
        } onCancel: {
            job.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}
