// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudioAtomics

/// Typed failures for the realtime control-to-audio render-plan handoff.
public enum RealtimeAudioRenderPlanHandoffError: Error, Equatable, Sendable {
    /// The atomic token storage could not be created during non-realtime setup.
    case atomicStorageUnavailable

    /// The atomic token storage is not lock-free on this platform.
    case atomicStorageNotLockFree

    /// The fixed slot ring had no reusable slot under the single-producer/single-consumer contract.
    case noReusableSlot
}

/// Single-producer/single-consumer FR-AUD-007 handoff for realtime render plans.
///
/// Publishing happens on the control side and may initialize or release plan storage. The audio
/// side uses `withCurrentPlan(_:)`, which only performs lock-free atomic token operations and
/// mutates an already-published slot in place. Slot replacement deliberately happens only inside
/// `publish(_:)`, so ARC release of old plan storage is kept off the audio callback.
///
/// Slot reclamation is a hazard handshake where each side stores to one token and then loads the
/// *other* token. That store-then-load-from-a-different-location pattern (store buffering) is
/// only safe under `seq_cst` ordering — with release/acquire both sides can miss each other's
/// store, letting the producer overwrite a slot the audio callback is still reading.
public final class RealtimeAudioRenderPlanHandoff: @unchecked Sendable {
    public static let slotCount = 3

    private let slots: [RealtimeAudioRenderPlanSlot]
    private let currentToken: AtomicUInt64
    private let activeToken: AtomicUInt64
    private var nextGeneration: UInt32

    /// Creates an empty handoff. Publish an initial plan before the audio callback acquires.
    public init() throws {
        currentToken = try AtomicUInt64(initialValue: RealtimeAudioRenderPlanToken.none.rawValue)
        activeToken = try AtomicUInt64(initialValue: RealtimeAudioRenderPlanToken.none.rawValue)
        slots = (0..<Self.slotCount).map { _ in RealtimeAudioRenderPlanSlot() }
        nextGeneration = 0
    }

    /// Publishes a fully-prepared plan from the control side.
    public func publish(_ plan: RealtimeAudioRenderPlan) throws {
        let reusableSlot = try reusableSlotIndex()
        slots[reusableSlot].store(plan)
        nextGeneration &+= 1
        // SeqCst producer store of the hazard handshake: it pairs with the next reusable-slot
        // scan's seq_cst active-token load, so a retired slot is never reused until a concurrent
        // consumer either had its hazard store observed or observes this current-token change.
        currentToken.storeSeqCst(
            RealtimeAudioRenderPlanToken(
                generation: nextGeneration,
                slotIndex: UInt32(reusableSlot)
            ).rawValue
        )
    }

    /// Acquires and uses the current plan without locks, heap allocation, or ARC retain on the path.
    @discardableResult
    public func withCurrentPlan<Result>(
        _ body: (inout RealtimeAudioRenderPlan) -> Result
    ) -> Result? {
        let observed = currentToken.loadAcquire()
        guard observed != RealtimeAudioRenderPlanToken.none.rawValue else {
            return nil
        }

        // SeqCst consumer half of the hazard handshake: store the hazard, then re-check the
        // current token from a different location. Before the slot is dereferenced, either the
        // producer observes this active token or this consumer observes a changed current
        // token — a store-buffering guarantee release/acquire does not provide.
        activeToken.storeSeqCst(observed)
        guard currentToken.loadSeqCst() == observed else {
            activeToken.storeRelease(RealtimeAudioRenderPlanToken.none.rawValue)
            return nil
        }

        guard let slotIndex = RealtimeAudioRenderPlanToken(rawValue: observed).slotIndex else {
            activeToken.storeRelease(RealtimeAudioRenderPlanToken.none.rawValue)
            return nil
        }

        let result = slots[Int(slotIndex)].withMutablePlan(body)
        activeToken.storeRelease(RealtimeAudioRenderPlanToken.none.rawValue)
        return result
    }

