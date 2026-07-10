// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import simd

extension MetalClipEffectStackEncoder {
    static func applySeparableBlur(
        fragmentFunctionName: String,
        radius: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let width = sourceTexture.width
        let height = sourceTexture.height
        let format = sourceTexture.pixelFormat
        let intermediate = try context.makeTexture(format, width, height)
        let output = try context.makeTexture(format, width, height)
        let texelSize = SIMD2<Float>(1.0 / Float(width), 1.0 / Float(height))

        try encodeSeparablePass(
            fragmentFunctionName: fragmentFunctionName,
            source: sourceTexture,
            destination: intermediate,
            uniformBytes: MetalEffectUniformLayout.packSeparableBlur(
                texelSize: texelSize,
                direction: SIMD2<Float>(1, 0),
                radius: radius
            ),
            context: context
        )
        try encodeSeparablePass(
            fragmentFunctionName: fragmentFunctionName,
            source: intermediate,
            destination: output,
            uniformBytes: MetalEffectUniformLayout.packSeparableBlur(
                texelSize: texelSize,
                direction: SIMD2<Float>(0, 1),
                radius: radius
            ),
            context: context
        )
        return (output, [intermediate, output])
    }

    static func encodeSeparablePass(
        fragmentFunctionName: String,
        source: MTLTexture,
        destination: MTLTexture,
        uniformBytes: [UInt8],
        context: MetalEffectEncodeContext
    ) throws {
        let pipeline = try context.registry.pipelineState(
            fragmentFunctionName: fragmentFunctionName,
            pixelFormat: destination.pixelFormat
        )
        try encodeFullscreen(
            pipeline: pipeline,
            destination: destination,
            textures: [source],
            uniformBytes: uniformBytes,
            context: context
        )
    }

    static func encodeZoomBlur(
        amount: Float,
        centerX: Float,
        centerY: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let output = try context.makeTexture(
            sourceTexture.pixelFormat,
            sourceTexture.width,
            sourceTexture.height
        )
        let pipeline = try context.registry.pipelineState(
            fragmentFunctionName: try context.registry.fragmentFunctionName(for: .zoomBlur),
            pixelFormat: output.pixelFormat
        )
        try encodeFullscreen(
            pipeline: pipeline,
            destination: output,
            textures: [sourceTexture],
            uniformBytes: MetalEffectUniformLayout.packZoomBlur(
                centerX: centerX,
                centerY: centerY,
                amount: amount
            ),
            context: context
        )
        return (output, [output])
    }

    static func encodeSharpen(
        amount: Float,
        radius: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let output = try context.makeTexture(
            sourceTexture.pixelFormat,
            sourceTexture.width,
            sourceTexture.height
        )
        let pipeline = try context.registry.pipelineState(
            fragmentFunctionName: try context.registry.fragmentFunctionName(for: .sharpen),
            pixelFormat: output.pixelFormat
        )
        try encodeFullscreen(
            pipeline: pipeline,
            destination: output,
            textures: [sourceTexture],
            uniformBytes: MetalEffectUniformLayout.packSharpen(
                amount: amount,
                radiusPx: radius
            ),
            context: context
        )
        return (output, [output])
    }

    static func encodeGlow(
        amount: Float,
        radius: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let blurred = try applySeparableBlur(
            fragmentFunctionName: try context.registry.fragmentFunctionName(for: .gaussianBlur),
            radius: radius,
            to: sourceTexture,
            context: context
        )
        let output = try context.makeTexture(
            sourceTexture.pixelFormat,
            sourceTexture.width,
            sourceTexture.height
        )
        let pipeline = try context.registry.pipelineState(
            fragmentFunctionName: try context.registry.fragmentFunctionName(for: .glow),
            pixelFormat: output.pixelFormat
        )
        try encodeFullscreen(
            pipeline: pipeline,
            destination: output,
            textures: [sourceTexture, blurred.texture],
            uniformBytes: MetalEffectUniformLayout.packGlowCombine(amount: amount),
            context: context
        )
        return (output, blurred.intermediates + [output])
    }

    /// FR-COL-002: apply color curves via registry fragment + digest-cached ramp texture.
    static func encodeCurves(
        parameters: ClipCurvesEffectParameters,
        strength: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let output = try context.makeTexture(
            sourceTexture.pixelFormat,
            sourceTexture.width,
            sourceTexture.height
        )
        let fragmentName = try context.registry.fragmentFunctionName(for: .curves)
        let pipeline = try context.registry.pipelineState(
            fragmentFunctionName: fragmentName,
            pixelFormat: output.pixelFormat
        )
        let rampTexture = try context.registry.curvesRampTexture(for: parameters)
        try encodeFullscreen(
            pipeline: pipeline,
            destination: output,
            textures: [sourceTexture, rampTexture],
            uniformBytes: MetalEffectUniformLayout.packCurves(
                strength: strength,
                rampSize: Float(ColorCurveLimits.rampSampleCount)
            ),
            context: context
        )
        return (output, [output])
    }

    /// FR-COL-004: apply one LUT node via registry fragment + digest-cached LUT texture.
    static func encodeLUT(
        table: CubeLUTTable,
        strength: Float,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let output = try context.makeTexture(
            sourceTexture.pixelFormat,
            sourceTexture.width,
            sourceTexture.height
        )
        let fragmentName = context.registry.fragmentFunctionName(forLUT: table.dimensions)
        let pipeline = try context.registry.pipelineState(
            fragmentFunctionName: fragmentName,
            pixelFormat: output.pixelFormat
        )
        let lutTexture = try context.registry.lutTexture(for: table)
        try encodeFullscreen(
            pipeline: pipeline,
            destination: output,
            textures: [sourceTexture, lutTexture],
            uniformBytes: MetalEffectUniformLayout.packLUT(
                strength: strength,
                size: Float(table.size),
                domainMin: SIMD3<Float>(table.domainMin.r, table.domainMin.g, table.domainMin.b),
                domainMax: SIMD3<Float>(table.domainMax.r, table.domainMax.g, table.domainMax.b)
            ),
            context: context
        )
        return (output, [output])
    }

    /// Fullscreen triangle with fragment textures + layout-packed uniform bytes at buffer(0).
    static func encodeFullscreen(
        pipeline: MTLRenderPipelineState,
        destination: MTLTexture,
        textures: [MTLTexture],
        uniformBytes: [UInt8],
        context: MetalEffectEncodeContext
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = context.commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            throw MetalRenderError.renderEncoderCreationFailed
        }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        try setFragmentUniformBytes(uniformBytes, on: encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private static func setFragmentUniformBytes(
        _ bytes: [UInt8],
        on encoder: MTLRenderCommandEncoder
    ) throws {
        guard !bytes.isEmpty else {
            throw MetalRenderError.pipelineCreationFailed("effect uniform pack is empty")
        }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw MetalRenderError.pipelineCreationFailed(
                    "effect uniform pack base address unavailable"
                )
            }
            encoder.setFragmentBytes(base, length: raw.count, index: 0)
        }
    }
}
