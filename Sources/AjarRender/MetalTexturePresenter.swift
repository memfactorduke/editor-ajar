// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import MetalKit

/// Errors produced while presenting a rendered texture to an `MTKView`.
public enum MetalTexturePresenterError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A command queue could not be created.
    case commandQueueCreationFailed

    /// The embedded presentation shader library could not be compiled.
    case shaderLibraryCreationFailed(String)

    /// A required presentation shader function was missing.
    case shaderFunctionUnavailable(String)

    /// The presentation pipeline could not be created.
    case pipelineCreationFailed(String)

    /// The view had no drawable or render pass descriptor ready.
    case drawableUnavailable

    /// A command buffer could not be created.
    case commandBufferCreationFailed

    /// A render encoder could not be created.
    case renderEncoderCreationFailed

    /// A human-readable description of the presentation failure.
    public var description: String {
        switch self {
        case .commandQueueCreationFailed:
            "Metal presentation command queue creation failed"
        case .shaderLibraryCreationFailed(let message):
            "Metal presentation shader library creation failed: \(message)"
        case .shaderFunctionUnavailable(let name):
            "Metal presentation shader function unavailable: \(name)"
        case .pipelineCreationFailed(let message):
            "Metal presentation pipeline creation failed: \(message)"
        case .drawableUnavailable:
            "MTKView drawable unavailable"
        case .commandBufferCreationFailed:
            "Metal presentation command buffer creation failed"
        case .renderEncoderCreationFailed:
            "Metal presentation render encoder creation failed"
        }
    }
}

/// GPU-only presenter that draws a rendered source texture into an `MTKView` drawable.
public final class MetalTexturePresenter {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelineStates: [UInt: MTLRenderPipelineState] = [:]

    /// Creates a presenter for the provided Metal device.
    public init(device: MTLDevice) throws {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalTexturePresenterError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue

        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalTexturePresenterError.shaderLibraryCreationFailed(String(describing: error))
        }
    }

    /// Presents `sourceTexture` to the view's current drawable without CPU readback.
    public func present(sourceTexture: MTLTexture, in view: MTKView) throws {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor
        else {
            throw MetalTexturePresenterError.drawableUnavailable
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalTexturePresenterError.commandBufferCreationFailed
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalTexturePresenterError.renderEncoderCreationFailed
        }

        encoder.setRenderPipelineState(try pipelineState(for: view.colorPixelFormat))
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func pipelineState(for pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let pipelineState = pipelineStates[pixelFormat.rawValue] {
            return pipelineState
        }

        guard let vertexFunction = library.makeFunction(name: "ajar_present_vertex") else {
            throw MetalTexturePresenterError.shaderFunctionUnavailable("ajar_present_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "ajar_present_fragment") else {
            throw MetalTexturePresenterError.shaderFunctionUnavailable("ajar_present_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        do {
            let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelineStates[pixelFormat.rawValue] = pipelineState
            return pipelineState
        } catch {
            throw MetalTexturePresenterError.pipelineCreationFailed(String(describing: error))
        }
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct AjarPresentVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex AjarPresentVertexOut ajar_present_vertex(uint vertexID [[vertex_id]]) {
            constexpr float2 positions[6] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, -1.0),
                float2(1.0, 1.0),
                float2(-1.0, 1.0),
            };
            constexpr float2 uvs[6] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 1.0),
                float2(1.0, 0.0),
                float2(0.0, 0.0),
            };

            AjarPresentVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 ajar_present_fragment(
            AjarPresentVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]]
        ) {
            constexpr sampler sourceSampler(address::clamp_to_edge, filter::linear);
            return sourceTexture.sample(sourceSampler, in.uv);
        }
        """
}
