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

/// Color encoding written to an executor output texture (NFR-QUAL-001).
public enum RenderOutputColorMode: Hashable, Sendable {
    /// Display-encoded output: the render finishes with the present pass that applies the
    /// composite's output transfer function.
    case presented

    /// Premultiplied linear working-space output: the present pass is skipped and the texture
    /// holds linear working-space color. The executor requests this mode for nested compound
    /// renders so each nesting level stays linear until the single outermost present pass.
    case linearWorking
}

/// Output texture settings for one render graph execution.
public struct RenderOutputDescriptor: Equatable, Sendable {
    /// Output dimensions in pixels.
    public let pixelDimensions: PixelDimensions

    /// Metal pixel format for the output texture.
    public let pixelFormat: MTLPixelFormat

    /// Color encoding written to the output texture.
    ///
    /// This is deliberately independent of `pixelFormat`: requesting an
    /// `MetalRenderExecutor.linearWorkingPixelFormat` (rgba16Float) output with the default
    /// `.presented` mode still applies the display-transfer present pass, so a future
    /// HDR-presented half-float output never silently receives linear working-space color.
    /// Only callers that explicitly pass `.linearWorking` opt out of the present pass.
    public let colorMode: RenderOutputColorMode

    /// Creates output texture settings.
    public init(
        pixelDimensions: PixelDimensions,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        colorMode: RenderOutputColorMode = .presented
    ) {
        self.pixelDimensions = pixelDimensions
        self.pixelFormat = pixelFormat
        self.colorMode = colorMode
    }
}

private struct TextureDescriptorKey: Hashable {
    let pixelDimensions: PixelDimensions
    let pixelFormatRawValue: UInt

    init(pixelDimensions: PixelDimensions, pixelFormat: MTLPixelFormat) {
        self.pixelDimensions = pixelDimensions
        self.pixelFormatRawValue = pixelFormat.rawValue
    }

    init(output: RenderOutputDescriptor) {
        self.init(pixelDimensions: output.pixelDimensions, pixelFormat: output.pixelFormat)
    }

    init(texture: MTLTexture) {
        self.init(
            pixelDimensions: PixelDimensions(width: texture.width, height: texture.height),
            pixelFormat: texture.pixelFormat
        )
    }
}

private struct FrameCacheKey: Hashable {
    let contentHash: ContentHash
    let textureDescriptor: TextureDescriptorKey
    let colorMode: RenderOutputColorMode

    init(contentHash: ContentHash, output: RenderOutputDescriptor) {
        self.contentHash = contentHash
        self.textureDescriptor = TextureDescriptorKey(output: output)
        self.colorMode = output.colorMode
    }
}

struct AjarCompositeUniformLayout: Equatable, Sendable {
    let stride: Int
    let alignment: Int
    let maskStride: Int
    let outputSize: Int
    let sourceSize: Int
    let position: Int
    let scale: Int
    let anchorPoint: Int
    let crop: Int
    let rotationRadians: Int
    let opacity: Int
    let flipHorizontal: Int
    let flipVertical: Int
    let blendMode: Int
    let sourceTransfer: Int
    let sourcePrimaries: Int
    let sourceIsLinearWorking: Int
    let workingPrimaries: Int
    let outputTransfer: Int
    let chromaKeyColorAndTolerance: Int
    let chromaKeyControls: Int
    let chromaKeyMode: Int
    let chromaKeyPadding0: Int
    let chromaKeyPadding1: Int
    let chromaKeyPadding2: Int
    let lumaKeyThresholds: Int
    let lumaKeyControls: Int
    let colorCorrectionControls: Int
    let colorCorrectionWhiteBalance: Int
    let colorCorrectionLift: Int
    let colorCorrectionGamma: Int
    let colorCorrectionGain: Int
    let maskCount: Int
    let maskPadding0: Int
    let maskPadding1: Int
    let maskPadding2: Int
    let mask0: Int
    let mask1: Int
    let mask2: Int
    let mask3: Int
}

/// Supplies GPU-resident source textures for source render nodes.
public protocol RenderSourceTextureProvider {
    /// Returns the source texture for a resolved source node.
    ///
    /// Textures supplied to the compositor must store display-encoded color channels
    /// premultiplied by alpha. The Metal composite shader unpremultiplies before transfer
    /// conversion and treats straight-alpha texture data as invalid input. Opaque sources satisfy
    /// the contract with alpha `1`; importers for transparent formats such as PNG or ProRes 4444
    /// must premultiply before exposing textures through this provider.
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
    private let retainedObjects: [Any]

    init(
        texture: MTLTexture,
        contentHash: ContentHash,
        cacheHit: Bool,
        commandBuffer: MTLCommandBuffer?,
        completion: RenderCompletion?,
        retainedObjects: [Any]
    ) {
        self.texture = texture
        self.contentHash = contentHash
        self.cacheHit = cacheHit
        self.commandBuffer = commandBuffer
        self.completion = completion
        self.retainedObjects = retainedObjects
    }

    /// Waits until the render command buffer has completed.
    public func waitForCompletion() async throws {
        try await completion?.wait()
    }
}

private struct RenderSchedule {
    var nestedFrames: [RenderedFrame] = []
    var reusableTextures: [MTLTexture] = []
}

