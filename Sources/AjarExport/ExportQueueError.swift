// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed failures from FR-EXP-005 queue control operations.
public enum ExportQueueError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No job exists for the given id.
    case jobNotFound(UUID)

    /// The requested control action is illegal for the job's current state.
    case illegalJobTransition(ExportJobTransitionError)

    /// Only one hardware-encode job may run at a time; an internal drain invariant broke.
    case concurrentEncodeInvariantViolated

    /// Queue job identifiers are immutable and may never replace an existing record.
    case duplicateJobID(UUID)

    /// A nonterminal movie or GIF job already owns the same output path.
    case destinationAlreadyQueued(URL)

    /// Stable diagnostic text for logs and nonlocalized adapters.
    public var description: String {
        switch self {
        case .jobNotFound(let id):
            "export queue job \(id) was not found"
        case .illegalJobTransition(let error):
            error.description
        case .concurrentEncodeInvariantViolated:
            "export queue attempted to start a second concurrent hardware encode"
        case .duplicateJobID(let id):
            "export queue already contains job \(id)"
        case .destinationAlreadyQueued(let url):
            "another export is already queued for \(url.path)"
        }
    }
}
