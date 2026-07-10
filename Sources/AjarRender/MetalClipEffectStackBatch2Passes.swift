// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Metal

extension MetalClipEffectStackEncoder {
    static func encodeVignette(
        amount: Float,
        radius: Float,
        softness: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        try encodeBatch2SinglePass(
            kind: .vignette,
            uniformBytes: MetalEffectUniformLayout.packVignette(
                amount: amount,
                radius: radius,
                softness: softness
            ),
            to: sourceTexture,
            context: context
        )
    }

    static func encodeMirror(
        axisMode: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        try encodeBatch2SinglePass(
            kind: .mirror,
            uniformBytes: MetalEffectUniformLayout.packMirror(axisMode: axisMode),
            to: sourceTexture,
            context: context
        )
    }

    static func encodeMosaic(
        cellSize: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        try encodeBatch2SinglePass(
            kind: .mosaic,
            uniformBytes: MetalEffectUniformLayout.packMosaic(cellSizePx: cellSize),
            to: sourceTexture,
            context: context
        )
    }

    static func encodeColorAdjust(
        controls: SIMD4<Float>,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        try encodeBatch2SinglePass(
            kind: .colorAdjust,
            uniformBytes: MetalEffectUniformLayout.packColorAdjust(
                brightness: controls.x,
                contrast: controls.y,
                saturation: controls.z,
                tint: controls.w
            ),
            to: sourceTexture,
            context: context
        )
    }

    static func encodePosterize(
        levels: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        try encodeBatch2SinglePass(
            kind: .posterize,
            uniformBytes: MetalEffectUniformLayout.packPosterize(levels: levels),
            to: sourceTexture,
            context: context
        )
    }

    static func encodeInvert(
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        try encodeBatch2SinglePass(
            kind: .invert,
            uniformBytes: MetalEffectUniformLayout.packInvert(),
            to: sourceTexture,
            context: context
        )
    }

    private static func encodeBatch2SinglePass(
        kind: ClipEffectKind,
        uniformBytes: [UInt8],
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let output = try context.makeTexture(
            sourceTexture.pixelFormat,
            sourceTexture.width,
            sourceTexture.height
        )
        let pipeline = try context.registry.pipelineState(
            fragmentFunctionName: try context.registry.fragmentFunctionName(for: kind),
            pixelFormat: output.pixelFormat
        )
        try encodeFullscreen(
            pipeline: pipeline,
            destination: output,
            textures: [sourceTexture],
            uniformBytes: uniformBytes,
            context: context
        )
        return (output, [output])
    }
}
