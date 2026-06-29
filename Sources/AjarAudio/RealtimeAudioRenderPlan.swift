// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudioAtomics
import CoreAudio

/// Prepared storage kind used by a realtime audio callback plan.
public enum RealtimeAudioStorageKind: Equatable, Sendable {
    /// Samples were copied off-thread into plan-owned pointer memory.
    case ownedPointer

    /// Shared storage requiring a lock or mutex on the render callback path.
    case lockedSharedBuffer

    /// Storage that allocates scratch memory while rendering the callback.
    case allocatingCallbackBuffer

    var requiresRenderLocking: Bool {
        switch self {
        case .ownedPointer, .allocatingCallbackBuffer:
            return false
        case .lockedSharedBuffer:
            return true
        }
    }

    var requiresRenderAllocation: Bool {
        switch self {
        case .ownedPointer, .lockedSharedBuffer:
            return false
        case .allocatingCallbackBuffer:
            return true
        }
    }
}

/// Control-to-render handoff discipline used by a realtime audio callback.
public enum RealtimeAudioHandoffKind: Equatable, Sendable {
    /// No cross-thread handoff is involved.
    case none

    /// A fixed slot ring addressed by release/acquire C11 atomics.
    case lockFreeAtomicSlotRing

    /// Shared handoff storage requiring a lock or mutex on the callback path.
    case lockedSharedSlot

    /// Handoff path that allocates while acquiring from the callback.
    case allocatingAcquire

    var requiresAcquireLocking: Bool {
        switch self {
        case .none, .lockFreeAtomicSlotRing, .allocatingAcquire:
            return false
        case .lockedSharedSlot:
            return true
        }
    }

    var requiresAcquireAllocation: Bool {
        switch self {
        case .none, .lockFreeAtomicSlotRing, .lockedSharedSlot:
            return false
        case .allocatingAcquire:
            return true
        }
    }
}

/// Evidence-based safety contract for a prepared realtime audio callback plan.
public struct RealtimeAudioSafetyReport: Equatable, Sendable {
    /// Whether the render callback uses locks.
    public let usesLocks: Bool

    /// Whether the render callback allocates heap storage.
    public let allocatesDuringRender: Bool

    /// Number of frames held by the immutable prepared plan.
    public let preparedFrameCount: Int

    /// The prepared PCM storage shape used by the callback.
    public let storageKind: RealtimeAudioStorageKind

    /// Whether output memory is supplied by the caller instead of allocated by the callback.
    public let usesCallerOwnedOutput: Bool

    /// The control-to-render handoff discipline for the prepared plan.
    public let handoffKind: RealtimeAudioHandoffKind

    /// Whether acquiring a plan for the callback uses locks.
    public let usesHandoffLocks: Bool

    /// Whether acquiring a plan for the callback allocates heap storage.
    public let allocatesDuringAcquire: Bool

    /// Whether the prepared callback path satisfies the current FR-AUD-007 realtime contract.
    public var isRealtimeSafe: Bool {
        !usesLocks
            && !allocatesDuringRender
            && !usesHandoffLocks
            && !allocatesDuringAcquire
            && usesCallerOwnedOutput
    }

    /// Creates a safety report.
    public init(
        preparedFrameCount: Int,
        storageKind: RealtimeAudioStorageKind = .ownedPointer,
        usesCallerOwnedOutput: Bool = true,
        handoffKind: RealtimeAudioHandoffKind = .none
    ) {
        usesLocks = storageKind.requiresRenderLocking
        allocatesDuringRender = storageKind.requiresRenderAllocation
        self.preparedFrameCount = preparedFrameCount
        self.storageKind = storageKind
        self.usesCallerOwnedOutput = usesCallerOwnedOutput
        self.handoffKind = handoffKind
        usesHandoffLocks = handoffKind.requiresAcquireLocking
        allocatesDuringAcquire = handoffKind.requiresAcquireAllocation
    }

    func withHandoffKind(_ handoffKind: RealtimeAudioHandoffKind) -> RealtimeAudioSafetyReport {
        RealtimeAudioSafetyReport(
            preparedFrameCount: preparedFrameCount,
            storageKind: storageKind,
            usesCallerOwnedOutput: usesCallerOwnedOutput,
            handoffKind: handoffKind
        )
    }
}

/// Prepared realtime callback plan backed by immutable PCM and caller-owned output memory.
public struct RealtimeAudioRenderPlan: Sendable {
    private let format: AudioRenderFormat
    private let storage: RealtimeAudioSampleStorage
    private let frameCount: Int
    private var nextFrame: Int

    /// Creates a callback plan from an already-rendered buffer.
    public init(buffer: RenderedAudioBuffer) {
        format = buffer.format
        storage = RealtimeAudioSampleStorage(samples: buffer.samples)
        frameCount = buffer.frameCount
        nextFrame = 0
    }

    /// Returns the realtime-safety contract for this plan.
    public func safetyReport() -> RealtimeAudioSafetyReport {
        RealtimeAudioSafetyReport(
            preparedFrameCount: frameCount,
            storageKind: storage.kind,
            usesCallerOwnedOutput: true
        )
    }

