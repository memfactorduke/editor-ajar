// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

import AjarCore
import Foundation
import Metal
import simd

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

    /// A composite node did not contain any supported source inputs.
    case unsupportedCompositeInputCount(nodeID: RenderNodeID, inputCount: Int)

    /// A composite input node was not present in the graph.
    case missingInputNode(RenderNodeID)

    /// A composite node did not contain parameters for each source input.
    case compositeInputMetadataMismatch(nodeID: RenderNodeID)

    /// M2 only supports source nodes as composite inputs.
    case unsupportedInputNode(RenderNodeID)

    /// The source texture provider could not supply a texture.
    case sourceTextureUnavailable(RenderNodeID, String)

    /// The output texture could not be allocated.
    case outputTextureCreationFailed(width: Int, height: Int)

    /// A Metal command buffer could not be created.
    case commandBufferCreationFailed

    /// A Metal blit encoder could not be created.
    case blitEncoderCreationFailed

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
        case .compositeInputMetadataMismatch(let nodeID):
            "composite node \(nodeID) does not have matching source input metadata"
        case .unsupportedInputNode(let nodeID):
            "composite input node \(nodeID) is not a source node"
        case .sourceTextureUnavailable(let nodeID, let message):
            "source texture unavailable for node \(nodeID): \(message)"
        case .outputTextureCreationFailed(let width, let height):
            "output texture creation failed for \(width)x\(height)"
        case .commandBufferCreationFailed:
            "Metal command buffer creation failed"
        case .blitEncoderCreationFailed:
            "Metal blit encoder creation failed"
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

    private let completion: RenderCompletion?
    private let retainedSourceProvider: Any?

    init(
        texture: MTLTexture,
        contentHash: ContentHash,
        cacheHit: Bool,
        commandBuffer: MTLCommandBuffer?,
        completion: RenderCompletion?,
        retainedSourceProvider: Any?
    ) {
        self.texture = texture
        self.contentHash = contentHash
        self.cacheHit = cacheHit
        self.commandBuffer = commandBuffer
        self.completion = completion
        self.retainedSourceProvider = retainedSourceProvider
    }

    /// Waits until the render command buffer has completed.
    public func waitForCompletion() async throws {
        try await completion?.wait()
    }
}

