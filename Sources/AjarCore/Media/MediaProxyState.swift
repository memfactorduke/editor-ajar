// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Durable per-media proxy lifecycle state (FR-MED-004).
///
/// Persisted on `MediaRef` (schemaMinor 11). Generation **progress** is intentionally not
/// stored here — that is session-only UI state held by the app / proxy queue.
public enum MediaProxyState: Codable, Hashable, Sendable, Equatable {
    /// No proxy has been requested or recorded for this media.
    case none

    /// A background generation job is in flight (or was interrupted mid-run).
    case generating

    /// A regeneratable proxy file is ready at a path relative to the `.ajar` package root.
    ///
    /// Example: `caches/proxies/<mediaID>-<hashPrefix>-960x540.mov` (ADR-0007).
    case ready(relativePath: String)

    /// Last generation attempt failed; `message` is optional diagnostic text for UI.
    case failed(message: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case relativePath
        case message
    }

    private enum Kind: String, Codable {
        case none
        case generating
        case ready
        case failed
    }

    /// Creates a proxy state from a decoder (nested-legacy: absent → callers default to `.none`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:
            self = .none
        case .generating:
            self = .generating
        case .ready:
            let path = try container.decode(String.self, forKey: .relativePath)
            self = .ready(relativePath: path)
        case .failed:
            self = .failed(message: try container.decodeIfPresent(String.self, forKey: .message))
        }
    }

    /// Encodes the durable proxy state.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .generating:
            try container.encode(Kind.generating, forKey: .kind)
        case .ready(let relativePath):
            try container.encode(Kind.ready, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encodeIfPresent(message, forKey: .message)
        }
    }

    /// Relative package path when ready; otherwise `nil`.
    public var readyRelativePath: String? {
        if case .ready(let relativePath) = self {
            return relativePath
        }
        return nil
    }

    /// Whether a ready proxy has been recorded (file existence is a platform check).
    public var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

/// Media tier selected for playback decode / render-cache identity (FR-MED-004).
///
/// Export always uses ``original`` regardless of the playback toggle (FR-EXP-007).
public enum MediaSourceTier: String, Codable, Hashable, Sendable {
    /// Full-resolution original media.
    case original

    /// Optimized proxy media under `caches/proxies/`.
    case proxy
}

/// Pure playback resolution decision for one media item (FR-MED-004).
public struct MediaProxyPlaybackDecision: Equatable, Sendable {
    /// Tier the render graph and decode path should use for this frame.
    public let tier: MediaSourceTier

    /// When true, the platform layer should re-enqueue proxy generation (missing file / stale).
    public let shouldReenqueueGeneration: Bool

    /// Creates a resolution decision.
    public init(tier: MediaSourceTier, shouldReenqueueGeneration: Bool) {
        self.tier = tier
        self.shouldReenqueueGeneration = shouldReenqueueGeneration
    }
}

/// Pure resolver: toggle × readiness × file-existence → playback tier (FR-MED-004).
public enum MediaProxyPlaybackResolver {
    /// Resolves the playback media tier for one media reference.
    ///
    /// Rules:
    /// - Toggle off → original (never re-enqueue from the toggle alone).
    /// - Toggle on + ready + file exists → proxy.
    /// - Toggle on + ready + file missing → original and re-enqueue generation.
    /// - Toggle on + not ready (none / generating / failed) → original; re-enqueue only when
    ///   state is `.none` or `.failed` so a single in-flight job is not duplicated.
    public static func resolve(
        preferProxy: Bool,
        proxyState: MediaProxyState,
        proxyFileExists: Bool
    ) -> MediaProxyPlaybackDecision {
        guard preferProxy else {
            return MediaProxyPlaybackDecision(tier: .original, shouldReenqueueGeneration: false)
        }

        switch proxyState {
        case .ready:
            if proxyFileExists {
                return MediaProxyPlaybackDecision(
                    tier: .proxy,
                    shouldReenqueueGeneration: false
                )
            }
            return MediaProxyPlaybackDecision(tier: .original, shouldReenqueueGeneration: true)
        case .none, .failed:
            return MediaProxyPlaybackDecision(tier: .original, shouldReenqueueGeneration: true)
        case .generating:
            return MediaProxyPlaybackDecision(tier: .original, shouldReenqueueGeneration: false)
        }
    }
}

/// Default proxy raster policy (FR-MED-004): half original resolution, minimum 640 px width.
public enum MediaProxyResolutionPolicy {
    /// Minimum encoded proxy width in pixels.
    public static let minimumWidth = 640

    /// Computes proxy dimensions for an original raster.
    ///
    /// Half-resolution with width floor at ``minimumWidth``. Height scales to preserve aspect
    /// ratio; both dimensions are clamped to at least 2 and forced even (ProRes-friendly).
    public static func proxyDimensions(for original: PixelDimensions) -> PixelDimensions {
        let halfWidth = max(minimumWidth, original.width / 2)
        let width = evenAtLeast(halfWidth, minimum: 2)
        let scaledHeight: Int
        if original.width <= 0 {
            scaledHeight = max(2, original.height / 2)
        } else {
            let height = (original.height * width + original.width / 2) / original.width
            scaledHeight = max(2, height)
        }
        return PixelDimensions(width: width, height: evenAtLeast(scaledHeight, minimum: 2))
    }

    private static func evenAtLeast(_ value: Int, minimum: Int) -> Int {
        let clamped = max(minimum, value)
        return clamped % 2 == 0 ? clamped : clamped + 1
    }
}
