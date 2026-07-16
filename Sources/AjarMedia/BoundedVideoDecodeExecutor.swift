// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Cancellation state polled by an active decode at owner-thread lifecycle boundaries.
final class VideoDecodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false

    func checkCancellation() throws {
        let isCancelled = lock.withLock { cancellationRequested }
        if isCancelled {
            throw CancellationError()
        }
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
        }
    }
}

/// Exactly-once continuation and ownership state for one queued blocking decode.
final class VideoDecodeJob<Output>: @unchecked Sendable {
    typealias Work = (VideoDecodeCancellation) throws -> Output

    private enum Phase: Equatable {
        case initial
        case queued
        case running
        case finished
    }

    private let lock = NSLock()
    private let cancellation = VideoDecodeCancellation()
    private var phase = Phase.initial
    private var cancellationRequested = false
    private var continuation: CheckedContinuation<Output, Error>?
    private var operation: BlockOperation?
    private var work: Work?

    init(work: @escaping Work) {
        self.work = work
    }

    /// Installs the continuation and operation as one state transition. A task cancelled before
    /// submission never enters the executor or retains its captured asset in the queue.
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

    /// Queued jobs complete immediately and release their captured work. Running jobs only set a
    /// cooperative flag; the owner worker finishes its active AVAssetReader call and tears down
    /// that reader itself.
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
            case .running:
                break
            case .finished:
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
            try cancellation.checkCancellation()
            result = .success(try workToRun(cancellation))
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

/// Fixed-width executor for APIs that block a thread while decoding.
final class BoundedVideoDecodeExecutor: @unchecked Sendable {
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

    func run<Output>(
        _ work: @escaping (VideoDecodeCancellation) throws -> Output
    ) async throws -> Output {
        let job = VideoDecodeJob(work: work)
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
