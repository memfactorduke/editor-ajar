// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Cache identity for one rendered frame, shared by the RAM and disk cache tiers (ADR-0009).
///
/// The identity mirrors the render executor's RAM cache key: the render graph output node's
/// content hash plus the output texture settings that change the produced pixels. The color mode
/// and pixel format are carried as opaque raw values so this type stays platform-free; the
/// platform render module defines the mapping and must apply it identically on both tiers
/// (FR-PLAY-005, FR-CMP-006).
public struct RenderFrameCacheIdentity: Hashable, Sendable {
    /// Content hash of the render graph output node.
    public let contentHash: ContentHash

    /// Opaque raw value for the output color mode (presented vs. linear working).
    public let colorModeRawValue: UInt32

    /// Opaque raw value for the output texture pixel format.
    public let pixelFormatRawValue: UInt32

    /// Output width in pixels.
    public let width: Int

    /// Output height in pixels.
    public let height: Int

    /// Creates a frame cache identity.
    public init(
        contentHash: ContentHash,
        colorModeRawValue: UInt32,
        pixelFormatRawValue: UInt32,
        width: Int,
        height: Int
    ) {
        self.contentHash = contentHash
        self.colorModeRawValue = colorModeRawValue
        self.pixelFormatRawValue = pixelFormatRawValue
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// Deterministic file name for this identity's disk cache entry.
    ///
    /// Every identity component participates, so two identities never share a file and an edit
    /// that changes the content hash makes the old entry unreachable by construction.
    public var entryFileName: String {
        let hashComponent = "\(contentHash.algorithm.rawValue)-\(contentHash.digest)"
        let formatComponent = "c\(colorModeRawValue)-p\(pixelFormatRawValue)-\(width)x\(height)"
        return "\(hashComponent)-\(formatComponent).ajarframe"
    }
}
