// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// Keyframable LUT kind (table constant, strength keyframable).
    case lut(AnimatableClipLUTSettings)

    /// Keyframable vignette (FR-FX-002).
    case vignette(AnimatableClipVignetteSettings)

    /// Constant-axis mirror (FR-FX-002).
    case mirror(AnimatableClipMirrorSettings)

    /// Keyframable mosaic / pixelation (FR-FX-002).
    case mosaic(AnimatableClipMosaicSettings)

    /// Keyframable basic color adjustment (FR-FX-002).
    case colorAdjust(AnimatableClipColorAdjustSettings)

    /// Keyframable posterization (FR-FX-002).
    case posterize(AnimatableClipPosterizeSettings)

    /// Parameterless RGB inversion (FR-FX-002).
    case invert(AnimatableClipInvertSettings)

    /// Keyframable color curves (curves constant; strength keyframable) (FR-COL-002).
    case curves(AnimatableClipCurvesSettings)

    enum CodingKeys: String, CodingKey {
        case kind
        case parameters
    }

    /// Kind identity for registry and diagnostics.
    public var kind: ClipEffectKind {
        switch self {
        case .placeholder:
            .placeholder
        case .gaussianBlur:
            .gaussianBlur
        case .boxBlur:
            .boxBlur
        case .zoomBlur:
            .zoomBlur
        case .sharpen:
            .sharpen
        case .glow:
            .glow
        case .lut:
            .lut
        case .vignette:
            .vignette
        case .mirror:
            .mirror
        case .mosaic:
            .mosaic
        case .colorAdjust:
            .colorAdjust
        case .posterize:
            .posterize
        case .invert:
            .invert
        case .curves:
            .curves
        }
    }

    /// Default definition for `kind`.
    public static func identity(  // swiftlint:disable:this cyclomatic_complexity
        for kind: ClipEffectKind
    ) -> AnimatableClipEffectDefinition {
        switch kind {
        case .placeholder:
            .placeholder(.identity)
        case .gaussianBlur:
            .gaussianBlur(.identity)
        case .boxBlur:
            .boxBlur(.identity)
        case .zoomBlur:
            .zoomBlur(.identity)
        case .sharpen:
            .sharpen(.identity)
        case .glow:
            .glow(.identity)
        case .lut:
            .constant(ClipEffectDefinition.identity(for: .lut))
        case .vignette:
            .vignette(.identity)
        case .mirror:
            .mirror(.identity)
        case .colorAdjust:
            .colorAdjust(.identity)
        case .mosaic:
            .mosaic(.identity)
        case .posterize:
            .posterize(.identity)
        case .invert:
            .invert(.identity)
        case .curves:
            .constant(ClipEffectDefinition.identity(for: .curves))
        }
    }

    /// Creates a constant animatable definition from static parameters.
    public static func constant(  // swiftlint:disable:this cyclomatic_complexity
        _ definition: ClipEffectDefinition
    ) -> AnimatableClipEffectDefinition {
        switch definition {
        case .placeholder(let parameters):
            .placeholder(.constant(parameters))
        case .gaussianBlur(let parameters):
            .gaussianBlur(.constant(parameters))
        case .boxBlur(let parameters):
            .boxBlur(.constant(parameters))
        case .zoomBlur(let parameters):
            .zoomBlur(.constant(parameters))
        case .sharpen(let parameters):
            .sharpen(.constant(parameters))
        case .glow(let parameters):
            .glow(.constant(parameters))
        case .lut(let parameters):
            .lut(.constant(parameters))
        case .vignette(let parameters):
            .vignette(.constant(parameters))
        case .mirror(let parameters):
            .mirror(.constant(parameters))
        case .mosaic(let parameters):
            .mosaic(.constant(parameters))
        case .colorAdjust(let parameters):
            .colorAdjust(.constant(parameters))
        case .posterize(let parameters):
            .posterize(.constant(parameters))
        case .invert(let parameters):
            .invert(.constant(parameters))
        case .curves(let parameters):
            .curves(.constant(parameters))
        }
    }
}