// swiftlint:disable type_body_length
/// Metal executor for GPU-resident render graph composites.
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
                commandBuffer: nil,
                completion: nil,
                retainedSourceProvider: nil
            )
        }

        let texture = try makeOutputTexture(output)
        let commandBuffer = try makeCommandBuffer()
        let completion = RenderCompletion()
        completion.attach(to: commandBuffer)
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
            commandBuffer: commandBuffer,
            completion: completion,
            retainedSourceProvider: sourceProvider
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
        guard case .composite(let composite) = outputNode.kind else {
            throw MetalRenderError.unsupportedOutputNode(outputNode.id)
        }

        switch outputNode.inputIDs.count {
        case 0:
            try encodeTransparentComposite(into: outputTexture, commandBuffer: commandBuffer)
        default:
            guard composite.inputs.count == outputNode.inputIDs.count else {
                throw MetalRenderError.compositeInputMetadataMismatch(nodeID: outputNode.id)
            }
            guard composite.inputs.map(\.sourceNodeID) == outputNode.inputIDs else {
                throw MetalRenderError.compositeInputMetadataMismatch(nodeID: outputNode.id)
            }

            let sourceInputs = try composite.inputs.map { input in
                try sourceInput(graph: graph, input: input, sourceProvider: sourceProvider)
            }
            try encodeSourceComposite(
                sourceInputs: sourceInputs,
                outputTexture: outputTexture,
                commandBuffer: commandBuffer
            )
        }
    }

    private struct SourceCompositeInput {
        let source: RenderSourceNode
        let texture: MTLTexture
        let transform: ClipTransform
    }

    private func sourceInput(
        graph: RenderGraph,
        input: RenderCompositeInput,
        sourceProvider: any RenderSourceTextureProvider
    ) throws -> SourceCompositeInput {
        guard let inputNode = graph.node(withID: input.sourceNodeID) else {
            throw MetalRenderError.missingInputNode(input.sourceNodeID)
        }

        guard case .source(let source) = inputNode.kind else {
            throw MetalRenderError.unsupportedInputNode(input.sourceNodeID)
        }

        do {
            return SourceCompositeInput(
                source: source,
                texture: try sourceProvider.texture(for: source),
                transform: input.transform
            )
        } catch {
            throw MetalRenderError.sourceTextureUnavailable(
                input.sourceNodeID,
                String(describing: error)
            )
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
        sourceInputs: [SourceCompositeInput],
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let firstTexture = try makeIntermediateTexture(matching: outputTexture)
        let secondTexture = try makeIntermediateTexture(matching: outputTexture)
        try clear(firstTexture, commandBuffer: commandBuffer)

        var readTexture = firstTexture
        var writeTexture = secondTexture
        for sourceInput in sourceInputs {
            try encodeSourceCompositePass(
                sourceInput: sourceInput,
                destinationTexture: readTexture,
                outputTexture: writeTexture,
                commandBuffer: commandBuffer
            )
            swap(&readTexture, &writeTexture)
        }

        try copy(readTexture, to: outputTexture, commandBuffer: commandBuffer)
    }

    private func encodeSourceCompositePass(
        sourceInput: SourceCompositeInput,
        destinationTexture: MTLTexture,
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = renderPassDescriptor(for: outputTexture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalRenderError.renderEncoderCreationFailed
        }

        encoder.setRenderPipelineState(try pipelineState(for: outputTexture.pixelFormat))
        var uniforms = uniforms(
            transform: sourceInput.transform,
            sourceTexture: sourceInput.texture,
            outputTexture: outputTexture
        )
        encoder.setFragmentTexture(sourceInput.texture, index: 0)
        encoder.setFragmentTexture(destinationTexture, index: 1)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<AjarCompositeUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func makeIntermediateTexture(matching outputTexture: MTLTexture) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: outputTexture.pixelFormat,
            width: outputTexture.width,
            height: outputTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderError.outputTextureCreationFailed(
                width: outputTexture.width,
                height: outputTexture.height
            )
        }

        return texture
    }

    private func clear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        let descriptor = renderPassDescriptor(for: texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalRenderError.renderEncoderCreationFailed
        }
        encoder.endEncoding()
    }

    private func copy(
        _ sourceTexture: MTLTexture,
        to destinationTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRenderError.blitEncoderCreationFailed
        }
        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: sourceTexture.width,
                height: sourceTexture.height,
                depth: 1
            ),
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
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
        guard let fragmentFunction = library.makeFunction(name: "ajar_transform_fragment") else {
            throw MetalRenderError.shaderFunctionUnavailable("ajar_transform_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelineStates[pixelFormat.rawValue] = pipelineState
            return pipelineState
        } catch {
            throw MetalRenderError.pipelineCreationFailed(String(describing: error))
        }
    }

    private func uniforms(
        transform: ClipTransform,
        sourceTexture: MTLTexture,
        outputTexture: MTLTexture
    ) -> AjarCompositeUniforms {
        AjarCompositeUniforms(
            outputSize: SIMD2<Float>(Float(outputTexture.width), Float(outputTexture.height)),
            sourceSize: SIMD2<Float>(Float(sourceTexture.width), Float(sourceTexture.height)),
            position: simdPoint(transform.position),
            scale: simdScale(transform.scale),
            anchorPoint: simdPoint(transform.anchorPoint),
            crop: SIMD4<Float>(
                Float(transform.crop.left),
                Float(transform.crop.top),
                Float(transform.crop.right),
                Float(transform.crop.bottom)
            ),
            rotationRadians: radians(from: transform.rotation),
            opacity: clamp01(floatValue(transform.opacity)),
            flipHorizontal: transform.flip.horizontal ? 1 : 0,
            flipVertical: transform.flip.vertical ? 1 : 0,
            blendMode: blendModeValue(transform.blendMode),
            padding: 0
        )
    }

    private func simdPoint(_ point: CanvasPoint) -> SIMD2<Float> {
        SIMD2<Float>(floatValue(point.x), floatValue(point.y))
    }

    private func simdScale(_ scale: ClipScale) -> SIMD2<Float> {
        SIMD2<Float>(floatValue(scale.x), floatValue(scale.y))
    }

    private func radians(from rotation: ClipRotation) -> Float {
        let degrees = doubleValue(rotation.degrees) + (Double(rotation.revolutions) * 360.0)
        return Float(degrees * .pi / 180.0)
    }

    private func floatValue(_ value: RationalValue) -> Float {
        Float(doubleValue(value))
    }

    private func doubleValue(_ value: RationalValue) -> Double {
        Double(value.numerator) / Double(value.denominator)
    }

    private func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private func blendModeValue(_ blendMode: ClipBlendMode) -> UInt32 {
        switch blendMode {
        case .normal:
            return 0
        case .multiply:
            return 1
        case .screen:
            return 2
        case .overlay:
            return 3
        case .add:
            return 4
        case .darken:
            return 5
        case .lighten:
            return 6
        }
    }

    private struct AjarCompositeUniforms {
        var outputSize: SIMD2<Float>
        var sourceSize: SIMD2<Float>
        var position: SIMD2<Float>
        var scale: SIMD2<Float>
        var anchorPoint: SIMD2<Float>
        var crop: SIMD4<Float>
        var rotationRadians: Float
        var opacity: Float
        var flipHorizontal: UInt32
        var flipVertical: UInt32
        var blendMode: UInt32
        var padding: UInt32
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

        struct AjarCompositeUniforms {
            float2 outputSize;
            float2 sourceSize;
            float2 position;
            float2 scale;
            float2 anchorPoint;
            float4 crop;
            float rotationRadians;
            float opacity;
            uint flipHorizontal;
            uint flipVertical;
            uint blendMode;
            uint padding;
        };

        static float3 ajar_unpremultiply(float4 color) {
            if (color.a <= 0.00001) {
                return float3(0.0);
            }
            return color.rgb / color.a;
        }

        static float3 ajar_blend_color(uint mode, float3 source, float3 destination) {
            switch (mode) {
            case 1:
                return source * destination;
            case 2:
                return 1.0 - ((1.0 - source) * (1.0 - destination));
            case 3:
                return select(
                    1.0 - (2.0 * (1.0 - source) * (1.0 - destination)),
                    2.0 * source * destination,
                    destination <= 0.5
                );
            case 4:
                return min(source + destination, 1.0);
            case 5:
                return min(source, destination);
            case 6:
                return max(source, destination);
            default:
                return source;
            }
        }

        static float4 ajar_composite(float4 source, float4 destination, uint blendMode) {
            float sourceAlpha = source.a;
            float destinationAlpha = destination.a;
            if (sourceAlpha <= 0.00001) {
                return destination;
            }

            float outputAlpha = sourceAlpha + (destinationAlpha * (1.0 - sourceAlpha));
            if (blendMode == 0 || destinationAlpha <= 0.00001) {
                return saturate(float4(
                    source.rgb + (destination.rgb * (1.0 - sourceAlpha)),
                    outputAlpha
                ));
            }

            float3 sourceStraight = source.rgb / sourceAlpha;
            float3 destinationStraight = ajar_unpremultiply(destination);
            float3 blended = ajar_blend_color(blendMode, sourceStraight, destinationStraight);
            float3 outputRGB = (blended * sourceAlpha * destinationAlpha)
                + (source.rgb * (1.0 - destinationAlpha))
                + (destination.rgb * (1.0 - sourceAlpha));
            return saturate(float4(outputRGB, outputAlpha));
        }

        fragment float4 ajar_transform_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            texture2d<float> destinationTexture [[texture(1)]],
            constant AjarCompositeUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler sourceSampler(address::clamp_to_edge, filter::nearest);
            float4 destination = destinationTexture.sample(sourceSampler, in.uv);
            float2 canvasPoint = in.uv * uniforms.outputSize;
            float2 relative = canvasPoint - uniforms.anchorPoint - uniforms.position;
            float cosine = cos(-uniforms.rotationRadians);
            float sine = sin(-uniforms.rotationRadians);
            float2 rotated = float2(
                (relative.x * cosine) - (relative.y * sine),
                (relative.x * sine) + (relative.y * cosine)
            );

            if (abs(uniforms.scale.x) <= 0.00001 || abs(uniforms.scale.y) <= 0.00001) {
                return destination;
            }

            float2 localPoint = (rotated / uniforms.scale) + uniforms.anchorPoint;
            float2 cropMin = uniforms.crop.xy;
            float2 cropMax = uniforms.sourceSize - uniforms.crop.zw;
            if (localPoint.x < cropMin.x || localPoint.y < cropMin.y
                || localPoint.x >= cropMax.x || localPoint.y >= cropMax.y) {
                return destination;
            }

            float2 sourceUV = localPoint / uniforms.sourceSize;
            if (sourceUV.x < 0.0 || sourceUV.y < 0.0 || sourceUV.x > 1.0 || sourceUV.y > 1.0) {
                return destination;
            }
            if (uniforms.flipHorizontal != 0) {
                sourceUV.x = 1.0 - sourceUV.x;
            }
            if (uniforms.flipVertical != 0) {
                sourceUV.y = 1.0 - sourceUV.y;
            }

            float4 source = sourceTexture.sample(sourceSampler, sourceUV);
            source.a *= uniforms.opacity;
            source.rgb *= source.a;
            return ajar_composite(source, destination, uniforms.blendMode);
        }
        """
}
// swiftlint:enable type_body_length

final class RenderCompletion {
    private typealias CompletionContinuation = CheckedContinuation<Void, Error>

    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuations: [CompletionContinuation] = []

    func attach(to commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            self?.complete(error: completedBuffer.error)
        }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CompletionContinuation) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }

            continuations.append(continuation)
            lock.unlock()
        }
    }

    private func complete(error: Error?) {
        let result: Result<Void, Error> = error.map(Result.failure) ?? .success(())

        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }

        self.result = result
        let continuations = continuations
        self.continuations.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(with: result)
        }
    }
}
