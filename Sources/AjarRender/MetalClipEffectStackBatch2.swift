// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Metal

extension MetalClipEffectStackEncoder {
    static func applyVignette(
        _ parameters: ClipVignetteParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let amount = batch2Clamp01(Float(parameters.amount.doubleValue))
        guard amount > 0.001 else {
            return (sourceTexture, [])
        }
        return try encodeVignette(
            amount: amount,
            radius: batch2Clamp01(Float(parameters.radius.doubleValue)),
            softness: batch2Clamp01(Float(parameters.softness.doubleValue)),
            to: sourceTexture,
            context: context
        )
    }

    static func applyMirror(
        _ parameters: ClipMirrorParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        try encodeMirror(
            axisMode: parameters.axis.metalAxisMode,
            to: sourceTexture,
            context: context
        )
    }

    static func applyMosaic(
        _ parameters: ClipMosaicParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let cellSize = batch2Clamp(
            Float(parameters.cellSize.doubleValue),
            minimum: 1,
            maximum: Float(ClipEffectLibraryLimits.maximumMosaicCellSize.doubleValue)
        )
        guard cellSize > 1.001 else {
            return (sourceTexture, [])
        }
        return try encodeMosaic(cellSize: cellSize, to: sourceTexture, context: context)
    }

    static func applyColorAdjust(
        _ parameters: ClipColorAdjustParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let brightness = batch2Clamp(
            Float(parameters.brightness.doubleValue),
            minimum: -1,
            maximum: 1
        )
        let maximum = Float(ClipEffectLibraryLimits.maximumColorAdjustMultiplier.doubleValue)
        let contrast = batch2Clamp(
            Float(parameters.contrast.doubleValue),
            minimum: 0,
            maximum: maximum
        )
        let saturation = batch2Clamp(
            Float(parameters.saturation.doubleValue),
            minimum: 0,
            maximum: maximum
        )
        let tint = batch2Clamp(Float(parameters.tint.doubleValue), minimum: -1, maximum: 1)
        let isIdentity = abs(brightness) < 0.001 && abs(contrast - 1) < 0.001
            && abs(saturation - 1) < 0.001 && abs(tint) < 0.001
        guard !isIdentity else {
            return (sourceTexture, [])
        }
        return try encodeColorAdjust(
            controls: SIMD4<Float>(brightness, contrast, saturation, tint),
            to: sourceTexture,
            context: context
        )
    }

    static func applyPosterize(
        _ parameters: ClipPosterizeParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let levels = batch2Clamp(
            round(Float(parameters.levels.doubleValue)),
            minimum: 2,
            maximum: Float(ClipEffectLibraryLimits.maximumPosterizeLevels.doubleValue)
        )
        guard levels < 255.5 else {
            return (sourceTexture, [])
        }
        return try encodePosterize(levels: levels, to: sourceTexture, context: context)
    }

    static func applyInvert(
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        try encodeInvert(to: sourceTexture, context: context)
    }

    private static func batch2Clamp01(_ value: Float) -> Float {
        batch2Clamp(value, minimum: 0, maximum: 1)
    }

    private static func batch2Clamp(_ value: Float, minimum: Float, maximum: Float) -> Float {
        min(max(value, minimum), maximum)
    }
}

extension ClipMirrorAxis {
    fileprivate var metalAxisMode: Float {
        switch self {
        case .horizontal:
            0
        case .vertical:
            1
        case .quad:
            2
        }
    }
}
