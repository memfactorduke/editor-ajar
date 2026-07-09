// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed effect definition: kind identity plus that kind's parameter struct (ADR-0016).
public enum ClipEffectDefinition: Codable, Equatable, Sendable {
    /// Placeholder bootstrap kind.
    case placeholder(ClipPlaceholderEffectParameters)

    /// Separable Gaussian blur (FR-FX-002).
    case gaussianBlur(ClipGaussianBlurParameters)

    /// Separable box blur (FR-FX-002).
    case boxBlur(ClipBoxBlurParameters)

    /// Zoom / radial blur (FR-FX-002).
    case zoomBlur(ClipZoomBlurParameters)

    /// Unsharp-mask sharpen (FR-FX-002).
    case sharpen(ClipSharpenParameters)

    /// Soft glow (FR-FX-002).
    case glow(ClipGlowParameters)

    private enum CodingKeys: String, CodingKey {
        case kind
        case parameters
    }

    /// Kind identity for registry and diagnostics.
    public var kind: ClipEffectKind {
        switch self {
        case .placeholder:
            return .placeholder
        case .gaussianBlur:
            return .gaussianBlur
        case .boxBlur:
            return .boxBlur
        case .zoomBlur:
            return .zoomBlur
        case .sharpen:
            return .sharpen
        case .glow:
            return .glow
        }
    }

    /// Identity definition for `kind`.
    public static func identity(for kind: ClipEffectKind) -> ClipEffectDefinition {
        switch kind {
        case .placeholder:
            return .placeholder(.identity)
        case .gaussianBlur:
            return .gaussianBlur(.identity)
        case .boxBlur:
            return .boxBlur(.identity)
        case .zoomBlur:
            return .zoomBlur(.identity)
        case .sharpen:
            return .sharpen(.identity)
        case .glow:
            return .glow(.identity)
        }
    }

    /// Decodes a kind-tagged parameter payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ClipEffectKind.self, forKey: .kind)
        switch kind {
        case .placeholder:
            let parameters =
                try container.decodeIfPresent(
                    ClipPlaceholderEffectParameters.self,
                    forKey: .parameters
                ) ?? .identity
            self = .placeholder(parameters)
        case .gaussianBlur:
            let parameters =
                try container.decodeIfPresent(
                    ClipGaussianBlurParameters.self,
                    forKey: .parameters
                ) ?? .identity
            self = .gaussianBlur(parameters)
        case .boxBlur:
            let parameters =
                try container.decodeIfPresent(
                    ClipBoxBlurParameters.self,
                    forKey: .parameters
                ) ?? .identity
            self = .boxBlur(parameters)
        case .zoomBlur:
            let parameters =
                try container.decodeIfPresent(
                    ClipZoomBlurParameters.self,
                    forKey: .parameters
                ) ?? .identity
            self = .zoomBlur(parameters)
        case .sharpen:
            let parameters =
                try container.decodeIfPresent(
                    ClipSharpenParameters.self,
                    forKey: .parameters
                ) ?? .identity
            self = .sharpen(parameters)
        case .glow:
            let parameters =
                try container.decodeIfPresent(
                    ClipGlowParameters.self,
                    forKey: .parameters
                ) ?? .identity
            self = .glow(parameters)
        }
    }

    /// Encodes kind + parameters.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .placeholder(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .gaussianBlur(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .boxBlur(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .zoomBlur(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .sharpen(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .glow(let parameters):
            try container.encode(parameters, forKey: .parameters)
        }
    }
}

/// Keyframable effect definition.
public enum AnimatableClipEffectDefinition: Codable, Equatable, Sendable {
    /// Keyframable placeholder bootstrap kind.
    case placeholder(AnimatableClipPlaceholderSettings)

    /// Keyframable Gaussian blur (FR-FX-002).
    case gaussianBlur(AnimatableClipGaussianBlurSettings)

    /// Keyframable box blur (FR-FX-002).
    case boxBlur(AnimatableClipBoxBlurSettings)

    /// Keyframable zoom blur (FR-FX-002).
    case zoomBlur(AnimatableClipZoomBlurSettings)

    /// Keyframable sharpen (FR-FX-002).
    case sharpen(AnimatableClipSharpenSettings)

    /// Keyframable glow (FR-FX-002).
    case glow(AnimatableClipGlowSettings)

    private enum CodingKeys: String, CodingKey {
        case kind
        case parameters
    }

