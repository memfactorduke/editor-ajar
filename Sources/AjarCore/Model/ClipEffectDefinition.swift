// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// Imported `.cube` LUT with adjustable strength (FR-COL-004).
    case lut(ClipLUTEffectParameters)

    /// Radial edge darkening (FR-FX-002).
    case vignette(ClipVignetteParameters)

    /// Horizontal, vertical, or four-quadrant reflection (FR-FX-002).
    case mirror(ClipMirrorParameters)

    /// Mosaic / pixelation (FR-FX-002).
    case mosaic(ClipMosaicParameters)

    /// Basic brightness, contrast, saturation, and tint adjustment (FR-FX-002).
    case colorAdjust(ClipColorAdjustParameters)

    /// Discrete color-level posterization (FR-FX-002).
    case posterize(ClipPosterizeParameters)

    /// RGB inversion (FR-FX-002).
    case invert(ClipInvertParameters)

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
        }
    }

    /// Default definition for `kind` (a no-op where that kind has an identity control).
    public static func identity(  // swiftlint:disable:this cyclomatic_complexity
        for kind: ClipEffectKind
    ) -> ClipEffectDefinition {
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
            .lut(ClipLUTEffectParameters(table: .identityOneD, strength: .zero))
        case .vignette:
            .vignette(.identity)
        case .mirror:
            .mirror(.identity)
        case .mosaic:
            .mosaic(.identity)
        case .colorAdjust:
            .colorAdjust(.identity)
        case .posterize:
            .posterize(.identity)
        case .invert:
            .invert(.identity)
        }
    }

    /// LUT identity: same table and placement, zero strength.
    public static func lutIdentity(
        table: CubeLUTTable,
        placement: ClipLUTPlacement = .look
    ) -> ClipEffectDefinition {
        .lut(ClipLUTEffectParameters(table: table, strength: .zero, placement: placement))
    }
}
