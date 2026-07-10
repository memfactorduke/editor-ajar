// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Lifecycle of one FR-EXP-005 export queue job.
///
/// ## Pause policy
/// `AVAssetWriter` cannot true-pause a hardware encode. Pause therefore means a graceful
/// cooperative stop of the active `ExportSession` (temp-then-publish aborts with no partial
/// destination). Resume re-enters `pending` and restarts the encode from frame zero
/// (`pausedWillRestart` makes that restart contract visible in the state machine).
///
/// ## Persistence
/// Queue jobs are **not** persisted across app relaunch in this release. A quit mid-export
/// cancels in-flight work; the user re-enqueues after relaunch.
public enum ExportJobState: String, Codable, CaseIterable, Equatable, Sendable {
    /// Waiting for the sequential drain to select this job.
    case pending

    /// An `ExportSession` is actively encoding this job.
    case running

    /// User paused: encode stopped; resume will full-restart from frame 0.
    case pausedWillRestart

    /// User cancelled; no partial destination file remains.
    case cancelled

    /// Encode failed with a typed `ExportError`; no partial destination file remains.
    case failed

    /// Encode completed and the destination was atomically published.
    case done
}

/// Discrete events that drive `ExportJobState` transitions.
public enum ExportJobEvent: String, CaseIterable, Equatable, Sendable {
    /// Drain selected this job; start a session.
    case start

    /// User requested pause (stop + later full restart).
    case pause

    /// User requested resume after `pausedWillRestart` (rejoin queue as `pending`).
    case resume

    /// User requested cancel, or the session was cancelled without a pause intent.
    case cancel

    /// Session finished and published successfully.
    case complete

    /// Session failed with a typed export error.
    case fail
}

/// Illegal job lifecycle transition.
public enum ExportJobTransitionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `event` is not allowed from `from`.
    case illegalTransition(from: ExportJobState, event: ExportJobEvent)

    public var description: String {
        switch self {
        case .illegalTransition(let from, let event):
            "illegal export job transition: \(from.rawValue) + \(event.rawValue)"
        }
    }
}

/// Pure, platform-free job state machine for the FR-EXP-005 export queue.
///
/// Lives in `AjarExport` (not `AjarCore`) so it can share export types, but it imports only
/// Foundation and remains headlessly unit-testable without AVFoundation.
public enum ExportJobStateMachine: Sendable {
    /// Explicit legal-transition table: every allowed `(state, event)` pair maps to a next state.
    public static let legalTransitions: [ExportJobState: [ExportJobEvent: ExportJobState]] = [
        .pending: [
            .start: .running,
            .cancel: .cancelled
        ],
        .running: [
            .pause: .pausedWillRestart,
            .cancel: .cancelled,
            .complete: .done,
            .fail: .failed
        ],
        .pausedWillRestart: [
            .resume: .pending,
            .cancel: .cancelled
        ],
        .cancelled: [:],
        .failed: [:],
        .done: [:]
    ]

    /// Returns whether `event` is legal from `state`.
    public static func canApply(state: ExportJobState, event: ExportJobEvent) -> Bool {
        legalTransitions[state]?[event] != nil
    }

    /// Applies `event` to `state`, or returns a typed illegal-transition error.
    public static func apply(
        state: ExportJobState,
        event: ExportJobEvent
    ) -> Result<ExportJobState, ExportJobTransitionError> {
        guard let next = legalTransitions[state]?[event] else {
            return .failure(.illegalTransition(from: state, event: event))
        }
        return .success(next)
    }

    /// Whether the job can still be scheduled or controlled.
    public static func isTerminal(_ state: ExportJobState) -> Bool {
        switch state {
        case .cancelled, .failed, .done:
            true
        case .pending, .running, .pausedWillRestart:
            false
        }
    }
}
