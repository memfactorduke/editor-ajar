// SPDX-License-Identifier: GPL-3.0-or-later

extension ClipEffectDefinition {
    /// Decodes a kind-tagged parameter payload, defaulting a missing payload by kind.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ClipEffectKind.self, forKey: .kind)
        switch kind {
        case .placeholder:
            self = .placeholder(
                try container.decodeIfPresent(
                    ClipPlaceholderEffectParameters.self,
                    forKey: .parameters
                ) ?? .identity
            )
        case .gaussianBlur:
            self = .gaussianBlur(
                try container.decodeIfPresent(
                    ClipGaussianBlurParameters.self,
                    forKey: .parameters
                ) ?? .identity
            )
        case .boxBlur:
            self = .boxBlur(
                try container.decodeIfPresent(ClipBoxBlurParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .zoomBlur:
            self = .zoomBlur(
                try container.decodeIfPresent(ClipZoomBlurParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .sharpen:
            self = .sharpen(
                try container.decodeIfPresent(ClipSharpenParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .glow:
            self = .glow(
                try container.decodeIfPresent(ClipGlowParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .lut:
            let parameters = try container.decode(ClipLUTEffectParameters.self, forKey: .parameters)
            self = .lut(parameters)
        case .curves:
            self = .curves(
                try container.decodeIfPresent(
                    ClipCurvesEffectParameters.self,
                    forKey: .parameters
                ) ?? .identity
            )
        case .vignette, .mirror, .mosaic, .colorAdjust, .posterize, .invert:
            self = try Self.decodeBatch2(kind: kind, from: container)
        }
    }

    private static func decodeBatch2(
        kind: ClipEffectKind,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ClipEffectDefinition {
        switch kind {
        case .vignette:
            return .vignette(
                try container.decodeIfPresent(ClipVignetteParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .mirror:
            return .mirror(
                try container.decodeIfPresent(ClipMirrorParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .mosaic:
            return .mosaic(
                try container.decodeIfPresent(ClipMosaicParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .colorAdjust:
            return .colorAdjust(
                try container.decodeIfPresent(ClipColorAdjustParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .posterize:
            return .posterize(
                try container.decodeIfPresent(ClipPosterizeParameters.self, forKey: .parameters)
                    ?? .identity
            )
        case .invert:
            return .invert(
                try container.decodeIfPresent(ClipInvertParameters.self, forKey: .parameters)
                    ?? .identity
            )
        default:
            return .identity(for: kind)
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// Encodes kind + typed parameters.
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
        case .lut(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .vignette(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .mirror(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .mosaic(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .colorAdjust(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .posterize(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .invert(let parameters):
            try container.encode(parameters, forKey: .parameters)
        case .curves(let parameters):
            try container.encode(parameters, forKey: .parameters)
        }
    }
    // swiftlint:enable cyclomatic_complexity
}
