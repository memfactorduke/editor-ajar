// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Cooperative interruption hook for deterministic offline rendering.
///
/// The mixer invokes this hook at bounded intervals in every frame-heavy pass. Callers may
/// throw their own typed cancellation error; the mixer deliberately preserves that error.
public typealias AudioRenderCancellationCheck = @Sendable () throws -> Void

/// Stable structural identity for one nested-render occurrence.
///
/// Clip IDs alone are insufficient because compound decomposition can legally duplicate them.
/// Track identity plus item position keeps those occurrences separate while remaining stable for
/// every bounded chunk rendered from the same captured project snapshot.
enum OfflineAudioRenderPathComponent: Hashable, Sendable {
    case sequence(UUID)
    case track(UUID)
    case item(Int)
    case clip(UUID)
}

typealias OfflineAudioRenderPath = [OfflineAudioRenderPathComponent]

/// State carried between bounded renders of one continuous timeline range.
///
/// Most mix parameters are functions of absolute timeline time and therefore need no state.
/// Ducking is the exception: attack/hold/release envelopes depend on the preceding sample. This
/// continuation preserves a bounded tail of envelope states so chunked production export is
/// sample-identical to one monolithic render without retaining preceding PCM or detector arrays.
public struct OfflineAudioRenderContinuation: Sendable {
    var duckingStates: [OfflineDuckingContinuationKey: OfflineDuckingContinuationState] = [:]

    /// Creates an empty continuation. The first render begins every ducking envelope at rest,
    /// matching the historical monolithic-range behavior.
    public init() {}
}

struct OfflineDuckingContinuationKey: Hashable, Sendable {
    let renderPath: OfflineAudioRenderPath
    let ruleIndex: Int
}

struct OfflineDuckingEnvelopeState: Sendable {
    var amount = Double(0)
    var holdRemaining = 0
}

struct OfflineDuckingEnvelopeSnapshot: Sendable {
    let rangeStart: RationalTime
    let envelope: OfflineDuckingEnvelopeState
}

struct OfflineDuckingContinuationState: Sendable {
    let snapshots: [OfflineDuckingEnvelopeSnapshot]

    init(
        range: TimeRange,
        sampleRate: Int,
        history: OfflineDuckingEnvelopeHistory
    ) throws {
        let rangeEnd = try range.start + range.duration
        snapshots = try history.orderedStates.enumerated().map { index, envelope in
            let boundaryFrame = history.firstBoundaryFrame + index
            let rangeStart: RationalTime
            if boundaryFrame == history.lastBoundaryFrame {
                // Preserve the prior exact-adjacency contract even for a range whose duration
                // rounded to an integral output frame count.
                rangeStart = rangeEnd
            } else {
                let offset = try RationalTime(
                    value: Int64(boundaryFrame),
                    timescale: Int64(sampleRate)
                )
                rangeStart = try range.start + offset
            }
            return OfflineDuckingEnvelopeSnapshot(
                rangeStart: rangeStart,
                envelope: envelope
            )
        }
    }

    func envelope(at rangeStart: RationalTime) -> OfflineDuckingEnvelopeState? {
        snapshots.last { $0.rangeStart == rangeStart }?.envelope
    }
}

/// Fixed-size ring of frame-boundary envelope states produced by one render.
///
/// Each compound level expands its child window by two leading and one trailing frame. The next
/// adjacent outer chunk can consequently restart a deepest child up to three frames per nesting
/// level before that child's prior end. Keeping `3 * 16 + 1` boundaries includes both ends of the
/// maximum 48-frame overlap while remaining constant-size regardless of render duration.
struct OfflineDuckingEnvelopeHistory {
    static let maximumSnapshotCount =
        (3 * RenderGraphBuilder.maximumCompoundNestingDepth) + 1

    private var storage = [OfflineDuckingEnvelopeState](
        repeating: OfflineDuckingEnvelopeState(),
        count: maximumSnapshotCount
    )
    private var startIndex = 0
    private(set) var count = 0
    private var appendedCount = 0

    var firstBoundaryFrame: Int {
        appendedCount - count
    }

    var lastBoundaryFrame: Int {
        appendedCount - 1
    }

    var orderedStates: [OfflineDuckingEnvelopeState] {
        (0..<count).map { storage[(startIndex + $0) % Self.maximumSnapshotCount] }
    }

    mutating func append(_ envelope: OfflineDuckingEnvelopeState) {
        if count < Self.maximumSnapshotCount {
            storage[(startIndex + count) % Self.maximumSnapshotCount] = envelope
            count += 1
        } else {
            storage[startIndex] = envelope
            startIndex = (startIndex + 1) % Self.maximumSnapshotCount
        }
        appendedCount += 1
    }
}