// swiftlint:disable type_body_length
/// Metal executor for GPU-resident render graph composites.
public final class MetalRenderExecutor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let executorStateLock = NSLock()
    private var pipelineStates: [PipelineStateKey: MTLRenderPipelineState] = [:]
    private var frameCache: [FrameCacheKey: MTLTexture] = [:]
    private var frameCacheAccessOrder: [FrameCacheKey] = []
    private var cacheHitCountValue = 0
    private var cacheMissCountValue = 0
    private var outputPassCountValue = 0
    private let texturePoolLock = NSLock()
    private var texturePool: [TextureDescriptorKey: [MTLTexture]] = [:]
    private var texturePoolAccessOrder: [TextureDescriptorKey] = []
    private var texturePoolStoredCount = 0
    private var texturePoolHitCountValue = 0

    /// Half-float linear working format used between composite passes.
    public static let linearWorkingPixelFormat: MTLPixelFormat = .rgba16Float

    /// Maximum number of content-hash cache entries retained by this executor.
    public let maximumCacheEntryCount: Int

    /// Maximum number of completed reusable textures retained by this executor.
    public let maximumPooledTextureCount: Int

    /// Number of content-hash cache entries retained by this executor.
    public var cacheEntryCount: Int {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        return frameCache.count
    }

    /// Number of completed reusable textures retained by this executor.
    public var texturePoolEntryCount: Int {
        texturePoolLock.lock()
        defer { texturePoolLock.unlock() }
        return texturePoolStoredCount
    }

    /// Number of texture allocations avoided by the reusable texture pool.
    public var texturePoolHitCount: Int {
        texturePoolLock.lock()
        defer { texturePoolLock.unlock() }
        return texturePoolHitCountValue
    }

    /// Number of render calls satisfied by the content-hash cache.
    public var cacheHitCount: Int {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        return cacheHitCountValue
    }

    /// Number of render calls that populated the content-hash cache.
    public var cacheMissCount: Int {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        return cacheMissCountValue
    }

    /// Number of display-transfer output passes encoded by this executor.
    public var outputPassCount: Int {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        return outputPassCountValue
    }

    /// Creates an executor with the default Metal device.
    public convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        try self.init(device: device)
    }

    /// Creates an executor with an explicit Metal device.
    public init(
        device: MTLDevice,
        maximumCacheEntryCount: Int = 16,
        maximumPooledTextureCount: Int = 16
    ) throws {
        self.device = device
        self.maximumCacheEntryCount = max(1, maximumCacheEntryCount)
        self.maximumPooledTextureCount = max(0, maximumPooledTextureCount)

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
        let cacheKey = FrameCacheKey(contentHash: outputNode.contentHash, output: output)
        if let cachedTexture = cachedTexture(for: cacheKey) {
            recordCacheHit()
            return RenderedFrame(
                texture: cachedTexture,
                contentHash: outputNode.contentHash,
                cacheHit: true,
                commandBuffer: nil,
                completion: nil,
                retainedObjects: []
            )
        }

        let texture = try makeOutputTexture(output)
        let commandBuffer = try makeCommandBuffer()
        let completion = RenderCompletion()
        completion.attach(to: commandBuffer)
        let schedule = try encode(
            graph: graph,
            output: output,
            into: texture,
            commandBuffer: commandBuffer,
            sourceProvider: sourceProvider
        )
        recordCacheMiss()
        storeCachedTexture(texture, for: cacheKey)
        recycleReusableTextures(schedule.reusableTextures, after: commandBuffer)
        commandBuffer.commit()
        var retainedObjects: [Any] = [sourceProvider]
        retainedObjects.append(contentsOf: schedule.nestedFrames)

        return RenderedFrame(
            texture: texture,
            contentHash: outputNode.contentHash,
            cacheHit: false,
            commandBuffer: commandBuffer,
            completion: completion,
            retainedObjects: retainedObjects
        )
    }

    /// Removes all cached frame textures.
    public func removeAllCachedFrames() {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        frameCache.removeAll()
        frameCacheAccessOrder.removeAll()
        cacheHitCountValue = 0
        cacheMissCountValue = 0
    }

    private func recordCacheHit() {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        cacheHitCountValue += 1
    }

    private func recordCacheMiss() {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        cacheMissCountValue += 1
    }

    private func recordOutputPass() {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        outputPassCountValue += 1
    }

    private func cachedTexture(for key: FrameCacheKey) -> MTLTexture? {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        guard let texture = frameCache[key] else {
            return nil
        }
        markCacheEntryUsedLocked(key)
        return texture
    }

    private func storeCachedTexture(_ texture: MTLTexture, for key: FrameCacheKey) {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        frameCache[key] = texture
        markCacheEntryUsedLocked(key)
        evictExpiredCacheEntriesLocked()
    }

    private func markCacheEntryUsedLocked(_ key: FrameCacheKey) {
        frameCacheAccessOrder.removeAll { $0 == key }
        frameCacheAccessOrder.append(key)
    }

    private func evictExpiredCacheEntriesLocked() {
        while frameCacheAccessOrder.count > maximumCacheEntryCount {
            let expiredKey = frameCacheAccessOrder.removeFirst()
            frameCache.removeValue(forKey: expiredKey)
        }
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
        guard width > 0, height > 0 else {
            throw MetalRenderError.outputTextureCreationFailed(width: width, height: height)
        }
        return try makeReusableTexture(
            pixelFormat: output.pixelFormat,
            width: width,
            height: height
        )
    }

    private func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRenderError.commandBufferCreationFailed
        }

        return commandBuffer
    }

    private func nestedOutputDescriptor(
        for output: RenderOutputDescriptor
    ) -> RenderOutputDescriptor {
        RenderOutputDescriptor(
            pixelDimensions: output.pixelDimensions,
            pixelFormat: Self.linearWorkingPixelFormat,
            colorMode: .linearWorking
        )
    }

    private func encode(
        graph: RenderGraph,
        output: RenderOutputDescriptor,
        into outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        sourceProvider: any RenderSourceTextureProvider
    ) throws -> RenderSchedule {
        let outputNode = try outputNode(in: graph)
        guard case .composite(let composite) = outputNode.kind else {
            throw MetalRenderError.unsupportedOutputNode(outputNode.id)
        }

        switch outputNode.inputIDs.count {
        case 0:
            try encodeTransparentComposite(into: outputTexture, commandBuffer: commandBuffer)
            return RenderSchedule()
        default:
            guard composite.inputs.count == outputNode.inputIDs.count else {
                throw MetalRenderError.compositeInputMetadataMismatch(nodeID: outputNode.id)
            }
            guard composite.inputs.map(\.sourceNodeID) == outputNode.inputIDs else {
                throw MetalRenderError.compositeInputMetadataMismatch(nodeID: outputNode.id)
            }

            let sourceInputs = try composite.inputs.map { input in
                try sourceInput(
                    graph: graph,
                    input: input,
                    output: output,
                    sourceProvider: sourceProvider
                )
            }
            let reusableTextures = try encodeSourceComposite(
                composite: composite,
                sourceInputs: sourceInputs,
                outputTexture: outputTexture,
                commandBuffer: commandBuffer,
                outputMode: output.colorMode
            )
            return RenderSchedule(
                nestedFrames: sourceInputs.compactMap(\.retainedFrame),
                reusableTextures: reusableTextures
            )
        }
    }

    private struct SourceCompositeInput {
        let source: RenderSourceNode
        let texture: MTLTexture
        let transform: ClipTransform
        let effects: ClipEffects
        let trackOpacity: RationalValue
        let trackBlendMode: ClipBlendMode
        let sourceColorSpace: MediaColorSpace
        let sourceIsLinearWorking: Bool
        let retainedFrame: RenderedFrame?
    }

    private static let blendModeValues: [ClipBlendMode: UInt32] = [
        .normal: 0,
        .multiply: 1,
        .screen: 2,
        .overlay: 3,
        .add: 4,
        .darken: 5,
        .lighten: 6,
        .colorDodge: 7,
        .colorBurn: 8,
        .hardLight: 9,
        .softLight: 10,
        .difference: 11,
        .exclusion: 12,
        .subtract: 13,
        .hue: 14,
        .saturation: 15,
        .color: 16,
        .luminosity: 17
    ]

    private func sourceInput(
        graph: RenderGraph,
        input: RenderCompositeInput,
        output: RenderOutputDescriptor,
        sourceProvider: any RenderSourceTextureProvider
    ) throws -> SourceCompositeInput {
        guard let inputNode = graph.node(withID: input.sourceNodeID) else {
            throw MetalRenderError.missingInputNode(input.sourceNodeID)
        }

        switch inputNode.kind {
        case .source(let source):
            do {
                return SourceCompositeInput(
                    source: source,
                    texture: try sourceProvider.texture(for: source),
                    transform: input.transform,
                    effects: input.effects,
                    trackOpacity: input.trackOpacity,
                    trackBlendMode: input.trackBlendMode,
                    sourceColorSpace: source.colorSpace,
                    sourceIsLinearWorking: false,
                    retainedFrame: nil
                )
            } catch {
                throw MetalRenderError.sourceTextureUnavailable(
                    input.sourceNodeID,
                    String(describing: error)
                )
            }
        case .compound(let compound):
            let frame = try render(
                graph: compound.graph,
                output: nestedOutputDescriptor(for: output),
                sourceProvider: sourceProvider
            )
            return SourceCompositeInput(
                source: RenderSourceNode(
                    mediaID: compound.sequenceID,
                    clipID: compound.clipID,
                    sourceTime: compound.sequenceTime,
                    sourceRange: compound.sourceRange,
                    speed: compound.speed,
                    reverse: compound.reverse,
                    freezeFrame: compound.freezeFrame,
                    colorSpace: compound.colorSpace
                ),
                texture: frame.texture,
                transform: input.transform,
                effects: input.effects,
                trackOpacity: input.trackOpacity,
                trackBlendMode: input.trackBlendMode,
                sourceColorSpace: compound.colorSpace,
                sourceIsLinearWorking: true,
                retainedFrame: frame
            )
        case .composite:
            throw MetalRenderError.unsupportedInputNode(input.sourceNodeID)
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
        composite: RenderCompositeNode,
        sourceInputs: [SourceCompositeInput],
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        outputMode: RenderOutputColorMode
    ) throws -> [MTLTexture] {
        switch outputMode {
        case .presented:
            return try encodePresentedSourceComposite(
                composite: composite,
                sourceInputs: sourceInputs,
                outputTexture: outputTexture,
                commandBuffer: commandBuffer
            )
        case .linearWorking:
            return try encodeLinearWorkingSourceComposite(
                composite: composite,
                sourceInputs: sourceInputs,
                outputTexture: outputTexture,
                commandBuffer: commandBuffer
            )
        }
    }

    private func encodePresentedSourceComposite(
        composite: RenderCompositeNode,
        sourceInputs: [SourceCompositeInput],
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> [MTLTexture] {
        let firstTexture = try makeIntermediateTexture(matching: outputTexture)
        let secondTexture = try makeIntermediateTexture(matching: outputTexture)
        try clear(firstTexture, commandBuffer: commandBuffer)

        var readTexture = firstTexture
        var writeTexture = secondTexture
        for sourceInput in sourceInputs {
            try encodeSourceCompositePass(
                composite: composite,
                sourceInput: sourceInput,
                destinationTexture: readTexture,
                outputTexture: writeTexture,
                commandBuffer: commandBuffer
            )
            swap(&readTexture, &writeTexture)
        }

        try encodeOutputPass(
            linearTexture: readTexture,
            outputTexture: outputTexture,
            composite: composite,
            commandBuffer: commandBuffer
        )
        return [firstTexture, secondTexture]
    }

    private func encodeLinearWorkingSourceComposite(
        composite: RenderCompositeNode,
        sourceInputs: [SourceCompositeInput],
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> [MTLTexture] {
        let intermediateTexture = try makeIntermediateTexture(matching: outputTexture)
        var readTexture: MTLTexture
        var writeTexture: MTLTexture
        if sourceInputs.count.isMultiple(of: 2) {
            try clear(outputTexture, commandBuffer: commandBuffer)
            readTexture = outputTexture
            writeTexture = intermediateTexture
        } else {
            try clear(intermediateTexture, commandBuffer: commandBuffer)
            readTexture = intermediateTexture
            writeTexture = outputTexture
        }

        for sourceInput in sourceInputs {
            try encodeSourceCompositePass(
                composite: composite,
                sourceInput: sourceInput,
                destinationTexture: readTexture,
                outputTexture: writeTexture,
                commandBuffer: commandBuffer
            )
            swap(&readTexture, &writeTexture)
        }

        return [intermediateTexture]
    }

    private func encodeSourceCompositePass(
        composite: RenderCompositeNode,
        sourceInput: SourceCompositeInput,
        destinationTexture: MTLTexture,
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = renderPassDescriptor(for: outputTexture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalRenderError.renderEncoderCreationFailed
        }

        encoder.setRenderPipelineState(
            try pipelineState(
                fragmentFunctionName: "ajar_transform_fragment",
                pixelFormat: outputTexture.pixelFormat
            )
        )
        var uniforms = uniforms(
            input: sourceInput,
            sourceTexture: sourceInput.texture,
            outputTexture: outputTexture,
            workingColorSpace: composite.workingColorSpace,
            outputColorSpace: composite.outputColorSpace
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

    private func encodeOutputPass(
        linearTexture: MTLTexture,
        outputTexture: MTLTexture,
        composite: RenderCompositeNode,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = renderPassDescriptor(for: outputTexture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalRenderError.renderEncoderCreationFailed
        }

        encoder.setRenderPipelineState(
            try pipelineState(
                fragmentFunctionName: "ajar_present_fragment",
                pixelFormat: outputTexture.pixelFormat
            )
        )
        var uniforms = presentUniforms(composite: composite)
        encoder.setFragmentTexture(linearTexture, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<AjarPresentUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        recordOutputPass()
    }

    private func makeIntermediateTexture(matching outputTexture: MTLTexture) throws -> MTLTexture {
        try makeReusableTexture(
            pixelFormat: Self.linearWorkingPixelFormat,
            width: outputTexture.width,
            height: outputTexture.height
        )
    }

    private func makeReusableTexture(
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        let key = TextureDescriptorKey(
            pixelDimensions: PixelDimensions(width: width, height: height),
            pixelFormat: pixelFormat
        )
        if let texture = pooledTexture(for: key) {
            return texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderError.outputTextureCreationFailed(
                width: width,
                height: height
            )
        }

        return texture
    }

    private func pooledTexture(for key: TextureDescriptorKey) -> MTLTexture? {
        texturePoolLock.lock()
        defer { texturePoolLock.unlock() }

        guard var bucket = texturePool[key], let texture = bucket.popLast() else {
            return nil
        }

        if bucket.isEmpty {
            texturePool.removeValue(forKey: key)
        } else {
            texturePool[key] = bucket
        }
        if let accessIndex = texturePoolAccessOrder.lastIndex(of: key) {
            texturePoolAccessOrder.remove(at: accessIndex)
        }
        texturePoolStoredCount -= 1
        texturePoolHitCountValue += 1
        return texture
    }

    private func recycleReusableTextures(
        _ textures: [MTLTexture],
        after commandBuffer: MTLCommandBuffer
    ) {
        guard maximumPooledTextureCount > 0, !textures.isEmpty else {
            return
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.storeReusableTextures(textures)
        }
    }

    private func storeReusableTextures(_ textures: [MTLTexture]) {
        texturePoolLock.lock()
        defer { texturePoolLock.unlock() }

        for texture in textures {
            let key = TextureDescriptorKey(texture: texture)
            texturePool[key, default: []].append(texture)
            texturePoolAccessOrder.append(key)
            texturePoolStoredCount += 1
        }
        evictExpiredReusableTextures()
    }

    private func evictExpiredReusableTextures() {
        while texturePoolStoredCount > maximumPooledTextureCount,
              let expiredKey = texturePoolAccessOrder.first {
            texturePoolAccessOrder.removeFirst()
            guard var bucket = texturePool[expiredKey], !bucket.isEmpty else {
                continue
            }
            bucket.removeFirst()
            texturePoolStoredCount -= 1
            if bucket.isEmpty {
                texturePool.removeValue(forKey: expiredKey)
            } else {
                texturePool[expiredKey] = bucket
            }
        }
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

    private func pipelineState(
        fragmentFunctionName: String,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let key = PipelineStateKey(
            fragmentFunctionName: fragmentFunctionName,
            pixelFormatRawValue: pixelFormat.rawValue
        )
        if let pipelineState = cachedPipelineState(for: key) {
            return pipelineState
        }

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
        descriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            return storePipelineState(pipelineState, for: key)
        } catch {
            throw MetalRenderError.pipelineCreationFailed(String(describing: error))
        }
    }

    private func cachedPipelineState(for key: PipelineStateKey) -> MTLRenderPipelineState? {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }
        return pipelineStates[key]
    }

    private func storePipelineState(
        _ pipelineState: MTLRenderPipelineState,
        for key: PipelineStateKey
    ) -> MTLRenderPipelineState {
        executorStateLock.lock()
        defer { executorStateLock.unlock() }

        if let existingPipelineState = pipelineStates[key] {
            return existingPipelineState
        }

        pipelineStates[key] = pipelineState
        return pipelineState
    }

    private func uniforms(
        input: SourceCompositeInput,
        sourceTexture: MTLTexture,
        outputTexture: MTLTexture,
        workingColorSpace: MediaColorSpace,
        outputColorSpace: MediaColorSpace
    ) -> AjarCompositeUniforms {
        let transform = input.transform
        let effects = input.effects
        let chromaKey = effects.chromaKey
        let lumaKey = effects.lumaKey
        let colorCorrection = colorCorrectionUniforms(effects.colorCorrection)
        let masks = maskUniforms(effects.masks)
        let effectiveOpacity = clamp01(floatValue(transform.opacity))
            * clamp01(floatValue(input.trackOpacity))
        return AjarCompositeUniforms(
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
            opacity: effectiveOpacity,
            flipHorizontal: transform.flip.horizontal ? 1 : 0,
            flipVertical: transform.flip.vertical ? 1 : 0,
            blendMode: blendModeValue(
                effectiveBlendMode(
                    clipBlendMode: transform.blendMode,
                    trackBlendMode: input.trackBlendMode
                )
            ),
            sourceTransfer: colorTransferValue(input.sourceColorSpace),
            sourcePrimaries: colorPrimariesValue(input.sourceColorSpace),
            sourceIsLinearWorking: input.sourceIsLinearWorking ? 1 : 0,
            workingPrimaries: colorPrimariesValue(workingColorSpace),
            outputTransfer: colorTransferValue(outputColorSpace),
            chromaKeyColorAndTolerance: chromaKeyColorAndTolerance(chromaKey),
            chromaKeyControls: chromaKeyControls(chromaKey),
            chromaKeyMode: chromaKey.viewMatte ? 1 : 0,
            chromaKeyPadding0: 0,
            chromaKeyPadding1: 0,
            chromaKeyPadding2: 0,
            lumaKeyThresholds: lumaKeyThresholds(lumaKey),
            lumaKeyControls: lumaKeyControls(lumaKey),
            colorCorrectionControls: colorCorrection.controls,
            colorCorrectionWhiteBalance: colorCorrection.whiteBalance,
            colorCorrectionLift: colorCorrection.lift,
            colorCorrectionGamma: colorCorrection.gamma,
            colorCorrectionGain: colorCorrection.gain,
            maskCount: UInt32(min(effects.masks.count, ClipMaskLimits.maximumMasksPerClip)),
            maskPadding0: 0,
            maskPadding1: 0,
            maskPadding2: 0,
            mask0: masks[0],
            mask1: masks[1],
            mask2: masks[2],
            mask3: masks[3]
        )
    }

    private func chromaKeyColorAndTolerance(_ key: ClipChromaKeySettings) -> SIMD4<Float> {
        SIMD4<Float>(
            clamp01(floatValue(key.keyColor.red)),
            clamp01(floatValue(key.keyColor.green)),
            clamp01(floatValue(key.keyColor.blue)),
            clamp01(floatValue(key.tolerance))
        )
    }

    private func chromaKeyControls(_ key: ClipChromaKeySettings) -> SIMD4<Float> {
        SIMD4<Float>(
            key.enabled ? 1.0 : 0.0,
            clamp01(floatValue(key.edgeSoftness)),
            clamp01(floatValue(key.spillSuppression)),
            clamp01(floatValue(key.choke))
        )
    }

    private func lumaKeyThresholds(_ key: ClipLumaKeySettings) -> SIMD4<Float> {
        SIMD4<Float>(
            clamp01(floatValue(key.lowThreshold)),
            clamp01(floatValue(key.highThreshold)),
            clamp01(floatValue(key.softness)),
            0
        )
    }

    private func lumaKeyControls(_ key: ClipLumaKeySettings) -> SIMD4<Float> {
        SIMD4<Float>(
            key.enabled ? 1.0 : 0.0,
            key.invert ? 1.0 : 0.0,
            0,
            0
        )
    }

    private func colorCorrectionUniforms(
        _ correction: ClipColorCorrection
    ) -> AjarColorCorrectionUniforms {
        AjarColorCorrectionUniforms(
            controls: SIMD4<Float>(
                clamp(floatValue(correction.exposure), minimum: -10, maximum: 10),
                clamp(floatValue(correction.contrast), minimum: 0, maximum: 4),
                clamp(floatValue(correction.saturation), minimum: 0, maximum: 4),
                clamp(floatValue(correction.vibrance), minimum: -1, maximum: 1)
            ),
            whiteBalance: SIMD4<Float>(
                clamp(floatValue(correction.temperature), minimum: -1, maximum: 1),
                clamp(floatValue(correction.tint), minimum: -1, maximum: 1),
                0,
                0
            ),
            lift: colorCorrectionChannels(correction.lift, minimum: -1, maximum: 1),
            gamma: colorCorrectionChannels(correction.gamma, minimum: 0.01, maximum: 4),
            gain: colorCorrectionChannels(correction.gain, minimum: 0, maximum: 4)
        )
    }

    private func colorCorrectionChannels(
        _ channels: ClipColorChannels,
        minimum: Float,
        maximum: Float
    ) -> SIMD4<Float> {
        SIMD4<Float>(
            clamp(floatValue(channels.red), minimum: minimum, maximum: maximum),
            clamp(floatValue(channels.green), minimum: minimum, maximum: maximum),
            clamp(floatValue(channels.blue), minimum: minimum, maximum: maximum),
            0
        )
    }

    private func maskUniforms(_ masks: [ClipMask]) -> [AjarMaskUniform] {
        var uniforms = Array(
            repeating: AjarMaskUniform.empty,
            count: ClipMaskLimits.maximumMasksPerClip
        )
        for (index, mask) in masks.prefix(ClipMaskLimits.maximumMasksPerClip).enumerated() {
            uniforms[index] = maskUniform(mask)
        }
        return uniforms
    }

    private func maskUniform(_ mask: ClipMask) -> AjarMaskUniform {
        let shape = maskShapeUniform(mask.shape)
        return AjarMaskUniform(
            shapeKind: shape.kind,
            combineMode: maskCombineMode(mask.combine),
            invert: mask.invert ? 1 : 0,
            pointCount: shape.pointCount,
            featherRadius: max(floatValue(mask.featherRadius), 0),
            maskPadding0: 0,
            maskPadding1: 0,
            maskPadding2: 0,
            params0: shape.params0,
            points0: shape.points0,
            points1: shape.points1,
            points2: shape.points2,
            points3: shape.points3
        )
    }

    private struct MaskShapeUniform {
        let kind: UInt32
        let pointCount: UInt32
        let params0: SIMD4<Float>
        let points0: SIMD4<Float>
        let points1: SIMD4<Float>
        let points2: SIMD4<Float>
        let points3: SIMD4<Float>
    }

    private func maskShapeUniform(_ shape: ClipMaskShape) -> MaskShapeUniform {
        switch shape {
        case .rectangle(let rectangle):
            let minX = floatValue(rectangle.x)
            let minY = floatValue(rectangle.y)
            return MaskShapeUniform(
                kind: 1,
                pointCount: 0,
                params0: SIMD4<Float>(
                    minX,
                    minY,
                    minX + floatValue(rectangle.width),
                    minY + floatValue(rectangle.height)
                ),
                points0: .zero,
                points1: .zero,
                points2: .zero,
                points3: .zero
            )
        case .ellipse(let ellipse):
            return MaskShapeUniform(
                kind: 2,
                pointCount: 0,
                params0: SIMD4<Float>(
                    floatValue(ellipse.centerX),
                    floatValue(ellipse.centerY),
                    floatValue(ellipse.radiusX),
                    floatValue(ellipse.radiusY)
                ),
                points0: .zero,
                points1: .zero,
                points2: .zero,
                points3: .zero
            )
        case .polygon(let polygon):
            let points = polygon.points.prefix(ClipMaskLimits.maximumPolygonPointCount)
                .map(simdPoint)
            return MaskShapeUniform(
                kind: 3,
                pointCount: UInt32(points.count),
                params0: .zero,
                points0: packedPoints(points, offset: 0),
                points1: packedPoints(points, offset: 2),
                points2: packedPoints(points, offset: 4),
                points3: packedPoints(points, offset: 6)
            )
        }
    }

    private func packedPoints(_ points: [SIMD2<Float>], offset: Int) -> SIMD4<Float> {
        let first = point(points, at: offset)
        let second = point(points, at: offset + 1)
        return SIMD4<Float>(first.x, first.y, second.x, second.y)
    }

    private func point(_ points: [SIMD2<Float>], at index: Int) -> SIMD2<Float> {
        guard points.indices.contains(index) else {
            return .zero
        }
        return points[index]
    }

    private func maskCombineMode(_ operation: ClipMaskCombineOperation) -> UInt32 {
        switch operation {
        case .add:
            return 0
        case .subtract:
            return 1
        case .intersect:
            return 2
        }
    }

    private func presentUniforms(composite: RenderCompositeNode) -> AjarPresentUniforms {
        AjarPresentUniforms(
            workingPrimaries: colorPrimariesValue(composite.workingColorSpace),
            outputTransfer: colorTransferValue(composite.outputColorSpace),
            outputPrimaries: colorPrimariesValue(composite.outputColorSpace),
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

    private func clamp(_ value: Float, minimum: Float, maximum: Float) -> Float {
        min(max(value, minimum), maximum)
    }

    private func effectiveBlendMode(
        clipBlendMode: ClipBlendMode,
        trackBlendMode: ClipBlendMode
    ) -> ClipBlendMode {
        // Tracks are currently validated as non-overlapping, so at most one clip per track can be
        // active at a time. That makes flattening directly into one accumulation texture exact:
        // track opacity multiplies clip opacity, and a non-normal track blend mode intentionally
        // overrides the clip blend mode. When transitions or intra-track overlap land, this must
        // become per-track isolation first, then track-over-track compositing.
        trackBlendMode == .normal ? clipBlendMode : trackBlendMode
    }

    private func blendModeValue(_ blendMode: ClipBlendMode) -> UInt32 {
        Self.blendModeValues[blendMode] ?? 0
    }

    private func colorTransferValue(_ colorSpace: MediaColorSpace) -> UInt32 {
        switch colorSpace {
        case .sRGB, .displayP3:
            return 0
        case .rec709, .rec2020, .unspecified, .unknown:
            return 1
        }
    }

    private func colorPrimariesValue(_ colorSpace: MediaColorSpace) -> UInt32 {
        switch colorSpace {
        case .displayP3:
            return 1
        case .rec2020:
            return 2
        case .rec709, .sRGB, .unspecified, .unknown:
            return 0
        }
    }

    private struct PipelineStateKey: Hashable {
        let fragmentFunctionName: String
        let pixelFormatRawValue: UInt
    }

    static var compositeUniformLayout: AjarCompositeUniformLayout {
        AjarCompositeUniformLayout(
            stride: MemoryLayout<AjarCompositeUniforms>.stride,
            alignment: MemoryLayout<AjarCompositeUniforms>.alignment,
            maskStride: MemoryLayout<AjarMaskUniform>.stride,
            outputSize: MemoryLayout<AjarCompositeUniforms>.offset(of: \.outputSize) ?? -1,
            sourceSize: MemoryLayout<AjarCompositeUniforms>.offset(of: \.sourceSize) ?? -1,
            position: MemoryLayout<AjarCompositeUniforms>.offset(of: \.position) ?? -1,
            scale: MemoryLayout<AjarCompositeUniforms>.offset(of: \.scale) ?? -1,
            anchorPoint: MemoryLayout<AjarCompositeUniforms>.offset(of: \.anchorPoint) ?? -1,
            crop: MemoryLayout<AjarCompositeUniforms>.offset(of: \.crop) ?? -1,
            rotationRadians: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.rotationRadians) ?? -1,
            opacity: MemoryLayout<AjarCompositeUniforms>.offset(of: \.opacity) ?? -1,
            flipHorizontal: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.flipHorizontal) ?? -1,
            flipVertical: MemoryLayout<AjarCompositeUniforms>.offset(of: \.flipVertical) ?? -1,
            blendMode: MemoryLayout<AjarCompositeUniforms>.offset(of: \.blendMode) ?? -1,
            sourceTransfer: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.sourceTransfer) ?? -1,
            sourcePrimaries: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.sourcePrimaries) ?? -1,
            sourceIsLinearWorking: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.sourceIsLinearWorking) ?? -1,
            workingPrimaries: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.workingPrimaries) ?? -1,
            outputTransfer: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.outputTransfer) ?? -1,
            chromaKeyColorAndTolerance: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.chromaKeyColorAndTolerance) ?? -1,
            chromaKeyControls: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.chromaKeyControls) ?? -1,
            chromaKeyMode: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.chromaKeyMode) ?? -1,
            chromaKeyPadding0: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.chromaKeyPadding0) ?? -1,
            chromaKeyPadding1: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.chromaKeyPadding1) ?? -1,
            chromaKeyPadding2: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.chromaKeyPadding2) ?? -1,
            lumaKeyThresholds: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.lumaKeyThresholds) ?? -1,
            lumaKeyControls: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.lumaKeyControls) ?? -1,
            colorCorrectionControls: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.colorCorrectionControls) ?? -1,
            colorCorrectionWhiteBalance: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.colorCorrectionWhiteBalance) ?? -1,
            colorCorrectionLift: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.colorCorrectionLift) ?? -1,
            colorCorrectionGamma: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.colorCorrectionGamma) ?? -1,
            colorCorrectionGain: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.colorCorrectionGain) ?? -1,
            maskCount: MemoryLayout<AjarCompositeUniforms>.offset(of: \.maskCount) ?? -1,
            maskPadding0: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.maskPadding0) ?? -1,
            maskPadding1: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.maskPadding1) ?? -1,
            maskPadding2: MemoryLayout<AjarCompositeUniforms>
                .offset(of: \.maskPadding2) ?? -1,
            mask0: MemoryLayout<AjarCompositeUniforms>.offset(of: \.mask0) ?? -1,
            mask1: MemoryLayout<AjarCompositeUniforms>.offset(of: \.mask1) ?? -1,
            mask2: MemoryLayout<AjarCompositeUniforms>.offset(of: \.mask2) ?? -1,
            mask3: MemoryLayout<AjarCompositeUniforms>.offset(of: \.mask3) ?? -1
        )
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
        var sourceTransfer: UInt32
        var sourcePrimaries: UInt32
        var sourceIsLinearWorking: UInt32
        var workingPrimaries: UInt32
        var outputTransfer: UInt32
        var chromaKeyColorAndTolerance: SIMD4<Float>
        var chromaKeyControls: SIMD4<Float>
        var chromaKeyMode: UInt32
        var chromaKeyPadding0: UInt32
        var chromaKeyPadding1: UInt32
        var chromaKeyPadding2: UInt32
        var lumaKeyThresholds: SIMD4<Float>
        var lumaKeyControls: SIMD4<Float>
        var colorCorrectionControls: SIMD4<Float>
        var colorCorrectionWhiteBalance: SIMD4<Float>
        var colorCorrectionLift: SIMD4<Float>
        var colorCorrectionGamma: SIMD4<Float>
        var colorCorrectionGain: SIMD4<Float>
        var maskCount: UInt32
        var maskPadding0: UInt32
        var maskPadding1: UInt32
        var maskPadding2: UInt32
        var mask0: AjarMaskUniform
        var mask1: AjarMaskUniform
        var mask2: AjarMaskUniform
        var mask3: AjarMaskUniform
    }

    private struct AjarColorCorrectionUniforms {
        var controls: SIMD4<Float>
        var whiteBalance: SIMD4<Float>
        var lift: SIMD4<Float>
        var gamma: SIMD4<Float>
        var gain: SIMD4<Float>
    }

    private struct AjarMaskUniform {
        var shapeKind: UInt32
        var combineMode: UInt32
        var invert: UInt32
        var pointCount: UInt32
        var featherRadius: Float
        var maskPadding0: Float
        var maskPadding1: Float
        var maskPadding2: Float
        var params0: SIMD4<Float>
        var points0: SIMD4<Float>
        var points1: SIMD4<Float>
        var points2: SIMD4<Float>
        var points3: SIMD4<Float>

        static let empty = AjarMaskUniform(
            shapeKind: 0,
            combineMode: 0,
            invert: 0,
            pointCount: 0,
            featherRadius: 0,
            maskPadding0: 0,
            maskPadding1: 0,
            maskPadding2: 0,
            params0: .zero,
            points0: .zero,
            points1: .zero,
            points2: .zero,
            points3: .zero
        )
    }

    private struct AjarPresentUniforms {
        var workingPrimaries: UInt32
        var outputTransfer: UInt32
        var outputPrimaries: UInt32
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

        struct AjarMaskUniform {
            uint shapeKind;
            uint combineMode;
            uint invert;
            uint pointCount;
            float featherRadius;
            float maskPadding0;
            float maskPadding1;
            float maskPadding2;
            float4 params0;
            float4 points0;
            float4 points1;
            float4 points2;
            float4 points3;
        };

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
            uint sourceTransfer;
            uint sourcePrimaries;
            uint sourceIsLinearWorking;
            uint workingPrimaries;
            uint outputTransfer;
            float4 chromaKeyColorAndTolerance;
            float4 chromaKeyControls;
            uint chromaKeyMode;
            uint chromaKeyPadding0;
            uint chromaKeyPadding1;
            uint chromaKeyPadding2;
            float4 lumaKeyThresholds;
            float4 lumaKeyControls;
            float4 colorCorrectionControls;
            float4 colorCorrectionWhiteBalance;
            float4 colorCorrectionLift;
            float4 colorCorrectionGamma;
            float4 colorCorrectionGain;
            uint maskCount;
            uint maskPadding0;
            uint maskPadding1;
            uint maskPadding2;
            AjarMaskUniform mask0;
            AjarMaskUniform mask1;
            AjarMaskUniform mask2;
            AjarMaskUniform mask3;
        };

        struct AjarPresentUniforms {
            uint workingPrimaries;
            uint outputTransfer;
            uint outputPrimaries;
            uint padding;
        };

        static float3 ajar_decode_srgb(float3 value) {
            return select(
                pow((value + 0.055) / 1.055, float3(2.4)),
                value / 12.92,
                value <= 0.04045
            );
        }

        static float3 ajar_encode_srgb(float3 value) {
            return select(
                (1.055 * pow(value, float3(1.0 / 2.4))) - 0.055,
                value * 12.92,
                value <= 0.0031308
            );
        }

        static float3 ajar_decode_rec709(float3 value) {
            return select(
                pow((value + 0.099) / 1.099, float3(1.0 / 0.45)),
                value / 4.5,
                value < 0.081
            );
        }

        static float3 ajar_encode_rec709(float3 value) {
            return select(
                (1.099 * pow(value, float3(0.45))) - 0.099,
                value * 4.5,
                value < 0.018
            );
        }

        static float3 ajar_decode_transfer(float3 value, uint transfer) {
            if (transfer == 0) {
                return ajar_decode_srgb(value);
            }
            return ajar_decode_rec709(value);
        }

        static float3 ajar_encode_transfer(float3 value, uint transfer) {
            if (transfer == 0) {
                return ajar_encode_srgb(value);
            }
            return ajar_encode_rec709(value);
        }

        static float3 ajar_rgb_to_xyz(float3 rgb, uint primaries) {
            if (primaries == 1) {
                return float3(
                    (0.4865709 * rgb.r) + (0.2656677 * rgb.g) + (0.1982173 * rgb.b),
                    (0.2289746 * rgb.r) + (0.6917385 * rgb.g) + (0.0792869 * rgb.b),
                    (0.0000000 * rgb.r) + (0.0451134 * rgb.g) + (1.0439444 * rgb.b)
                );
            }
            if (primaries == 2) {
                return float3(
                    (0.6369580 * rgb.r) + (0.1446169 * rgb.g) + (0.1688809 * rgb.b),
                    (0.2627002 * rgb.r) + (0.6779981 * rgb.g) + (0.0593017 * rgb.b),
                    (0.0000000 * rgb.r) + (0.0280727 * rgb.g) + (1.0609851 * rgb.b)
                );
            }
            return float3(
                (0.4124564 * rgb.r) + (0.3575761 * rgb.g) + (0.1804375 * rgb.b),
                (0.2126729 * rgb.r) + (0.7151522 * rgb.g) + (0.0721750 * rgb.b),
                (0.0193339 * rgb.r) + (0.1191920 * rgb.g) + (0.9503041 * rgb.b)
            );
        }

        static float3 ajar_xyz_to_rgb(float3 xyz, uint primaries) {
            if (primaries == 1) {
                return float3(
                    (2.4934969 * xyz.x) + (-0.9313836 * xyz.y) + (-0.4027108 * xyz.z),
                    (-0.8294890 * xyz.x) + (1.7626640 * xyz.y) + (0.0236247 * xyz.z),
                    (0.0358458 * xyz.x) + (-0.0761724 * xyz.y) + (0.9568845 * xyz.z)
                );
            }
            if (primaries == 2) {
                return float3(
                    (1.7166512 * xyz.x) + (-0.3556708 * xyz.y) + (-0.2533663 * xyz.z),
                    (-0.6666844 * xyz.x) + (1.6164812 * xyz.y) + (0.0157685 * xyz.z),
                    (0.0176399 * xyz.x) + (-0.0427706 * xyz.y) + (0.9421031 * xyz.z)
                );
            }
            return float3(
                (3.2404542 * xyz.x) + (-1.5371385 * xyz.y) + (-0.4985314 * xyz.z),
                (-0.9692660 * xyz.x) + (1.8760108 * xyz.y) + (0.0415560 * xyz.z),
                (0.0556434 * xyz.x) + (-0.2040259 * xyz.y) + (1.0572252 * xyz.z)
            );
        }

        static float3 ajar_convert_primaries(
            float3 rgb,
            uint sourcePrimaries,
            uint targetPrimaries
        ) {
            if (sourcePrimaries == targetPrimaries) {
                return rgb;
            }
            return ajar_xyz_to_rgb(ajar_rgb_to_xyz(rgb, sourcePrimaries), targetPrimaries);
        }

        static float3 ajar_source_to_working_linear(
            float3 encoded,
            constant AjarCompositeUniforms &uniforms
        ) {
            float3 sourceLinear = ajar_decode_transfer(saturate(encoded), uniforms.sourceTransfer);
            return ajar_convert_primaries(
                sourceLinear,
                uniforms.sourcePrimaries,
                uniforms.workingPrimaries
            );
        }

        static float3 ajar_source_sample_to_working_linear(
            float3 straightSource,
            constant AjarCompositeUniforms &uniforms
        ) {
            if (uniforms.sourceIsLinearWorking != 0) {
                return ajar_convert_primaries(
                    straightSource,
                    uniforms.sourcePrimaries,
                    uniforms.workingPrimaries
                );
            }
            return ajar_source_to_working_linear(straightSource, uniforms);
        }

        static float3 ajar_unpremultiply(float4 color) {
            if (color.a <= 0.00001) {
                return float3(0.0);
            }
            return color.rgb / color.a;
        }

        static float ajar_blend_lum(float3 color) {
            // ADR-0010 keeps blending in Rec.709 linear light, so these are Rec.709 luma
            // coefficients rather than the W3C gamma-space 0.3/0.59/0.11 blend weights.
            return dot(color, float3(0.2126, 0.7152, 0.0722));
        }

        static float ajar_blend_sat(float3 color) {
            return max(max(color.r, color.g), color.b) - min(min(color.r, color.g), color.b);
        }

        static float3 ajar_blend_clip_color(float3 color) {
            float lum = ajar_blend_lum(color);
            float minColor = min(min(color.r, color.g), color.b);
            float maxColor = max(max(color.r, color.g), color.b);
            if (minColor < 0.0) {
                color = lum + (((color - lum) * lum) / max(lum - minColor, 0.00001));
            }
            if (maxColor > 1.0) {
                color = lum + (((color - lum) * (1.0 - lum)) / max(maxColor - lum, 0.00001));
            }
            return saturate(color);
        }

        static float3 ajar_blend_set_lum(float3 color, float lum) {
            return ajar_blend_clip_color(color + (lum - ajar_blend_lum(color)));
        }

        static float3 ajar_blend_set_sat(float3 color, float sat) {
            float minColor = min(min(color.r, color.g), color.b);
            float maxColor = max(max(color.r, color.g), color.b);
            if (maxColor <= minColor) {
                return float3(0.0);
            }
            return (color - minColor) * (sat / (maxColor - minColor));
        }

        static float ajar_soft_light_component(float source, float destination) {
            if (source <= 0.5) {
                return destination - ((1.0 - (2.0 * source)) * destination * (1.0 - destination));
            }

            float curve = destination <= 0.25
                ? (((16.0 * destination) - 12.0) * destination + 4.0) * destination
                : sqrt(destination);
            return destination + (((2.0 * source) - 1.0) * (curve - destination));
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
            case 7:
                return select(
                    min(destination / max(1.0 - source, 0.00001), 1.0),
                    float3(1.0),
                    source >= 1.0
                );
            case 8:
                return select(
                    1.0 - min((1.0 - destination) / max(source, 0.00001), 1.0),
                    float3(0.0),
                    source <= 0.0
                );
            case 9:
                return select(
                    1.0 - (2.0 * (1.0 - source) * (1.0 - destination)),
                    2.0 * source * destination,
                    source <= 0.5
                );
            case 10:
                return float3(
                    ajar_soft_light_component(source.r, destination.r),
                    ajar_soft_light_component(source.g, destination.g),
                    ajar_soft_light_component(source.b, destination.b)
                );
            case 11:
                return abs(destination - source);
            case 12:
                return destination + source - (2.0 * destination * source);
            case 13:
                return max(destination - source, 0.0);
            case 14:
                return ajar_blend_set_lum(
                    ajar_blend_set_sat(source, ajar_blend_sat(destination)),
                    ajar_blend_lum(destination)
                );
            case 15:
                return ajar_blend_set_lum(
                    ajar_blend_set_sat(destination, ajar_blend_sat(source)),
                    ajar_blend_lum(destination)
                );
            case 16:
                return ajar_blend_set_lum(source, ajar_blend_lum(destination));
            case 17:
                return ajar_blend_set_lum(destination, ajar_blend_lum(source));
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

            // Blend formulas require straight linear RGB; `ajar_composite` re-premultiplies.
            float3 sourceStraight = source.rgb / sourceAlpha;
            float3 destinationStraight = ajar_unpremultiply(destination);
            float3 blended = ajar_blend_color(blendMode, sourceStraight, destinationStraight);
            float3 outputRGB = (blended * sourceAlpha * destinationAlpha)
                + (source.rgb * (1.0 - destinationAlpha))
                + (destination.rgb * (1.0 - sourceAlpha));
            return saturate(float4(outputRGB, outputAlpha));
        }

        static float ajar_key_alpha(float distance, float tolerance, float edgeSoftness) {
            float width = max(edgeSoftness, 0.0001);
            float alpha = saturate((distance - tolerance) / width);
            return alpha * alpha * (3.0 - (2.0 * alpha));
        }

        static float3 ajar_chroma_key_color(
            constant AjarCompositeUniforms &uniforms
        ) {
            float3 encoded = uniforms.chromaKeyColorAndTolerance.rgb;
            return ajar_source_to_working_linear(encoded, uniforms);
        }

        static float2 ajar_normalized_chroma(float3 color) {
            // The keyer compares normalized chroma so green-screen brightness changes do not
            // move the matte. Near-black noisy pixels can still normalize to saturated chroma,
            // so callers should denoise or lift crushed footage before keying/de-spill.
            constexpr float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
            float3 nonnegative = max(color, float3(0.0));
            float chromaSum = max(nonnegative.r + nonnegative.g + nonnegative.b, 0.0001);
            float3 chromaticity = nonnegative / chromaSum;
            float luma = dot(chromaticity, lumaWeights);
            return float2(
                (chromaticity.b - luma) / 1.8556,
                (chromaticity.r - luma) / 1.5748
            );
        }

        static float ajar_chroma_distance(float3 sourceLinear, float3 keyColor) {
            return distance(
                ajar_normalized_chroma(sourceLinear),
                ajar_normalized_chroma(keyColor)
            );
        }

        static float3 ajar_sample_source_linear(
            texture2d<float> sourceTexture,
            sampler sourceSampler,
            float2 sourceUV,
            constant AjarCompositeUniforms &uniforms
        ) {
            float4 sampledSource = sourceTexture.sample(sourceSampler, sourceUV);
            float sourceTextureAlpha = saturate(sampledSource.a);
            float3 straightSource = sourceTextureAlpha > 0.00001
                ? sampledSource.rgb / sourceTextureAlpha
                : float3(0.0);
            return ajar_source_sample_to_working_linear(straightSource, uniforms);
        }

        static float ajar_chroma_base_alpha(
            float3 sourceLinear,
            float3 keyColor,
            constant AjarCompositeUniforms &uniforms
        ) {
            if (uniforms.chromaKeyControls.x <= 0.0) {
                return 1.0;
            }

            float distanceFromKey = ajar_chroma_distance(sourceLinear, keyColor);
            return ajar_key_alpha(
                distanceFromKey,
                uniforms.chromaKeyColorAndTolerance.a,
                uniforms.chromaKeyControls.y
            );
        }

        static float ajar_chroma_matte_alpha(
            texture2d<float> sourceTexture,
            sampler sourceSampler,
            float2 sourceUV,
            float3 sourceLinear,
            float3 keyColor,
            constant AjarCompositeUniforms &uniforms
        ) {
            float alpha = ajar_chroma_base_alpha(sourceLinear, keyColor, uniforms);
            float choke = saturate(uniforms.chromaKeyControls.w);
            if (uniforms.chromaKeyControls.x <= 0.0 || choke <= 0.0) {
                return alpha;
            }

            float2 texel = 1.0 / max(uniforms.sourceSize, float2(1.0));
            float erodedAlpha = alpha;
            // Off-frame samples are treated as background, so foreground touching the source
            // border erodes inward under choke instead of clamping an opaque edge.
            for (int yOffset = -1; yOffset <= 1; yOffset++) {
                for (int xOffset = -1; xOffset <= 1; xOffset++) {
                    float2 neighborUV = sourceUV + (float2(xOffset, yOffset) * texel);
                    float neighborAlpha = 0.0;
                    if (neighborUV.x >= 0.0 && neighborUV.y >= 0.0
                        && neighborUV.x <= 1.0 && neighborUV.y <= 1.0) {
                        float3 neighborLinear = ajar_sample_source_linear(
                            sourceTexture,
                            sourceSampler,
                            neighborUV,
                            uniforms
                        );
                        neighborAlpha = ajar_chroma_base_alpha(
                            neighborLinear,
                            keyColor,
                            uniforms
                        );
                    }
                    erodedAlpha = min(erodedAlpha, neighborAlpha);
                }
            }

            return mix(alpha, erodedAlpha, choke);
        }

        static float3 ajar_matte_preview_linear(
            float alpha,
            constant AjarCompositeUniforms &uniforms
        ) {
            return ajar_decode_transfer(float3(saturate(alpha)), uniforms.outputTransfer);
        }

        static float ajar_luma_matte_alpha(
            float3 sourceLinear,
            constant AjarCompositeUniforms &uniforms
        ) {
            if (uniforms.lumaKeyControls.x <= 0.0) {
                return 1.0;
            }

            constexpr float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
            float lowThreshold = saturate(uniforms.lumaKeyThresholds.x);
            float highThreshold = max(lowThreshold, saturate(uniforms.lumaKeyThresholds.y));
            float softness = saturate(uniforms.lumaKeyThresholds.z);
            float luma = dot(saturate(sourceLinear), lumaWeights);
            float outsideDistance = max(lowThreshold - luma, luma - highThreshold);
            float alpha = outsideDistance > 0.0 ? 1.0 : 0.0;
            if (softness > 0.0 && outsideDistance > 0.0) {
                alpha = smoothstep(0.0, softness, outsideDistance);
            }
            if (uniforms.lumaKeyControls.y > 0.0) {
                alpha = 1.0 - alpha;
            }
            return saturate(alpha);
        }

        static float3 ajar_despill(
            float3 sourceLinear,
            float3 keyColor,
            float amount
        ) {
            if (amount <= 0.0) {
                return sourceLinear;
            }

            float3 result = sourceLinear;
            if (keyColor.g >= keyColor.r && keyColor.g >= keyColor.b) {
                float replacement = max(result.r, result.b);
                result.g = mix(result.g, min(result.g, replacement), amount);
                return result;
            }
            if (keyColor.b >= keyColor.r && keyColor.b >= keyColor.g) {
                float replacement = max(result.r, result.g);
                result.b = mix(result.b, min(result.b, replacement), amount);
                return result;
            }

            float replacement = max(result.g, result.b);
            result.r = mix(result.r, min(result.r, replacement), amount);
            return result;
        }

        static float3 ajar_apply_color_correction(
            float3 sourceLinear,
            constant AjarCompositeUniforms &uniforms
        ) {
            float exposure = uniforms.colorCorrectionControls.x;
            float contrast = uniforms.colorCorrectionControls.y;
            float saturation = uniforms.colorCorrectionControls.z;
            float vibrance = uniforms.colorCorrectionControls.w;
            float temperature = uniforms.colorCorrectionWhiteBalance.x;
            float tint = uniforms.colorCorrectionWhiteBalance.y;

            float3 result = max(sourceLinear, float3(0.0));
            // FR-COL-001 grading order is intentional and golden-tested:
            // exposure, lift, gamma, gain, contrast, white balance, saturation, vibrance.
            // White balance currently uses a bounded linear-light channel adaptation
            // rather than a full chromatic-adaptation transform, so later grading work
            // can replace this block without ambiguity about where it belongs.
            result *= exp2(exposure);
            result = max(result + uniforms.colorCorrectionLift.rgb, float3(0.0));
            result = pow(
                max(result, float3(0.0)),
                1.0 / max(uniforms.colorCorrectionGamma.rgb, float3(0.01))
            );
            result *= max(uniforms.colorCorrectionGain.rgb, float3(0.0));

            constexpr float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
            result = max(((result - 0.18) * contrast) + 0.18, float3(0.0));

            float warm = max(temperature, 0.0);
            float cool = max(-temperature, 0.0);
            float3 temperatureScale = float3(
                1.0 + (warm * 0.20) - (cool * 0.10),
                1.0,
                1.0 - (warm * 0.10) + (cool * 0.20)
            );
            float magenta = max(tint, 0.0);
            float green = max(-tint, 0.0);
            float3 tintScale = float3(
                1.0 + (magenta * 0.08),
                1.0 + (green * 0.10) - (magenta * 0.08),
                1.0 + (magenta * 0.08)
            );
            result *= max(temperatureScale * tintScale, float3(0.0));

            float luma = dot(result, lumaWeights);
            result = mix(float3(luma), result, saturation);
            float chroma = max(result.r, max(result.g, result.b))
                - min(result.r, min(result.g, result.b));
            float vibranceSaturation = 1.0 + (vibrance * (1.0 - saturate(chroma)));
            result = mix(float3(luma), result, vibranceSaturation);
            return max(result, float3(0.0));
        }

        static AjarMaskUniform ajar_mask_at(
            constant AjarCompositeUniforms &uniforms,
            uint index
        ) {
            switch (index) {
            case 0:
                return uniforms.mask0;
            case 1:
                return uniforms.mask1;
            case 2:
                return uniforms.mask2;
            default:
                return uniforms.mask3;
            }
        }

        static float2 ajar_mask_point(AjarMaskUniform mask, uint index) {
            switch (index / 2) {
            case 0:
                return index % 2 == 0 ? mask.points0.xy : mask.points0.zw;
            case 1:
                return index % 2 == 0 ? mask.points1.xy : mask.points1.zw;
            case 2:
                return index % 2 == 0 ? mask.points2.xy : mask.points2.zw;
            default:
                return index % 2 == 0 ? mask.points3.xy : mask.points3.zw;
            }
        }

        static float ajar_feathered_alpha(float signedDistance, float feather) {
            if (feather <= 0.0) {
                return signedDistance >= 0.0 ? 1.0 : 0.0;
            }
            return smoothstep(-feather, feather, signedDistance);
        }

        static float ajar_rectangle_mask_alpha(float2 localPoint, AjarMaskUniform mask) {
            float2 minPoint = mask.params0.xy;
            float2 maxPoint = mask.params0.zw;
            float2 halfSize = max((maxPoint - minPoint) * 0.5, float2(0.0));
            float2 center = (minPoint + maxPoint) * 0.5;
            float2 q = abs(localPoint - center) - halfSize;
            float outsideDistance = length(max(q, float2(0.0)));
            float insideDistance = min(max(q.x, q.y), 0.0);
            float signedDistance = -(outsideDistance + insideDistance);
            return ajar_feathered_alpha(signedDistance, mask.featherRadius);
        }

        static float ajar_ellipse_mask_alpha(float2 localPoint, AjarMaskUniform mask) {
            float2 center = mask.params0.xy;
            float2 radius = max(mask.params0.zw, float2(0.0001));
            float normalizedDistance = length((localPoint - center) / radius);
            float signedDistance = (1.0 - normalizedDistance) * min(radius.x, radius.y);
            return ajar_feathered_alpha(signedDistance, mask.featherRadius);
        }

        static float ajar_segment_distance(float2 point, float2 first, float2 second) {
            float2 segment = second - first;
            float denominator = max(dot(segment, segment), 0.0001);
            float t = saturate(dot(point - first, segment) / denominator);
            return length(point - (first + (segment * t)));
        }

        static float ajar_polygon_mask_alpha(float2 localPoint, AjarMaskUniform mask) {
            if (mask.pointCount < 3) {
                return 0.0;
            }

            bool inside = false;
            float minDistance = 1000000.0;
            float2 previous = ajar_mask_point(mask, mask.pointCount - 1);
            for (uint index = 0; index < mask.pointCount; index++) {
                float2 current = ajar_mask_point(mask, index);
                minDistance = min(
                    minDistance,
                    ajar_segment_distance(localPoint, previous, current)
                );

                bool crosses = ((current.y > localPoint.y) != (previous.y > localPoint.y));
                if (crosses) {
                    float denominator = previous.y - current.y;
                    if (abs(denominator) < 0.0001) {
                        denominator = denominator < 0.0 ? -0.0001 : 0.0001;
                    }
                    float xIntersection = (
                        ((previous.x - current.x) * (localPoint.y - current.y))
                            / denominator
                    ) + current.x;
                    if (localPoint.x < xIntersection) {
                        inside = !inside;
                    }
                }
                previous = current;
            }

            float signedDistance = inside ? minDistance : -minDistance;
            return ajar_feathered_alpha(signedDistance, mask.featherRadius);
        }

        static float ajar_mask_shape_alpha(float2 localPoint, AjarMaskUniform mask) {
            switch (mask.shapeKind) {
            case 1:
                return ajar_rectangle_mask_alpha(localPoint, mask);
            case 2:
                return ajar_ellipse_mask_alpha(localPoint, mask);
            case 3:
                return ajar_polygon_mask_alpha(localPoint, mask);
            default:
                return 0.0;
            }
        }

        static float ajar_masks_matte_alpha(
            float2 localPoint,
            constant AjarCompositeUniforms &uniforms
        ) {
            if (uniforms.maskCount == 0) {
                return 1.0;
            }

            float combined = 0.0;
            uint count = min(uniforms.maskCount, 4u);
            for (uint index = 0; index < count; index++) {
                AjarMaskUniform mask = ajar_mask_at(uniforms, index);
                float alpha = ajar_mask_shape_alpha(localPoint, mask);
                if (mask.invert != 0) {
                    alpha = 1.0 - alpha;
                }

                if (index == 0) {
                    combined = alpha;
                } else if (mask.combineMode == 1) {
                    combined = combined * (1.0 - alpha);
                } else if (mask.combineMode == 2) {
                    combined = min(combined, alpha);
                } else {
                    combined = max(combined, alpha);
                }
            }

            return saturate(combined);
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

            float4 sampledSource = sourceTexture.sample(sourceSampler, sourceUV);
            float sourceTextureAlpha = saturate(sampledSource.a);
            float3 straightSource = sourceTextureAlpha > 0.00001
                ? sampledSource.rgb / sourceTextureAlpha
                : float3(0.0);
            float3 sourceLinear = ajar_source_sample_to_working_linear(straightSource, uniforms);
            float3 keyColor = float3(0.0);
            if (uniforms.chromaKeyControls.x > 0.0) {
                keyColor = ajar_chroma_key_color(uniforms);
            }
            float matteAlpha = ajar_chroma_matte_alpha(
                sourceTexture,
                sourceSampler,
                sourceUV,
                sourceLinear,
                keyColor,
                uniforms
            )
                * ajar_luma_matte_alpha(sourceLinear, uniforms);
            float maskAlpha = ajar_masks_matte_alpha(localPoint, uniforms);
            float combinedMatteAlpha = matteAlpha * maskAlpha;
            if (uniforms.chromaKeyMode != 0) {
                return float4(ajar_matte_preview_linear(combinedMatteAlpha, uniforms), 1.0);
            }

            if (uniforms.chromaKeyControls.x > 0.0) {
                sourceLinear = ajar_despill(
                    sourceLinear,
                    keyColor,
                    uniforms.chromaKeyControls.z
                );
            }
            sourceLinear = ajar_apply_color_correction(sourceLinear, uniforms);

            float sourceAlpha = saturate(
                sourceTextureAlpha * uniforms.opacity * combinedMatteAlpha
            );
            float4 source = float4(sourceLinear * sourceAlpha, sourceAlpha);
            return ajar_composite(source, destination, uniforms.blendMode);
        }

        fragment float4 ajar_present_fragment(
            AjarVertexOut in [[stage_in]],
            texture2d<float> linearTexture [[texture(0)]],
            constant AjarPresentUniforms &uniforms [[buffer(0)]]
        ) {
            constexpr sampler sourceSampler(address::clamp_to_edge, filter::nearest);
            float4 linearColor = linearTexture.sample(sourceSampler, in.uv);
            float alpha = saturate(linearColor.a);
            float3 straightWorking = ajar_unpremultiply(linearColor);
            float3 outputLinear = ajar_convert_primaries(
                straightWorking,
                uniforms.workingPrimaries,
                uniforms.outputPrimaries
            );
            float3 encoded = ajar_encode_transfer(saturate(outputLinear), uniforms.outputTransfer);
            return saturate(float4(encoded * alpha, alpha));
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
