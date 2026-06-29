// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// Whether the prepared callback path satisfies the current FR-AUD-007 realtime contract.
    public var isRealtimeSafe: Bool {
        !usesLocks && !allocatesDuringRender && usesCallerOwnedOutput
    }

    /// Creates a safety report.
    public init(
        preparedFrameCount: Int,
        storageKind: RealtimeAudioStorageKind = .ownedPointer,
        usesCallerOwnedOutput: Bool = true
    ) {
        usesLocks = storageKind.requiresRenderLocking
        allocatesDuringRender = storageKind.requiresRenderAllocation
        self.preparedFrameCount = preparedFrameCount
        self.storageKind = storageKind
        self.usesCallerOwnedOutput = usesCallerOwnedOutput
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
}

private final class RealtimeAudioSampleStorage: @unchecked Sendable {
    let kind = RealtimeAudioStorageKind.ownedPointer

    private let pointer: UnsafeMutablePointer<Float>
    private let sampleCount: Int

    init(samples: [Float]) {
        sampleCount = samples.count
        pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(sampleCount, 1))
        guard sampleCount > 0 else {
            return
        }

        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else {
                return
            }
            pointer.initialize(from: baseAddress, count: source.count)
        }
    }

    deinit {
        pointer.deinitialize(count: sampleCount)
        pointer.deallocate()
    }

    func copySamples(
        startingAt sourceOffset: Int,
        count: Int,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let sourceBase = pointer.advanced(by: sourceOffset)
        for sampleIndex in 0..<count {
            output[sampleIndex] = sourceBase[sampleIndex]
        }
    }
}
