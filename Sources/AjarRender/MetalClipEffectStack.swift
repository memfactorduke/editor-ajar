// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import simd

/// ADR-0016 kind → Metal pipeline registry for FR-FX-002 library effect nodes.
///
/// Missing or failed pipelines surface as typed `MetalRenderError` values — never traps.
final class MetalClipEffectStackRegistry {
    private let device: MTLDevice
    private let library: MTLLibrary
    private var pipelineStates: [String: MTLRenderPipelineState] = [:]
    private let lock = NSLock()

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    /// Returns the render pipeline for `fragmentFunctionName` writing `pixelFormat`.
    func pipelineState(
        fragmentFunctionName: String,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let key = "\(fragmentFunctionName)|\(pixelFormat.rawValue)"
        lock.lock()
        if let existing = pipelineStates[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let built = try makePipelineState(
            fragmentFunctionName: fragmentFunctionName,
            pixelFormat: pixelFormat,
            withReflection: false
        )
        lock.lock()
        pipelineStates[key] = built.pipeline
        lock.unlock()
        return built.pipeline
    }

    /// Builds a pipeline with `MTLPipelineOption.argumentInfo` reflection (tests).
    func pipelineStateWithReflection(
        fragmentFunctionName: String,
        pixelFormat: MTLPixelFormat
    ) throws -> (pipeline: MTLRenderPipelineState, reflection: MTLRenderPipelineReflection) {
        let built = try makePipelineState(
            fragmentFunctionName: fragmentFunctionName,
            pixelFormat: pixelFormat,
            withReflection: true
        )
        guard let reflection = built.reflection else {
            throw MetalRenderError.pipelineCreationFailed(
                "missing MTLRenderPipelineReflection for \(fragmentFunctionName)"
            )
        }
        return (built.pipeline, reflection)
    }

    private func makePipelineState(
        fragmentFunctionName: String,
        pixelFormat: MTLPixelFormat,
        withReflection: Bool
    ) throws -> (pipeline: MTLRenderPipelineState, reflection: MTLRenderPipelineReflection?) {
        guard let vertexFunction = library.makeFunction(name: "ajar_fullscreen_vertex") else {
            throw MetalRenderError.shaderFunctionUnavailable("ajar_fullscreen_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: fragmentFunctionName) else {
            throw MetalRenderError.shaderFunctionUnavailable(fragmentFunctionName)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        do {
            if withReflection {
                var reflection: MTLAutoreleasedRenderPipelineReflection?
                // macos-14 / Xcode 15 SDK: use `.argumentInfo` (not the later `.bindingInfo`
                // rename) and read `fragmentArguments` (not `fragmentBindings`).
                let pipeline = try device.makeRenderPipelineState(
                    descriptor: descriptor,
                    options: [.argumentInfo, .bufferTypeInfo],
                    reflection: &reflection
                )
                return (pipeline, reflection)
            }
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            return (pipeline, nil)
        } catch {
            throw MetalRenderError.pipelineCreationFailed(String(describing: error))
        }
    }

    /// Human-readable fragment-stage argument list for failure messages.
    static func describeFragmentArguments(
        _ reflection: MTLRenderPipelineReflection
    ) -> String {
        let arguments = reflection.fragmentArguments ?? []
        if arguments.isEmpty {
            return "(no fragment arguments reflected)"
        }
        return arguments.map { argument in
            let index = argument.index
            let name = argument.name
            let type = String(describing: argument.type)
            let access = String(describing: argument.access)
            return "index=\(index) name=\(name) type=\(type) access=\(access)"
        }.joined(separator: "\n")
    }

    /// Whether the fragment stage reflects a texture and a buffer both at index 0.
    static func fragmentBindsTexture0AndBuffer0(
        _ reflection: MTLRenderPipelineReflection
    ) -> (hasTexture0: Bool, hasBuffer0: Bool) {
        let arguments = reflection.fragmentArguments ?? []
        let hasTexture0 = arguments.contains { argument in
            argument.type == .texture && argument.index == 0
        }
        let hasBuffer0 = arguments.contains { argument in
            argument.type == .buffer && argument.index == 0
        }
        return (hasTexture0, hasBuffer0)
    }

    /// Primary fragment function for a built-in kind (registry entry; ADR-0016 §3).
    func fragmentFunctionName(for kind: ClipEffectKind) throws -> String {
        switch kind {
        case .placeholder:
            return "ajar_effect_passthrough_fragment"
        case .gaussianBlur:
            return "ajar_gaussian_blur_fragment"
        case .boxBlur:
            return "ajar_box_blur_fragment"
        case .zoomBlur:
            return "ajar_zoom_blur_fragment"
        case .sharpen:
            return "ajar_sharpen_fragment"
        case .glow:
            return "ajar_glow_combine_fragment"
        }
    }
}

/// Shared encode context for FR-FX-002 GPU stack application.
struct MetalEffectEncodeContext {
    let registry: MetalClipEffectStackRegistry
    let makeTexture: @Sendable (MTLPixelFormat, Int, Int) throws -> MTLTexture
    let commandBuffer: MTLCommandBuffer
}

/// GPU application of an ordered `ClipEffectStack` (FR-FX-002/003/007).
///
/// Fragment uniforms are packed via `MetalEffectUniformLayout` (same field order as the
/// generated MSL structs in `MetalClipEffectStackShaders`).
enum MetalClipEffectStackEncoder {
    /// Applies enabled stack nodes in order. Returns the input texture when the stack is empty
    /// or every node is a no-op. Intermediate textures stay GPU-private (no CPU readback).
    static func apply(
        stack: ClipEffectStack,
        to sourceTexture: MTLTexture,
        registry: MetalClipEffectStackRegistry,
        makeTexture: @escaping @Sendable (MTLPixelFormat, Int, Int) throws -> MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let activeNodes = stack.nodes.filter(\.enabled)
        guard !activeNodes.isEmpty else {
            return (sourceTexture, [])
        }

        let context = MetalEffectEncodeContext(
            registry: registry,
            makeTexture: makeTexture,
            commandBuffer: commandBuffer
        )
        var current = sourceTexture
        var intermediates: [MTLTexture] = []
        for node in activeNodes {
            let result = try apply(definition: node.definition, to: current, context: context)
            current = result.texture
            intermediates.append(contentsOf: result.intermediates)
        }
        return (current, intermediates)
    }

    private static func apply(
        definition: ClipEffectDefinition,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        switch definition {
        case .placeholder:
            return (sourceTexture, [])
        case .gaussianBlur(let parameters):
            return try applyGaussian(parameters, to: sourceTexture, context: context)
        case .boxBlur(let parameters):
            return try applyBox(parameters, to: sourceTexture, context: context)
        case .zoomBlur(let parameters):
            return try applyZoom(parameters, to: sourceTexture, context: context)
        case .sharpen(let parameters):
            return try applySharpen(parameters, to: sourceTexture, context: context)
        case .glow(let parameters):
            return try applyGlow(parameters, to: sourceTexture, context: context)
        }
    }

    private static func applyGaussian(
        _ parameters: ClipGaussianBlurParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        // Evaluation-time clamp (Bezier overshoot) — same convention as composite uniforms.
        let radius = clamp(
            Float(parameters.radius.doubleValue),
            minimum: 0,
            maximum: Float(ClipEffectLibraryLimits.maximumBlurRadius.doubleValue)
        )
        guard radius > 0.001 else {
            return (sourceTexture, [])
        }
        return try applySeparableBlur(
            fragmentFunctionName: try context.registry.fragmentFunctionName(for: .gaussianBlur),
            radius: radius,
            to: sourceTexture,
            context: context
        )
    }

    private static func applyBox(
        _ parameters: ClipBoxBlurParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let radius = clamp(
            Float(parameters.radius.doubleValue),
            minimum: 0,
            maximum: Float(ClipEffectLibraryLimits.maximumBoxBlurRadius.doubleValue)
        )
        guard radius > 0.001 else {
            return (sourceTexture, [])
        }
        return try applySeparableBlur(
            fragmentFunctionName: try context.registry.fragmentFunctionName(for: .boxBlur),
            radius: radius,
            to: sourceTexture,
            context: context
        )
    }

    private static func applyZoom(
        _ parameters: ClipZoomBlurParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let amount = clamp01(Float(parameters.amount.doubleValue))
        guard amount > 0.001 else {
            return (sourceTexture, [])
        }
        return try encodeZoomBlur(
            amount: amount,
            centerX: clamp01(Float(parameters.centerX.doubleValue)),
            centerY: clamp01(Float(parameters.centerY.doubleValue)),
            to: sourceTexture,
            context: context
        )
    }

    private static func applySharpen(
        _ parameters: ClipSharpenParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let amount = clamp01(Float(parameters.amount.doubleValue))
        guard amount > 0.001 else {
            return (sourceTexture, [])
        }
        return try encodeSharpen(
            amount: amount,
            radius: clamp(
                Float(parameters.radius.doubleValue),
                minimum: 0,
                maximum: Float(ClipEffectLibraryLimits.maximumSharpenRadius.doubleValue)
            ),
            to: sourceTexture,
            context: context
        )
    }

    private static func applyGlow(
        _ parameters: ClipGlowParameters,
        to sourceTexture: MTLTexture,
        context: MetalEffectEncodeContext
    ) throws -> (texture: MTLTexture, intermediates: [MTLTexture]) {
        let amount = clamp01(Float(parameters.amount.doubleValue))
        guard amount > 0.001 else {
            return (sourceTexture, [])
        }
        let radius = clamp(
            Float(parameters.radius.doubleValue),
            minimum: 0,
            maximum: Float(ClipEffectLibraryLimits.maximumBlurRadius.doubleValue)
        )
        return try encodeGlow(
            amount: amount,
            radius: max(radius, 0.5),
            to: sourceTexture,
            context: context
        )
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func clamp(_ value: Float, minimum: Float, maximum: Float) -> Float {
        min(max(value, minimum), maximum)
    }

}
