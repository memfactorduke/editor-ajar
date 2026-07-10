// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreMedia
import CoreVideo
import Foundation

/// One background proxy / optimized-media generation job (FR-MED-004).
///
/// ## Queue design
/// Proxies run on a **dedicated** ``ProxyGenerationQueue`` actor, not on the user
/// ``ExportQueue``. Justification: export serializes hardware encodes (one at a time). Proxy
/// generation is a ProRes software/offline transcode that must not block user export jobs, and
/// export must not wait behind long proxy batches. A second queue instance reuses the same
/// job state machine (``ExportJobStateMachine``) without sharing the hardware-encode drain.
public struct ProxyGenerationJob: Equatable, Sendable {
    /// Stable job id.
    public let id: UUID

    /// Media pool id being transcoded.
    public let mediaID: UUID

    /// Human-readable label for UI.
    public let displayName: String

    /// Immutable generation inputs.
    public let request: ProxyGenerationRequest

    /// Enqueue wall time.
    public let enqueuedAt: Date

    /// Creates a proxy job.
    public init(
        id: UUID = UUID(),
        mediaID: UUID,
        displayName: String,
        request: ProxyGenerationRequest,
        enqueuedAt: Date = Date()
    ) {
        self.id = id
        self.mediaID = mediaID
        self.displayName = displayName
        self.request = request
        self.enqueuedAt = enqueuedAt
    }
}

/// Immutable inputs for one proxy transcode (per-media, not a timeline render).
public struct ProxyGenerationRequest: Equatable, Sendable {
    /// Media being proxied.
    public let mediaID: UUID

    /// Absolute URL of the original media file to decode (session factory / app wiring).
    public let sourceURL: URL

    /// Final absolute destination URL under `caches/proxies/`.
    public let destinationURL: URL

    /// Package-relative path stored on `MediaRef.proxyState` when ready.
    public let relativePath: String

    /// Output raster (default: half original, min 640w).
    public let resolution: PixelDimensions

    /// Source frame count to encode.
    public let frameCount: Int64

    /// Source / output frame rate.
    public let frameRate: FrameRate

    /// Delivery color tag for the proxy container.
    public let colorSpace: ExportColorSpace

    /// Creates a proxy generation request.
    public init(
        mediaID: UUID,
        sourceURL: URL,
        destinationURL: URL,
        relativePath: String,
        resolution: PixelDimensions,
        frameCount: Int64,
        frameRate: FrameRate,
        colorSpace: ExportColorSpace = .rec709
    ) {
        self.mediaID = mediaID
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.relativePath = relativePath
        self.resolution = resolution
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.colorSpace = colorSpace
    }
}

/// Result of a completed proxy generation job.
public struct ProxyGenerationResult: Equatable, Sendable {
    /// Media id.
    public let mediaID: UUID

    /// Final proxy file URL.
    public let destinationURL: URL

    /// Package-relative path for `MediaProxyState.ready`.
    public let relativePath: String

    /// Frames written.
    public let videoFrameCount: Int64

    /// Creates a result.
    public init(
        mediaID: UUID,
        destinationURL: URL,
        relativePath: String,
        videoFrameCount: Int64
    ) {
        self.mediaID = mediaID
        self.destinationURL = destinationURL
        self.relativePath = relativePath
        self.videoFrameCount = videoFrameCount
    }
}

/// UI / observer snapshot for one proxy job (progress is **in-memory only**).
public struct ProxyJobSnapshot: Equatable, Sendable {
    /// Job id.
    public let id: UUID

    /// Media id.
    public let mediaID: UUID

    /// Display name.
    public let displayName: String

    /// Lifecycle state (reuses export job states).
    public let state: ExportJobState

    /// In-memory progress (not persisted).
    public let progress: ExportProgressEstimate

    /// Failure when state is `.failed`.
    public let failure: ExportError?

    /// Result when state is `.done`.
    public let result: ProxyGenerationResult?

    /// Enqueue time.
    public let enqueuedAt: Date

    /// Creates a snapshot.
    public init(
        id: UUID,
        mediaID: UUID,
        displayName: String,
        state: ExportJobState,
        progress: ExportProgressEstimate,
        failure: ExportError?,
        result: ProxyGenerationResult?,
        enqueuedAt: Date
    ) {
        self.id = id
        self.mediaID = mediaID
        self.displayName = displayName
        self.state = state
        self.progress = progress
        self.failure = failure
        self.result = result
        self.enqueuedAt = enqueuedAt
    }
}

/// Supplies original-media frames for proxy encode (injected; often `MediaTranscodeFrameProvider`).
public protocol ProxySourceFrameProvider: AnyObject {
    /// Writes source frame `index` into a writer-owned pixel buffer.
    func provideFrame(index: Int64, into pixelBuffer: CVPixelBuffer) async throws
}

/// Builds a ``ProxyGenerationSession`` for the queue.
public typealias ProxySessionFactory = @Sendable (
    _ jobID: UUID,
    _ request: ProxyGenerationRequest,
    _ onProgress: @escaping @Sendable (ExportProgress) -> Void
) -> ProxyGenerationSession
