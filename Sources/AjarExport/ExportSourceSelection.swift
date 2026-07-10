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
/// ## Proxy exclusion hook (FR-EXP-007 / FR-MED-004)
///
/// `AjarExport` does not depend on `AjarMedia` and does not select proxy files itself
/// (ADR-0019). Production ``RenderGraphExportFrameProvider`` builds graphs with
/// `proxyFileExists {_ in false}` and records **executed** source-node tiers into
/// ``ExportFrameSourceSelection`` rows (via ``ExportGraphSourceAuditing``). The policy remains
/// the fallback for stub providers and a secondary invariant:
///
/// 1. Production sessions use ``alwaysOriginal`` — every media id resolves to `.original`.
/// 2. `ExportSession` prefers graph-observed tiers when available, else this policy, so tests
///    can assert `records.allSatisfy { $0.tier == .original }` against the real graph.
/// 3. Playback may select proxies when `ProjectSettings.preferProxyPlayback` is on and a
///    proxy is ready (FR-MED-004), but export graphs stay structurally original-only.
public struct ExportSourceSelectionPolicy: Equatable, Sendable {
    /// Production default: every media id resolves to original media.
    public static let alwaysOriginal = ExportSourceSelectionPolicy(defaultTier: .original)

    /// Explicit alias for proxy-enabled projects: export remains pinned to originals
    /// (FR-EXP-007) even when playback prefers proxies (FR-MED-004).
    public static let alwaysOriginalForProxyEnabledProject = ExportSourceSelectionPolicy(
        defaultTier: .original
    )

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
    ///
    /// Production policies ignore playback proxy preference and always return `.original`.
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
