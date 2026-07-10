// SPDX-License-Identifier: GPL-3.0-or-later

extension AnimatableClipEffectDefinition {
    // swiftlint:disable cyclomatic_complexity
    /// Evaluates the definition at a sequence time.
    public func value(at time: RationalTime) -> ClipEffectDefinition {
        switch self {
        case .placeholder(let parameters):
            .placeholder(parameters.value(at: time))
        case .gaussianBlur(let parameters):
            .gaussianBlur(parameters.value(at: time))
        case .boxBlur(let parameters):
            .boxBlur(parameters.value(at: time))
        case .zoomBlur(let parameters):
            .zoomBlur(parameters.value(at: time))
        case .sharpen(let parameters):
            .sharpen(parameters.value(at: time))
        case .glow(let parameters):
            .glow(parameters.value(at: time))
        case .lut(let parameters):
            .lut(parameters.value(at: time))
        case .vignette(let parameters):
            .vignette(parameters.value(at: time))
        case .mirror(let parameters):
            .mirror(parameters.value(at: time))
        case .mosaic(let parameters):
            .mosaic(parameters.value(at: time))
        case .colorAdjust(let parameters):
            .colorAdjust(parameters.value(at: time))
        case .posterize(let parameters):
            .posterize(parameters.value(at: time))
        case .invert(let parameters):
            .invert(parameters.value(at: time))
        case .curves(let parameters):
            .curves(parameters.value(at: time))
        }
    }
    // swiftlint:enable cyclomatic_complexity

    /// Static definition represented by base keyframe values.
    public var baseDefinition: ClipEffectDefinition {
        switch self {
        case .placeholder(let parameters):
            .placeholder(parameters.baseParameters)
        case .gaussianBlur(let parameters):
            .gaussianBlur(parameters.baseParameters)
        case .boxBlur(let parameters):
            .boxBlur(parameters.baseParameters)
        case .zoomBlur(let parameters):
            .zoomBlur(parameters.baseParameters)
        case .sharpen(let parameters):
            .sharpen(parameters.baseParameters)
        case .glow(let parameters):
            .glow(parameters.baseParameters)
        case .lut(let parameters):
            .lut(parameters.baseParameters)
        case .vignette(let parameters):
            .vignette(parameters.baseParameters)
        case .mirror(let parameters):
            .mirror(parameters.baseParameters)
        case .mosaic(let parameters):
            .mosaic(parameters.baseParameters)
        case .colorAdjust(let parameters):
            .colorAdjust(parameters.baseParameters)
        case .posterize(let parameters):
            .posterize(parameters.baseParameters)
        case .invert(let parameters):
            .invert(parameters.baseParameters)
        case .curves(let parameters):
            .curves(parameters.baseParameters)
        }
    }
}
