// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal

/// Errors produced by Metal render graph execution.
public enum MetalRenderError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A default Metal device could not be created.
    case metalDeviceUnavailable

    /// A command queue could not be created for the Metal device.
    case commandQueueCreationFailed

    /// The embedded Metal shader library could not be compiled.
    case shaderLibraryCreationFailed(String)

    /// A required shader function was not found in the library.
    case shaderFunctionUnavailable(String)

    /// A render pipeline state could not be created.
    case pipelineCreationFailed(String)

    /// The render graph does not contain its declared output node.
    case missingOutputNode(RenderNodeID)

    /// The graph output node is not a composite node.
    case unsupportedOutputNode(RenderNodeID)

    /// M2 only supports empty or single-source composite nodes.
    case unsupportedCompositeInputCount(nodeID: RenderNodeID, inputCount: Int)

    /// A composite input node was not present in the graph.
    case missingInputNode(RenderNodeID)

    /// M2 only supports source nodes as composite inputs.
    case unsupportedInputNode(RenderNodeID)

    /// The source texture provider could not supply a texture.
    case sourceTextureUnavailable(RenderNodeID, String)

    /// The output texture could not be allocated.
    case outputTextureCreationFailed(width: Int, height: Int)

    /// A Metal command buffer could not be created.
    case commandBufferCreationFailed

    /// A render command encoder could not be created.
    case renderEncoderCreationFailed

    /// A human-readable description of the render failure.
    public var description: String {
        switch self {
        case .metalDeviceUnavailable:
            "Metal device unavailable for render graph execution"
        case .commandQueueCreationFailed:
            "Metal command queue creation failed"
        case .shaderLibraryCreationFailed(let message):
            "Metal shader library creation failed: \(message)"
        case .shaderFunctionUnavailable(let name):
            "Metal shader function unavailable: \(name)"
        case .pipelineCreationFailed(let message):
            "Metal render pipeline creation failed: \(message)"
        case .missingOutputNode(let nodeID):
            "render graph is missing output node \(nodeID)"
        case .unsupportedOutputNode(let nodeID):
            "render graph output node \(nodeID) is not a composite node"
        case .unsupportedCompositeInputCount(let nodeID, let inputCount):
            "composite node \(nodeID) has unsupported input count \(inputCount)"
        case .missingInputNode(let nodeID):
            "render graph is missing input node \(nodeID)"
        case .unsupportedInputNode(let nodeID):
            "composite input node \(nodeID) is not a source node"
        case .sourceTextureUnavailable(let nodeID, let message):
            "source texture unavailable for node \(nodeID): \(message)"
        case .outputTextureCreationFailed(let width, let height):
            "output texture creation failed for \(width)x\(height)"
        case .commandBufferCreationFailed:
            "Metal command buffer creation failed"
        case .renderEncoderCreationFailed:
            "Metal render command encoder creation failed"
        }
    }
}

/// Output texture settings for one render graph execution.
public struct RenderOutputDescriptor: Equatable, Sendable {
    /// Output dimensions in pixels.
    public let pixelDimensions: PixelDimensions

    /// Metal pixel format for the output texture.
    public let pixelFormat: MTLPixelFormat

    /// Creates output texture settings.
    public init(
        pixelDimensions: PixelDimensions,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) {
        self.pixelDimensions = pixelDimensions
        self.pixelFormat = pixelFormat
    }
}

/// Supplies GPU-resident source textures for source render nodes.
public protocol RenderSourceTextureProvider {
    /// Returns the source texture for a resolved source node.
    func texture(for source: RenderSourceNode) throws -> MTLTexture
}

/// Closure-backed source texture provider for tests and simple integrations.
public struct ClosureRenderSourceTextureProvider: RenderSourceTextureProvider {
    private let handler: (RenderSourceNode) throws -> MTLTexture

    /// Creates a provider from a closure.
    public init(_ handler: @escaping (RenderSourceNode) throws -> MTLTexture) {
        self.handler = handler
    }

    /// Returns the source texture for a resolved source node.
    public func texture(for source: RenderSourceNode) throws -> MTLTexture {
        try handler(source)
    }
}

/// Result of scheduling one render graph execution.
public struct RenderedFrame {
    /// The output texture containing the rendered frame.
    public let texture: MTLTexture

    /// Cache identity for the graph output node.
    public let contentHash: ContentHash

    /// Whether the texture was returned from the content-hash cache.
    public let cacheHit: Bool

    /// Command buffer that writes `texture` when `cacheHit` is false.
    public let commandBuffer: MTLCommandBuffer?
}

