// SPDX-License-Identifier: GPL-3.0-or-later

import AjarRender
import Foundation

/// App-side name for the cancellation boundary shared with `AjarRender`'s final file commit.
typealias DiskWriteBehindCancellation = MetalDiskCacheWriteCancellation

/// Immutable admission lease captured when a render begins. Carrying this lease through render
/// completion prevents an obsolete render from borrowing the next project's fresh owner if a
/// session transition lands between its last cancellation check and write-behind submission.
struct DiskWriteBehindSession: Sendable {
    let ownerID: UUID
    let cancellation: DiskWriteBehindCancellation
}

/// Process-wide admission and ownership for render disk-cache write-behind work.
///
/// Admission is deliberately drop-on-full: playback returns its rendered texture immediately
/// instead of retaining more full-frame textures or awaiting disk capacity. The coordinator owns
/// every accepted task until `MetalDiskFrameCache.persist` physically returns, so cancellation
/// never releases a slot while an old GCD write is still running.
actor DiskWriteBehindCoordinator {
    typealias Operation = @Sendable (DiskWriteBehindCancellation) async -> Void

    static let maximumConcurrentWrites = 2
    static let shared = DiskWriteBehindCoordinator(
        maximumConcurrentWrites: maximumConcurrentWrites
    )

    struct Snapshot: Equatable, Sendable {
        let activeWriteCount: Int
        let peakActiveWriteCount: Int
        let droppedWriteCount: Int
        let ownerCount: Int
    }

    private struct ActiveWrite {
        let ownerID: UUID
        let cancellation: DiskWriteBehindCancellation
        let task: Task<Void, Never>
    }

    let writeLimit: Int
    private var activeWrites: [UUID: ActiveWrite] = [:]
    private var peakActiveWriteCount = 0
    private var droppedWriteCount = 0
    private var ownerDrainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(maximumConcurrentWrites: Int) {
        writeLimit = max(1, maximumConcurrentWrites)
    }

    @discardableResult
    func submit(
        ownerID: UUID,
        cancellation: DiskWriteBehindCancellation,
        operation: @escaping Operation
    ) -> Bool {
        guard !Task.isCancelled,
              !cancellation.isCancelled,
              activeWrites.count < writeLimit else {
            droppedWriteCount += 1
            return false
        }

        let writeID = UUID()
        let task = Task.detached(priority: .background) { [self] in
            if !cancellation.isCancelled {
                await operation(cancellation)
            }
            await complete(writeID)
        }
        activeWrites[writeID] = ActiveWrite(
            ownerID: ownerID,
            cancellation: cancellation,
            task: task
        )
        peakActiveWriteCount = max(peakActiveWriteCount, activeWrites.count)
        return true
    }

    func drain(ownerID: UUID) async {
        await withCheckedContinuation { continuation in
            if hasActiveWrite(ownerID: ownerID) {
                ownerDrainWaiters[ownerID, default: []].append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    func cancelAndDrain(ownerID: UUID) async {
        cancel(ownerID: ownerID)
        await drain(ownerID: ownerID)
    }

    func cancel(ownerID: UUID) {
        for write in activeWrites.values where write.ownerID == ownerID {
            write.cancellation.cancel()
            write.task.cancel()
        }
        resumeOwnerDrainWaitersIfNeeded(ownerID: ownerID)
    }

    func waitUntilIdleForTesting() async {
        await withCheckedContinuation { continuation in
            if activeWrites.isEmpty {
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
            }
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeWriteCount: activeWrites.count,
            peakActiveWriteCount: peakActiveWriteCount,
            droppedWriteCount: droppedWriteCount,
            ownerCount: Set(activeWrites.values.map(\.ownerID)).count
        )
    }

    private func complete(_ writeID: UUID) {
        guard let completed = activeWrites.removeValue(forKey: writeID) else {
            return
        }
        resumeOwnerDrainWaitersIfNeeded(ownerID: completed.ownerID)
        guard activeWrites.isEmpty else {
            return
        }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func hasActiveWrite(ownerID: UUID) -> Bool {
        activeWrites.values.contains { $0.ownerID == ownerID }
    }

    private func resumeOwnerDrainWaitersIfNeeded(ownerID: UUID) {
        guard !hasActiveWrite(ownerID: ownerID),
              let waiters = ownerDrainWaiters.removeValue(forKey: ownerID) else {
            return
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Narrow sendability boundary for immutable, completed Metal render state handed to background
/// persistence. `RenderedFrame` also retains non-Sendable implementation objects, so the wider
/// engine result intentionally remains unannotated.
private struct DiskWriteBehindRequest: Sendable {
    let diskCache: MetalDiskFrameCache
    let frame: MetalDiskFrameCachePersistenceFrame
    let output: RenderOutputDescriptor

    func persist(cancellation: DiskWriteBehindCancellation) async {
        do {
            try cancellation.check()
            try await diskCache.persist(
                frame: frame,
                output: output,
                cancellation: cancellation
            )
        } catch {
            // Disk population is opportunistic. Cancellation and I/O failures remain cache misses;
            // the already-rendered playback frame is still valid and must not fail presentation.
        }
    }
}

/// Per-pipeline generation state. Accepted work lives in the process coordinator, not here, so a
/// pipeline deallocation can still find, cancel, and physically drain every operation it started.
final class DiskWriteBehindTracker: @unchecked Sendable {
    private struct State {
        var currentOwnerID = UUID()
        var currentCancellation = DiskWriteBehindCancellation()
        var retiredOwnerIDs: Set<UUID> = []
        var isShutdown = false
    }

    private let coordinator: DiskWriteBehindCoordinator
    private let lock = NSLock()
    private var state = State()

    init(coordinator: DiskWriteBehindCoordinator) {
        self.coordinator = coordinator
    }

    func submit(
        diskCache: MetalDiskFrameCache,
        frame: MetalDiskFrameCachePersistenceFrame,
        output: RenderOutputDescriptor,
        session: DiskWriteBehindSession
    ) async {
        let request = DiskWriteBehindRequest(
            diskCache: diskCache,
            frame: frame,
            output: output
        )
        _ = await submit(session: session) { cancellation in
            await request.persist(cancellation: cancellation)
        }
    }

    func captureSession() -> DiskWriteBehindSession? {
        lock.withLock {
            guard !Task.isCancelled, !state.isShutdown else {
                return nil
            }
            return DiskWriteBehindSession(
                ownerID: state.currentOwnerID,
                cancellation: state.currentCancellation
            )
        }
    }

    @discardableResult
    func submit(_ operation: @escaping DiskWriteBehindCoordinator.Operation) async -> Bool {
        guard let session = captureSession() else {
            return false
        }
        return await submit(session: session, operation)
    }

    @discardableResult
    func submit(
        session: DiskWriteBehindSession,
        _ operation: @escaping DiskWriteBehindCoordinator.Operation
    ) async -> Bool {
        return await coordinator.submit(
            ownerID: session.ownerID,
            cancellation: session.cancellation,
            operation: operation
        )
    }

    func beginNewSession() {
        let retired = lock.withLock { () -> (UUID, DiskWriteBehindCancellation)? in
            guard !state.isShutdown else {
                return nil
            }
            let retired = (state.currentOwnerID, state.currentCancellation)
            state.retiredOwnerIDs.insert(retired.0)
            state.currentOwnerID = UUID()
            state.currentCancellation = DiskWriteBehindCancellation()
            return retired
        }
        guard let (ownerID, cancellation) = retired else {
            return
        }
        cancellation.cancel()
        Task { [weak self, coordinator] in
            await coordinator.cancelAndDrain(ownerID: ownerID)
            self?.retiredOwnerDidDrain(ownerID)
        }
    }

    func waitForAll() async {
        let ownerIDs = lock.withLock {
            state.retiredOwnerIDs.union([state.currentOwnerID])
        }
        for ownerID in ownerIDs {
            await coordinator.drain(ownerID: ownerID)
        }
    }

    func shutdown() {
        let closure = closeAdmission()
        closure.currentCancellation.cancel()
        for ownerID in closure.ownerIDs {
            Task { [coordinator] in
                await coordinator.cancel(ownerID: ownerID)
            }
        }
    }

    func shutdownAndWait() async {
        let closure = closeAdmission()
        closure.currentCancellation.cancel()
        await withTaskGroup(of: Void.self) { group in
            for ownerID in closure.ownerIDs {
                group.addTask { [coordinator] in
                    await coordinator.cancelAndDrain(ownerID: ownerID)
                }
            }
            await group.waitForAll()
        }
    }

    private func closeAdmission() -> (
        ownerIDs: Set<UUID>,
        currentCancellation: DiskWriteBehindCancellation
    ) {
        lock.withLock {
            state.isShutdown = true
            return (
                state.retiredOwnerIDs.union([state.currentOwnerID]),
                state.currentCancellation
            )
        }
    }

    private func retiredOwnerDidDrain(_ ownerID: UUID) {
        _ = lock.withLock {
            state.retiredOwnerIDs.remove(ownerID)
        }
    }
}