    /// Returns the safety contract for the currently-published plan, if any.
    public func safetyReport() -> RealtimeAudioSafetyReport? {
        let token = RealtimeAudioRenderPlanToken(rawValue: currentToken.loadAcquire())
        guard let slotIndex = token.slotIndex else {
            return nil
        }

        return slots[Int(slotIndex)]
            .safetyReport()?
            .withHandoffKind(.lockFreeAtomicSlotRing)
    }

    private func reusableSlotIndex() throws -> Int {
        let currentIndex = RealtimeAudioRenderPlanToken(
            rawValue: currentToken.loadAcquire()
        ).slotIndex
        // SeqCst producer load of the hazard handshake, paired with the previous publish's
        // seq_cst current-token store and the consumer's seq_cst hazard store/re-check.
        let activeIndex = RealtimeAudioRenderPlanToken(
            rawValue: activeToken.loadSeqCst()
        ).slotIndex

        for slotIndex in slots.indices where UInt32(slotIndex) != currentIndex
            && UInt32(slotIndex) != activeIndex {
            return slotIndex
        }

        throw RealtimeAudioRenderPlanHandoffError.noReusableSlot
    }
}

private struct RealtimeAudioRenderPlanToken: Equatable {
    static let none = RealtimeAudioRenderPlanToken(rawValue: UInt64.max)

    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(generation: UInt32, slotIndex: UInt32) {
        rawValue = (UInt64(generation) << 32) | UInt64(slotIndex)
    }

    var slotIndex: UInt32? {
        guard rawValue != Self.none.rawValue else {
            return nil
        }
        let index = UInt32(rawValue & UInt64(UInt32.max))
        guard index < UInt32(RealtimeAudioRenderPlanHandoff.slotCount) else {
            return nil
        }
        return index
    }
}

private final class RealtimeAudioRenderPlanSlot: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<RealtimeAudioRenderPlan>
    private var hasPlan: Bool

    init() {
        pointer = UnsafeMutablePointer<RealtimeAudioRenderPlan>.allocate(capacity: 1)
        hasPlan = false
    }

    deinit {
        if hasPlan {
            pointer.deinitialize(count: 1)
        }
        pointer.deallocate()
    }

    func store(_ plan: RealtimeAudioRenderPlan) {
        if hasPlan {
            pointer.deinitialize(count: 1)
        }
        pointer.initialize(to: plan)
        hasPlan = true
    }

    func withMutablePlan<Result>(
        _ body: (inout RealtimeAudioRenderPlan) -> Result
    ) -> Result? {
        guard hasPlan else {
            return nil
        }
        return body(&pointer.pointee)
    }

    func safetyReport() -> RealtimeAudioSafetyReport? {
        guard hasPlan else {
            return nil
        }
        return pointer.pointee.safetyReport()
    }
}

private final class AtomicUInt64: @unchecked Sendable {
    private let storage: OpaquePointer

    init(initialValue: UInt64) throws {
        guard let storage = AjarAudioAtomicUInt64Create(initialValue) else {
            throw RealtimeAudioRenderPlanHandoffError.atomicStorageUnavailable
        }
        guard AjarAudioAtomicUInt64IsLockFree(storage) != 0 else {
            AjarAudioAtomicUInt64Destroy(storage)
            throw RealtimeAudioRenderPlanHandoffError.atomicStorageNotLockFree
        }
        self.storage = storage
    }

    deinit {
        AjarAudioAtomicUInt64Destroy(storage)
    }

    func loadAcquire() -> UInt64 {
        AjarAudioAtomicUInt64LoadAcquire(storage)
    }

    func storeRelease(_ value: UInt64) {
        AjarAudioAtomicUInt64StoreRelease(storage, value)
    }

    func loadSeqCst() -> UInt64 {
        AjarAudioAtomicUInt64LoadSeqCst(storage)
    }

    func storeSeqCst(_ value: UInt64) {
        AjarAudioAtomicUInt64StoreSeqCst(storage, value)
    }
}