/// Metal executor for the M2 single-source render graph.
public final class MetalRenderExecutor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelineStates: [UInt: MTLRenderPipelineState] = [:]
    private var frameCache: [ContentHash: MTLTexture] = [:]

    /// Number of content-hash cache entries retained by this executor.
    public var cacheEntryCount: Int {
        frameCache.count
    }

    /// Creates an executor with the default Metal device.
    public convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        try self.init(device: device)
    }

    /// Creates an executor with an explicit Metal device.
    public init(device: MTLDevice) throws {
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalRenderError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue

        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalRenderError.shaderLibraryCreationFailed(String(describing: error))
        }
    }

    /// Executes a render graph and returns a GPU-resident output texture.
    ///
    /// The render path samples the source `MTLTexture` supplied by `sourceProvider` and never
    /// performs CPU readback. AjarMedia can satisfy the source texture contract with textures
    /// created by `CVMetalTextureCache`.
    public func render(
        graph: RenderGraph,
        output: RenderOutputDescriptor,
        sourceProvider: any RenderSourceTextureProvider
    ) throws -> RenderedFrame {
        let outputNode = try outputNode(in: graph)
        if let cachedTexture = frameCache[outputNode.contentHash] {
            return RenderedFrame(
                texture: cachedTexture,
                contentHash: outputNode.contentHash,
                cacheHit: true,
                commandBuffer: nil
            )
        }

        let texture = try makeOutputTexture(output)
        let commandBuffer = try makeCommandBuffer()
        try encode(
            graph: graph,
            outputNode: outputNode,
            into: texture,
            commandBuffer: commandBuffer,
            sourceProvider: sourceProvider
        )
        frameCache[outputNode.contentHash] = texture
        commandBuffer.commit()

        return RenderedFrame(
            texture: texture,
            contentHash: outputNode.contentHash,
            cacheHit: false,
            commandBuffer: commandBuffer
        )
    }

    /// Removes all cached frame textures.
    public func removeAllCachedFrames() {
        frameCache.removeAll()
    }

    private func outputNode(in graph: RenderGraph) throws -> RenderNode {
        guard let outputNode = graph.outputNode else {
            throw MetalRenderError.missingOutputNode(graph.outputNodeID)
        }

        guard case .composite = outputNode.kind else {
            throw MetalRenderError.unsupportedOutputNode(outputNode.id)
        }

        return outputNode
    }

    private func makeOutputTexture(_ output: RenderOutputDescriptor) throws -> MTLTexture {
        let width = output.pixelDimensions.width
        let height = output.pixelDimensions.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: output.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        guard width > 0, height > 0, let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderError.outputTextureCreationFailed(width: width, height: height)
        }

        return texture
    }

    private func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRenderError.commandBufferCreationFailed
        }

        return commandBuffer
    }

    private func encode(
        graph: RenderGraph,
        outputNode: RenderNode,
        into outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        sourceProvider: any RenderSourceTextureProvider
    ) throws {
        switch outputNode.inputIDs.count {
        case 0:
            try encodeTransparentComposite(into: outputTexture, commandBuffer: commandBuffer)
        case 1:
            let sourceTexture = try sourceTexture(
                graph: graph,
                inputID: outputNode.inputIDs[0],
                sourceProvider: sourceProvider
            )
            try encodeSourceComposite(
                sourceTexture: sourceTexture,
                outputTexture: outputTexture,
                commandBuffer: commandBuffer
            )
        default:
            throw MetalRenderError.unsupportedCompositeInputCount(
                nodeID: outputNode.id,
                inputCount: outputNode.inputIDs.count
            )
        }
    }

    private func sourceTexture(
        graph: RenderGraph,
        inputID: RenderNodeID,
        sourceProvider: any RenderSourceTextureProvider
    ) throws -> MTLTexture {
        guard let inputNode = graph.node(withID: inputID) else {
            throw MetalRenderError.missingInputNode(inputID)
        }

        guard case .source(let source) = inputNode.kind else {
            throw MetalRenderError.unsupportedInputNode(inputID)
        }

        do {
            return try sourceProvider.texture(for: source)
        } catch {
            throw MetalRenderError.sourceTextureUnavailable(inputID, String(describing: error))
        }
    }

    private func encodeTransparentComposite(
        into outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = renderPassDescriptor(for: outputTexture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalRenderError.renderEncoderCreationFailed
        }

        encoder.endEncoding()
    }

    private func encodeSourceComposite(
        sourceTexture: MTLTexture,
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = renderPassDescriptor(for: outputTexture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalRenderError.renderEncoderCreationFailed
        }

        encoder.setRenderPipelineState(try pipelineState(for: outputTexture.pixelFormat))
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func renderPassDescriptor(for outputTexture: MTLTexture) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        let colorAttachment = descriptor.colorAttachments[0]
        colorAttachment?.texture = outputTexture
        colorAttachment?.loadAction = .clear
        colorAttachment?.storeAction = .store
        colorAttachment?.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        return descriptor
    }

    private func pipelineState(for pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let pipelineState = pipelineStates[pixelFormat.rawValue] {
            return pipelineState
        }

        guard let vertexFunction = library.makeFunction(name: "ajar_fullscreen_vertex") else {
            throw MetalRenderError.shaderFunctionUnavailable("ajar_fullscreen_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "ajar_passthrough_fragment") else {
            throw MetalRenderError.shaderFunctionUnavailable("ajar_passthrough_fragment")
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
            throw MetalRenderError.pipelineCreationFailed(String(describing: error))
        }
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct AjarVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex AjarVertexOut ajar_fullscreen_vertex(uint vertexID [[vertex_id]]) {
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

            AjarVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 ajar_passthrough_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]]
        ) {
            constexpr sampler sourceSampler(address::clamp_to_edge, filter::nearest);
            return sourceTexture.sample(sourceSampler, in.uv);
        }
        """
}