    /// Copies the next frames into caller-owned interleaved output memory.
    ///
    /// The callback path performs no file I/O, no locking, and no heap allocation; callers provide
    /// a preallocated output buffer sized to a whole number of frames.
    @discardableResult
    public mutating func render(into output: UnsafeMutableBufferPointer<Float>) -> Int {
        let outputFrameCapacity = output.count / format.channelCount
        let availableFrames = max(0, frameCount - nextFrame)
        let framesToCopy = min(outputFrameCapacity, availableFrames)
        copyFrames(framesToCopy, into: output)
        clearRemainder(afterFrames: framesToCopy, in: output)
        nextFrame += framesToCopy
        return framesToCopy
    }

    /// Copies the next frames into caller-owned non-interleaved Core Audio output buffers.
    @discardableResult
    public mutating func renderNonInterleaved(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount requestedFrameCount: Int
    ) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let outputFrameCapacity = nonInterleavedFrameCapacity(
            buffers: buffers,
            requestedFrameCount: requestedFrameCount
        )
        let availableFrames = max(0, frameCount - nextFrame)
        let framesToCopy = min(outputFrameCapacity, availableFrames)
        copyNonInterleavedFrames(framesToCopy, into: buffers)
        clearNonInterleavedRemainder(
            afterFrames: framesToCopy,
            requestedFrameCount: requestedFrameCount,
            in: buffers
        )
        nextFrame += framesToCopy
        return framesToCopy
    }

    private func copyFrames(
        _ framesToCopy: Int,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let sampleCount = framesToCopy * format.channelCount
        let sourceOffset = nextFrame * format.channelCount
        guard sampleCount > 0 else {
            return
        }
        storage.copySamples(startingAt: sourceOffset, count: sampleCount, into: output)
    }

    private func clearRemainder(
        afterFrames framesToCopy: Int,
        in output: UnsafeMutableBufferPointer<Float>
    ) {
        let start = framesToCopy * format.channelCount
        guard start < output.count else {
            return
        }
        for sampleIndex in start..<output.count {
            output[sampleIndex] = 0
        }
    }

    private func nonInterleavedFrameCapacity(
        buffers: UnsafeMutableAudioBufferListPointer,
        requestedFrameCount: Int
    ) -> Int {
        guard requestedFrameCount > 0, buffers.count >= format.channelCount else {
            return 0
        }

        var frameCapacity = requestedFrameCount
        for channelIndex in 0..<format.channelCount {
            guard buffers[channelIndex].mData != nil else {
                return 0
            }
            let bufferFrameCapacity = Int(buffers[channelIndex].mDataByteSize)
                / MemoryLayout<Float>.stride
            frameCapacity = min(frameCapacity, bufferFrameCapacity)
        }
        return frameCapacity
    }

    private func copyNonInterleavedFrames(
        _ framesToCopy: Int,
        into buffers: UnsafeMutableAudioBufferListPointer
    ) {
        guard framesToCopy > 0 else {
            return
        }

        storage.copyNonInterleavedFrames(
            startingAt: nextFrame,
            frameCount: framesToCopy,
            channelCount: format.channelCount,
            into: buffers
        )
    }

    private func clearNonInterleavedRemainder(
        afterFrames framesToCopy: Int,
        requestedFrameCount: Int,
        in buffers: UnsafeMutableAudioBufferListPointer
    ) {
        guard requestedFrameCount > 0 else {
            return
        }

        for bufferIndex in 0..<buffers.count {
            guard let data = buffers[bufferIndex].mData else {
                continue
            }
            let bufferFrameCapacity = min(
                requestedFrameCount,
                Int(buffers[bufferIndex].mDataByteSize) / MemoryLayout<Float>.stride
            )
            guard framesToCopy < bufferFrameCapacity else {
                continue
            }
            let output = data.assumingMemoryBound(to: Float.self)
            for frameIndex in framesToCopy..<bufferFrameCapacity {
                output[frameIndex] = 0
            }
        }
    }
}

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
/// side uses `withCurrentPlan(_:)`, which only performs release/acquire atomic token operations and
/// mutates an already-published slot in place. Slot replacement deliberately happens only inside
/// `publish(_:)`, so ARC release of old plan storage is kept off the audio callback.
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
        currentToken.storeRelease(
            RealtimeAudioRenderPlanToken(
                generation: nextGeneration,
                slotIndex: UInt32(reusableSlot)
            ).rawValue
        )
        // Pairs with the next producer active-token scan so retired slots are not reused until a
        // concurrent consumer either publishes its hazard or observes this current-token change.
        AtomicUInt64.threadFenceSeqCst()
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

        activeToken.storeRelease(observed)
        // Hazard-pointer StoreLoad fence: the producer must observe this active token, or this
        // consumer must observe a changed current token before dereferencing the slot.
        AtomicUInt64.threadFenceSeqCst()
        guard currentToken.loadAcquire() == observed else {
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
        // StoreLoad fence for the producer side of the hazard-pointer reclamation handshake.
        AtomicUInt64.threadFenceSeqCst()
        let activeIndex = RealtimeAudioRenderPlanToken(
            rawValue: activeToken.loadAcquire()
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

    static func threadFenceSeqCst() {
        AjarAudioAtomicThreadFenceSeqCst()
    }
}
