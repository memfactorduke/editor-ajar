// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Media tier selected for a source during export graph evaluation (FR-EXP-007 / FR-MED-004).
///
/// ADR-0019 requires export to pull **original** media. Proxy/optimized media is a playback
/// concern (FR-MED-004, issue #217). This enum is the audit surface so golden-export and unit
/// tests can assert the contract before proxy generation lands.
public enum ExportMediaSourceTier: String, Codable, Equatable, Sendable {
    /// Full-resolution original media. Required for every export frame (FR-EXP-007).
    case original

    /// Proxy / optimized media. Valid for playback only; never a legal export source.
    case proxy
}

/// Session-level policy that resolves which media tier export will request per `MediaRef` id.
///
/// ## Proxy exclusion hook (FR-EXP-007, FR-MED-004 not yet landed)
///
/// `AjarExport` does not depend on `AjarMedia` and does not select proxy files itself
/// (ADR-0019). The app/CLI injects an `ExportRenderSourceProvider` that **must** decode
/// originals. This policy is the stable assertion hook:
///
/// 1. Production sessions use ``alwaysOriginal`` — every media id resolves to `.original`.
/// 2. `ExportSession` records each resolution into ``ExportFrameSourceSelection`` rows while
///    writing frames so tests can assert `records.allSatisfy { $0.tier == .original }`.
/// 3. When FR-MED-004 (#217) lands, playback may point at proxies, but export adapters still
///    consult this policy (or an extended resolver) and continue to resolve `.original`. Extend
///    ``resolvedTier(for:)`` / add resolver injection rather than inventing a second audit path.
public struct ExportSourceSelectionPolicy: Equatable, Sendable {
    /// Production default: every media id resolves to original media.
    public static let alwaysOriginal = ExportSourceSelectionPolicy(defaultTier: .original)

    /// Tier returned by ``resolvedTier(for:)`` for every media id.
    ///
    /// FR-MED-004 may replace the uniform default with a per-id table while keeping export on
    /// `.original`. Tests may inject `.proxy` only to prove the audit records the policy.
    public let defaultTier: ExportMediaSourceTier

    /// Creates a uniform-tier policy.
    public init(defaultTier: ExportMediaSourceTier = .original) {
        self.defaultTier = defaultTier
    }

    /// Resolves the media tier export will request for `mediaID`.
    public func resolvedTier(for mediaID: UUID) -> ExportMediaSourceTier {
        _ = mediaID
        return defaultTier
    }
}

/// One recorded source-tier resolution for a single export frame and media id (FR-EXP-007).
public struct ExportFrameSourceSelection: Equatable, Sendable {
    /// Zero-based sequential export frame index.
    public let frameIndex: Int64

    /// Media pool id that the policy was asked about.
    public let mediaID: UUID

    /// Tier the session policy resolved for this media id.
    public let tier: ExportMediaSourceTier

    /// Creates an audit row.
    public init(frameIndex: Int64, mediaID: UUID, tier: ExportMediaSourceTier) {
        self.frameIndex = frameIndex
        self.mediaID = mediaID
        self.tier = tier
    }
}
