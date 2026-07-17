// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

extension MediaPreviewCache {
    /// Runs a transient decode (e.g. hover-scrub) through the same worker bound — no disk write.
    func runBounded<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        await acquireWorker()
        do {
            try Task.checkCancellation()
            let value = try await work()
            try Task.checkCancellation()
            releaseWorker()
            return value
        } catch {
            releaseWorker()
            throw error
        }
    }

    /// Hover-scrub frame at `time`, scheduled under the worker bound (not a free-standing decoder).
    func hoverFramePNG(for media: MediaRef, at time: RationalTime) async throws -> Data {
        try await runBounded {
            try await hoverExtractor(media, time)
        }
    }

    /// Transfer the held worker slot on resume — never decrement then re-increment (M2).
    private func acquireWorker() async {
        if activeWorkers < workerLimit {
            activeWorkers += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // Slot ownership was transferred by `releaseWorker`; do not increment again.
    }

    private func releaseWorker() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            activeWorkers -= 1
        }
    }
}