    /// Kind identity for registry and diagnostics.
    public var kind: ClipEffectKind {
        switch self {
        case .placeholder:
            return .placeholder
        case .gaussianBlur:
            return .gaussianBlur
        case .boxBlur:
            return .boxBlur
        case .zoomBlur:
            return .zoomBlur
        case .sharpen:
            return .sharpen
        case .glow:
            return .glow
        }
    }

    /// Identity definition for `kind`.
    public static func identity(for kind: ClipEffectKind) -> AnimatableClipEffectDefinition {
        switch kind {
        case .placeholder:
            return .placeholder(.identity)
        case .gaussianBlur:
            return .gaussianBlur(.identity)
        case .boxBlur:
            return .boxBlur(.identity)
        case .zoomBlur:
            return .zoomBlur(.identity)
        case .sharpen:
            return .sharpen(.identity)
        case .glow:
            return .glow(.identity)
        }
    }

    /// Creates a constant animatable definition from static parameters.
    public static func constant(
        _ definition: ClipEffectDefinition
    ) -> AnimatableClipEffectDefinition {
        switch definition {
        case .placeholder(let parameters):
            return .placeholder(.constant(parameters))
        case .gaussianBlur(let parameters):
            return .gaussianBlur(.constant(parameters))
        case .boxBlur(let parameters):
            return .boxBlur(.constant(parameters))
        case .zoomBlur(let parameters):
            return .zoomBlur(.constant(parameters))
        case .sharpen(let parameters):
            return .sharpen(.constant(parameters))
        case .glow(let parameters):
            return .glow(.constant(parameters))
        }
    }

    /// Decodes a kind-tagged keyframable parameter payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ClipEffectKind.self, forKey: .kind)
        switch kind {
        case .placeholder:
            let parameters =
                try container.decodeIfPresent(
                    AnimatableClipPlaceholderSettings.self,
                    forKey: .parameters
                ) ?? .identity
            self = .placeholder(parameters)
        case .gaussianBlur:
            let parameters =
                try container.decodeIfPresent(
                    AnimatableClipGaussianBlurSettings.self,
                    forKey: .parameters
                ) ?? .identity
            self = .gaussianBlur(parameters)
        case .boxBlur:
            let parameters =
                try container.decodeIfPresent(
                    AnimatableClipBoxBlurSettings.self,
                    forKey: .parameters
                ) ?? .identity
            self = .boxBlur(parameters)
        case .zoomBlur:
            let parameters =
                try container.decodeIfPresent(
                    AnimatableClipZoomBlurSettings.self,
                    forKey: .parameters
                ) ?? .identity
            self = .zoomBlur(parameters)
        case .sharpen:
            let parameters =
                try container.decodeIfPresent(
                    AnimatableClipSharpenSettings.self,
                    forKey: .parameters
                ) ?? .identity
            self = .sharpen(parameters)
        case .glow:
            let parameters =
                try container.decodeIfPresent(
                    AnimatableClipGlowSettings.self,
                    forKey: .parameters
                ) ?? .identity
            self = .glow(parameters)
        }
    }

    /// Encodes kind + parameters.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .placeholder(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .gaussianBlur(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .boxBlur(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .zoomBlur(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .sharpen(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .glow(let parameters):
            try container.encode(parameters, forKey: .parameters)
        }
    }

    /// Evaluates the definition at a sequence time.
    public func value(at time: RationalTime) -> ClipEffectDefinition {
        switch self {
        case .placeholder(let parameters):
            return .placeholder(parameters.value(at: time))
        case .gaussianBlur(let parameters):
            return .gaussianBlur(parameters.value(at: time))
        case .boxBlur(let parameters):
            return .boxBlur(parameters.value(at: time))
        case .zoomBlur(let parameters):
            return .zoomBlur(parameters.value(at: time))
        case .sharpen(let parameters):
            return .sharpen(parameters.value(at: time))
        case .glow(let parameters):
            return .glow(parameters.value(at: time))
        }
    }

    /// Static definition represented by base keyframe values.
    public var baseDefinition: ClipEffectDefinition {
        switch self {
        case .placeholder(let parameters):
            return .placeholder(parameters.baseParameters)
        case .gaussianBlur(let parameters):
            return .gaussianBlur(parameters.baseParameters)
        case .boxBlur(let parameters):
            return .boxBlur(parameters.baseParameters)
        case .zoomBlur(let parameters):
            return .zoomBlur(parameters.baseParameters)
        case .sharpen(let parameters):
            return .sharpen(parameters.baseParameters)
        case .glow(let parameters):
            return .glow(parameters.baseParameters)
        }
    }
}
