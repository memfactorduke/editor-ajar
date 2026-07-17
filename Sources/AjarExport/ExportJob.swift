// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Output family scheduled by the heterogeneous export queue.
public enum ExportJobKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// A container export driven by ``ExportSession``.
    case movie

    /// An ImageIO animated-GIF export driven by ``AnimatedGIFExportSession``.
    case animatedGIF
}

/// Immutable description of one enqueued export (FR-EXP-005).
///
/// `request` already captures a project **value** snapshot at enqueue time; concurrent edits to
/// the live document cannot mutate a running or pending job.
public struct ExportJob: Sendable, Identifiable {
    /// Stable queue identity (also used as the `ExportSession` id).
    public let id: UUID

    /// Human-readable label for UI (sequence name, file name, etc.).
    public let displayName: String

    /// Validated export inputs including the project snapshot.
    public let request: ExportRequest

    /// Wall-clock enqueue time (not persisted).
    public let enqueuedAt: Date

    /// Creates a job record. Callers must have already snapshotted the project into `request`.
    public init(
        id: UUID = UUID(),
        displayName: String,
        request: ExportRequest,
        enqueuedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.request = request
        self.enqueuedAt = enqueuedAt
    }
}

/// Observable queue row for UI and tests.
public struct ExportJobSnapshot: Equatable, Sendable, Identifiable {
    /// Job identity.
    public let id: UUID

    /// UI label.
    public let displayName: String

    /// Output family for choosing the appropriate queue-row treatment.
    public let kind: ExportJobKind

    /// Destination URL from the captured request.
    public let destinationURL: URL

    /// Current lifecycle state.
    public let state: ExportJobState

    /// Frames + rolling ETA for the current session run.
    public let progress: ExportProgressEstimate

    /// Failure when `state == .failed`.
    public let failure: ExportError?

    /// Success summary when `state == .done`.
    public let result: ExportResult?

    /// Enqueue timestamp.
    public let enqueuedAt: Date

    /// Captured project snapshot identity checks (sequence id at enqueue).
    public let snapshotSequenceID: UUID

    /// Creates a snapshot.
    public init(
        id: UUID,
        displayName: String,
        kind: ExportJobKind = .movie,
        destinationURL: URL,
        state: ExportJobState,
        progress: ExportProgressEstimate,
        failure: ExportError?,
        result: ExportResult?,
        enqueuedAt: Date,
        snapshotSequenceID: UUID
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.destinationURL = destinationURL
        self.state = state
        self.progress = progress
        self.failure = failure
        self.result = result
        self.enqueuedAt = enqueuedAt
        self.snapshotSequenceID = snapshotSequenceID
    }
}

/// Builds one-shot sessions for the sequential export queue.
///
/// The factory owns frame/audio provider injection (ADR-0019). The queue only schedules and
/// cancels sessions; it never imports AppKit or decodes media.
public typealias ExportSessionFactory =
    @Sendable (
        _ jobID: UUID,
        _ request: ExportRequest,
        _ onFrameProgress: (@Sendable (ExportProgress) -> Void)?
    ) -> ExportSession

/// Builds one-shot animated-GIF sessions for the heterogeneous export queue.
///
/// Like ``ExportSessionFactory``, the factory owns render-provider injection. The queue keeps
/// movie and GIF requests in one strict-serial schedule and only drives their shared lifecycle.
public typealias AnimatedGIFExportSessionFactory =
    @Sendable (
        _ jobID: UUID,
        _ request: AnimatedGIFExportRequest,
        _ onFrameProgress: (@Sendable (ExportProgress) -> Void)?
    ) -> AnimatedGIFExportSession
