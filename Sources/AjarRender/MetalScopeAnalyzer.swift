// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

import AjarCore
import Foundation
import Metal

/// Histogram channels produced by `MetalScopeAnalyzer`.
public enum MetalScopeHistogramChannel: Int, CaseIterable, Sendable {
    /// Red-channel histogram.
    case red

    /// Green-channel histogram.
    case green

    /// Blue-channel histogram.
    case blue

    /// Rec.709 luma histogram.
    case luma
}

/// RGB channels produced by the RGB parade scope.
public enum MetalScopeRGBChannel: Int, CaseIterable, Sendable {
    /// Red parade lane.
    case red

    /// Green parade lane.
    case green

    /// Blue parade lane.
    case blue
}

/// Fixed FR-COL-003 scope buffer layout shared by the GPU kernels and tests.
public enum MetalScopeLayout {
    /// Number of normalized 8-bit bins used by all scopes.
    public static let binCount = 256

    /// Number of histogram channels: red, green, blue, and luma.
    public static let histogramChannelCount = MetalScopeHistogramChannel.allCases.count

    /// Number of RGB parade lanes.
    public static let rgbParadeChannelCount = MetalScopeRGBChannel.allCases.count

    /// Histogram element count.
    public static let histogramElementCount = histogramChannelCount * binCount

    /// Vectorscope is stored as a 256x256 chroma-density grid.
    public static let vectorscopeElementCount = binCount * binCount

    /// Histogram buffer index for `channel` and `bin`.
    public static func histogramIndex(
        channel: MetalScopeHistogramChannel,
        bin: Int
    ) -> Int {
        (channel.rawValue * binCount) + bin
    }

    /// Waveform buffer index for output column `x` and luma `bin`.
    public static func waveformIndex(x: Int, bin: Int) -> Int {
        (x * binCount) + bin
    }

    /// RGB parade buffer index for `channel`, output column `x`, and channel `bin`.
    public static func rgbParadeIndex(
        channel: MetalScopeRGBChannel,
        x: Int,
        bin: Int,
        width: Int
    ) -> Int {
        ((channel.rawValue * width * binCount) + (x * binCount)) + bin
    }

    /// Vectorscope buffer index for chroma coordinates.
    public static func vectorscopeIndex(x: Int, y: Int) -> Int {
        (y * binCount) + x
    }
}

/// Errors produced by GPU scope analysis.
public enum MetalScopeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A default Metal device could not be created.
    case metalDeviceUnavailable

    /// A command queue could not be created.
    case commandQueueCreationFailed

    /// The embedded Metal shader library could not be compiled.
    case shaderLibraryCreationFailed(String)

    /// A required shader function was not found.
    case shaderFunctionUnavailable(String)

    /// A compute pipeline could not be created.
    case computePipelineCreationFailed(String)

    /// A command buffer could not be created.
    case commandBufferCreationFailed

    /// A command encoder could not be created.
    case commandEncoderCreationFailed

    /// A GPU buffer could not be created.
    case bufferCreationFailed(String)

    /// A GPU texture could not be created.
    case textureCreationFailed(String)

    /// The source texture dimensions are invalid.
    case invalidSourceDimensions(width: Int, height: Int)

    /// Human-readable error message.
    public var description: String {
        switch self {
        case .metalDeviceUnavailable:
            "Metal device unavailable for scope analysis"
        case .commandQueueCreationFailed:
            "Metal command queue creation failed for scope analysis"
        case .shaderLibraryCreationFailed(let message):
            "Metal scope shader library creation failed: \(message)"
        case .shaderFunctionUnavailable(let name):
            "Metal scope shader function unavailable: \(name)"
        case .computePipelineCreationFailed(let message):
            "Metal scope compute pipeline creation failed: \(message)"
        case .commandBufferCreationFailed:
            "Metal scope command buffer creation failed"
        case .commandEncoderCreationFailed:
            "Metal scope command encoder creation failed"
        case .bufferCreationFailed(let label):
            "Metal scope buffer creation failed for \(label)"
        case .textureCreationFailed(let label):
            "Metal scope texture creation failed for \(label)"
        case .invalidSourceDimensions(let width, let height):
            "Metal scope source texture has invalid dimensions \(width)x\(height)"
        }
    }
}

/// GPU-resident result of one FR-COL-003 scope analysis pass.
///
/// The buffers and textures are produced by `commandBuffer`. The analyzer does not wait for
/// completion and does not read data back to the CPU; callers that need CPU-visible data must
/// schedule their own throttled/asynchronous readback outside the playback render hot path.
public struct MetalScopeFrame {
    /// Dimensions of the analyzed source texture.
    public let sourceDimensions: PixelDimensions

    /// Command buffer that writes every buffer and texture in this result.
    public let commandBuffer: MTLCommandBuffer

    /// Four contiguous 256-bin histograms: red, green, blue, and Rec.709 luma.
    public let histogramBuffer: MTLBuffer

    /// Column-wise luma distribution, indexed by `MetalScopeLayout.waveformIndex`.
    public let waveformBuffer: MTLBuffer

    /// Three contiguous column-wise RGB distributions.
    public let rgbParadeBuffer: MTLBuffer

    /// 256x256 Rec.709 chroma density grid.
    public let vectorscopeBuffer: MTLBuffer

    /// Rendered histogram occupancy texture.
    public let histogramTexture: MTLTexture

    /// Rendered waveform occupancy texture.
    public let waveformTexture: MTLTexture

    /// Rendered RGB parade occupancy texture.
    public let rgbParadeTexture: MTLTexture

    /// Rendered vectorscope occupancy texture.
    public let vectorscopeTexture: MTLTexture

    private let completion: RenderCompletion?
    private let resourceLease: AnyObject?

    fileprivate init(
        sourceDimensions: PixelDimensions,
        commandBuffer: MTLCommandBuffer,
        histogramBuffer: MTLBuffer,
        waveformBuffer: MTLBuffer,
        rgbParadeBuffer: MTLBuffer,
        vectorscopeBuffer: MTLBuffer,
        histogramTexture: MTLTexture,
        waveformTexture: MTLTexture,
        rgbParadeTexture: MTLTexture,
        vectorscopeTexture: MTLTexture,
        completion: RenderCompletion?,
        resourceLease: AnyObject?
    ) {
        self.sourceDimensions = sourceDimensions
        self.commandBuffer = commandBuffer
        self.histogramBuffer = histogramBuffer
        self.waveformBuffer = waveformBuffer
        self.rgbParadeBuffer = rgbParadeBuffer
        self.vectorscopeBuffer = vectorscopeBuffer
        self.histogramTexture = histogramTexture
        self.waveformTexture = waveformTexture
        self.rgbParadeTexture = rgbParadeTexture
        self.vectorscopeTexture = vectorscopeTexture
        self.completion = completion
        self.resourceLease = resourceLease
    }

    /// Waits until the scope analysis command buffer has completed.
    public func waitForCompletion() async throws {
        try await completion?.wait()
    }
}

/// GPU scope analyzer for FR-COL-003 waveform, vectorscope, RGB parade, and histogram data.
public final class MetalScopeAnalyzer {  // swiftlint:disable:this type_body_length
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let resourcePool = ScopeResourcePool(ringDepth: 3)
    private var pipelines: [String: MTLComputePipelineState] = [:]

    /// Creates a scope analyzer with the default Metal device.
    public convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalScopeError.metalDeviceUnavailable
        }

        try self.init(device: device)
    }

    /// Creates a scope analyzer with an explicit Metal device.
    public init(device: MTLDevice) throws {
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalScopeError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue

        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalScopeError.shaderLibraryCreationFailed(String(describing: error))
        }
    }

    /// Schedules GPU scope analysis for display-encoded `texture`.
    ///
    /// Input contract: `texture` must contain display-encoded RGB samples, not the linear-light
    /// compositor working texture. The kernels intentionally compute Rec.709 luma and Cb/Cr from
    /// raw display-encoded sample values to match broadcast scope behavior.
    ///
    /// This method intentionally returns immediately after committing a command buffer. It never
    /// blocks on completion and never reads scope data back to the CPU, so it can be scheduled
    /// beside playback without adding a synchronous readback to the render hot path.
    public func analyze(displayEncodedTexture texture: MTLTexture) throws -> MetalScopeFrame {
        guard texture.width > 0, texture.height > 0 else {
            throw MetalScopeError.invalidSourceDimensions(
                width: texture.width,
                height: texture.height
            )
        }

        let resourceSet = try resourcePool.acquire(
            width: texture.width,
            makeBuffers: makeBuffers(width:),
            makeTextures: makeTextures(width:)
        )
        let buffers = resourceSet.buffers
        let textures = resourceSet.textures

        do {
            let commandBuffer = try makeCommandBuffer()
            try encodeScopeAnalysis(
                commandBuffer: commandBuffer,
                sourceTexture: texture,
                buffers: buffers,
                textures: textures
            )

            let lease = ScopeResourceLease(pool: resourcePool, resourceSet: resourceSet)
            let completion = RenderCompletion()
            completion.attach(to: commandBuffer)
            commandBuffer.addCompletedHandler { [lease] _ in
                lease.keepAlive()
            }
            commandBuffer.commit()

            return makeScopeFrame(
                texture: texture,
                commandBuffer: commandBuffer,
                resourceSet: resourceSet,
                completion: completion,
                lease: lease
            )
        } catch {
            resourcePool.release(resourceSet)
            throw error
        }
    }

    /// Deprecated compile-time guard for callers that do not state the scope input color-space.
    @available(
        *,
        unavailable,
        message:
            "Scopes require display-encoded Rec.709 input; call analyze(displayEncodedTexture:)."
    )
    public func analyze(texture: MTLTexture) throws -> MetalScopeFrame {
        try analyze(displayEncodedTexture: texture)
    }

    private func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalScopeError.commandBufferCreationFailed
        }
        return commandBuffer
    }

    private func encodeScopeAnalysis(
        commandBuffer: MTLCommandBuffer,
        sourceTexture texture: MTLTexture,
        buffers: ScopeBuffers,
        textures: ScopeTextures
    ) throws {
        try encodeClears(commandBuffer: commandBuffer, buffers: buffers)
        try encodeAccumulate(
            commandBuffer: commandBuffer,
            sourceTexture: texture,
            buffers: buffers
        )
        try encodeScopeTexture(
            commandBuffer: commandBuffer,
            functionName: "ajar_scope_render_histogram",
            texture: textures.histogram,
            buffers: [buffers.histogram]
        )
        try encodeScopeTexture(
            commandBuffer: commandBuffer,
            functionName: "ajar_scope_render_waveform",
            texture: textures.waveform,
            buffers: [buffers.waveform]
        )
        try encodeScopeTexture(
            commandBuffer: commandBuffer,
            functionName: "ajar_scope_render_rgb_parade",
            texture: textures.rgbParade,
            buffers: [buffers.rgbParade]
        )
        try encodeScopeTexture(
            commandBuffer: commandBuffer,
            functionName: "ajar_scope_render_vectorscope",
            texture: textures.vectorscope,
            buffers: [buffers.vectorscope]
        )
    }

    private func makeScopeFrame(
        texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        resourceSet: ScopeResourceSet,
        completion: RenderCompletion,
        lease: ScopeResourceLease
    ) -> MetalScopeFrame {
        let buffers = resourceSet.buffers
        let textures = resourceSet.textures
        return MetalScopeFrame(
            sourceDimensions: PixelDimensions(width: texture.width, height: texture.height),
            commandBuffer: commandBuffer,
            histogramBuffer: buffers.histogram,
            waveformBuffer: buffers.waveform,
            rgbParadeBuffer: buffers.rgbParade,
            vectorscopeBuffer: buffers.vectorscope,
            histogramTexture: textures.histogram,
            waveformTexture: textures.waveform,
            rgbParadeTexture: textures.rgbParade,
            vectorscopeTexture: textures.vectorscope,
            completion: completion,
            resourceLease: lease
        )
    }

    private func makeBuffers(width: Int) throws -> ScopeBuffers {
        try ScopeBuffers(
            histogram: makeBuffer(
                label: "histogram",
                elementCount: MetalScopeLayout.histogramElementCount
            ),
            waveform: makeBuffer(
                label: "waveform",
                elementCount: width * MetalScopeLayout.binCount
            ),
            rgbParade: makeBuffer(
                label: "rgbParade",
                elementCount: width
                    * MetalScopeLayout.rgbParadeChannelCount
                    * MetalScopeLayout.binCount
            ),
            vectorscope: makeBuffer(
                label: "vectorscope",
                elementCount: MetalScopeLayout.vectorscopeElementCount
            )
        )
    }

    private func makeBuffer(label: String, elementCount: Int) throws -> MTLBuffer {
        let byteCount = elementCount * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModePrivate) else {
            throw MetalScopeError.bufferCreationFailed(label)
        }

        buffer.label = "AjarScope.\(label)"
        return buffer
    }

    private func makeTextures(width: Int) throws -> ScopeTextures {
        try ScopeTextures(
            histogram: makeScopeTexture(
                label: "histogram",
                width: MetalScopeLayout.binCount,
                height: MetalScopeLayout.histogramChannelCount
            ),
            waveform: makeScopeTexture(
                label: "waveform",
                width: width,
                height: MetalScopeLayout.binCount
            ),
            rgbParade: makeScopeTexture(
                label: "rgbParade",
                width: width * MetalScopeLayout.rgbParadeChannelCount,
                height: MetalScopeLayout.binCount
            ),
            vectorscope: makeScopeTexture(
                label: "vectorscope",
                width: MetalScopeLayout.binCount,
                height: MetalScopeLayout.binCount
            )
        )
    }

    private func makeScopeTexture(label: String, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalScopeError.textureCreationFailed(label)
        }

        texture.label = "AjarScope.\(label)"
        return texture
    }

    private func encodeClears(commandBuffer: MTLCommandBuffer, buffers: ScopeBuffers) throws {
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalScopeError.commandEncoderCreationFailed
        }

        for buffer in buffers.all {
            blitEncoder.fill(buffer: buffer, range: 0..<buffer.length, value: 0)
        }
        blitEncoder.endEncoding()
    }

    private func encodeAccumulate(
        commandBuffer: MTLCommandBuffer,
        sourceTexture: MTLTexture,
        buffers: ScopeBuffers
    ) throws {
        let pipeline = try pipeline(named: "ajar_scope_accumulate")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalScopeError.commandEncoderCreationFailed
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setBuffer(buffers.histogram, offset: 0, index: 0)
        encoder.setBuffer(buffers.waveform, offset: 0, index: 1)
        encoder.setBuffer(buffers.rgbParade, offset: 0, index: 2)
        encoder.setBuffer(buffers.vectorscope, offset: 0, index: 3)
        dispatch(
            encoder: encoder,
            pipeline: pipeline,
            width: sourceTexture.width,
            height: sourceTexture.height
        )
        encoder.endEncoding()
    }

    private func encodeScopeTexture(
        commandBuffer: MTLCommandBuffer,
        functionName: String,
        texture: MTLTexture,
        buffers: [MTLBuffer]
    ) throws {
        let pipeline = try pipeline(named: functionName)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalScopeError.commandEncoderCreationFailed
        }

        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        encoder.setTexture(texture, index: 0)
        dispatch(encoder: encoder, pipeline: pipeline, width: texture.width, height: texture.height)
        encoder.endEncoding()
    }

    private func pipeline(named name: String) throws -> MTLComputePipelineState {
        if let pipeline = pipelines[name] {
            return pipeline
        }

        guard let function = library.makeFunction(name: name) else {
            throw MetalScopeError.shaderFunctionUnavailable(name)
        }

        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            pipelines[name] = pipeline
            return pipeline
        } catch {
            throw MetalScopeError.computePipelineCreationFailed(String(describing: error))
        }
    }

    private func dispatch(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, 16))
        let maxThreadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        let threadHeight = max(1, min(maxThreadHeight, 16))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    private struct ScopeBuffers {
        let histogram: MTLBuffer
        let waveform: MTLBuffer
        let rgbParade: MTLBuffer
        let vectorscope: MTLBuffer

        var all: [MTLBuffer] {
            [histogram, waveform, rgbParade, vectorscope]
        }
    }

    private struct ScopeTextures {
        let histogram: MTLTexture
        let waveform: MTLTexture
        let rgbParade: MTLTexture
        let vectorscope: MTLTexture
    }

    private final class ScopeResourceSet {
        let buffers: ScopeBuffers
        let textures: ScopeTextures
        var isLeased = false

        init(buffers: ScopeBuffers, textures: ScopeTextures) {
            self.buffers = buffers
            self.textures = textures
        }
    }

    private final class ScopeResourceLease {
        private let pool: ScopeResourcePool
        private let resourceSet: ScopeResourceSet

        init(pool: ScopeResourcePool, resourceSet: ScopeResourceSet) {
            self.pool = pool
            self.resourceSet = resourceSet
        }

        func keepAlive() {}

        deinit {
            pool.release(resourceSet)
        }
    }

    private final class ScopeResourcePool {
        private let ringDepth: Int
        private let lock = NSLock()
        private var setsByWidth: [Int: [ScopeResourceSet]] = [:]
        private var nextIndexByWidth: [Int: Int] = [:]

        init(ringDepth: Int) {
            self.ringDepth = max(1, ringDepth)
        }

        func acquire(
            width: Int,
            makeBuffers: (Int) throws -> ScopeBuffers,
            makeTextures: (Int) throws -> ScopeTextures
        ) throws -> ScopeResourceSet {
            lock.lock()
            defer {
                lock.unlock()
            }

            var sets = setsByWidth[width] ?? []
            if sets.count < ringDepth {
                let resourceSet = ScopeResourceSet(
                    buffers: try makeBuffers(width),
                    textures: try makeTextures(width)
                )
                resourceSet.isLeased = true
                sets.append(resourceSet)
                setsByWidth[width] = sets
                nextIndexByWidth[width] = sets.count % ringDepth
                return resourceSet
            }

            let startIndex = nextIndexByWidth[width] ?? 0
            for offset in 0..<sets.count {
                let index = (startIndex + offset) % sets.count
                let resourceSet = sets[index]
                if !resourceSet.isLeased {
                    resourceSet.isLeased = true
                    nextIndexByWidth[width] = (index + 1) % sets.count
                    return resourceSet
                }
            }

            let overflowSet = ScopeResourceSet(
                buffers: try makeBuffers(width),
                textures: try makeTextures(width)
            )
            overflowSet.isLeased = true
            return overflowSet
        }

        func release(_ resourceSet: ScopeResourceSet) {
            lock.lock()
            resourceSet.isLeased = false
            lock.unlock()
        }
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        constant uint ajar_scope_bin_count = 256u;

        static uint ajar_scope_bin(float value) {
            float clamped = clamp(value, 0.0f, 1.0f);
            return min(uint((clamped * 255.0f) + 0.5f), 255u);
        }

        static float ajar_scope_luma(float3 rgb) {
            return dot(clamp(rgb, float3(0.0f), float3(1.0f)), float3(0.2126f, 0.7152f, 0.0722f));
        }

        static uint ajar_scope_waveform_index(uint x, uint bin) {
            return (x * ajar_scope_bin_count) + bin;
        }

        static uint ajar_scope_parade_index(uint channel, uint x, uint bin, uint width) {
            return ((channel * width * ajar_scope_bin_count) + (x * ajar_scope_bin_count)) + bin;
        }

        static uint ajar_scope_vectorscope_index(uint x, uint y) {
            return (y * ajar_scope_bin_count) + x;
        }

        static uint2 ajar_scope_vectorscope_position(float3 rgb) {
            float3 clamped = clamp(rgb, float3(0.0f), float3(1.0f));
            float y = ajar_scope_luma(clamped);
            float cb = (clamped.b - y) / (2.0f * (1.0f - 0.0722f));
            float cr = (clamped.r - y) / (2.0f * (1.0f - 0.2126f));
            return uint2(ajar_scope_bin(cb + 0.5f), ajar_scope_bin(cr + 0.5f));
        }

        static float ajar_scope_density(uint count) {
            return count == 0u ? 0.0f : saturate(log2(float(count) + 1.0f) * 0.25f);
        }

        static float4 ajar_scope_histogram_color(uint row, uint count) {
            if (count == 0u) {
                return float4(0.0f, 0.0f, 0.0f, 1.0f);
            }
            float density = ajar_scope_density(count);
            switch (row) {
            case 0:
                return float4(density, 0.0f, 0.0f, 1.0f);
            case 1:
                return float4(0.0f, density, 0.0f, 1.0f);
            case 2:
                return float4(0.0f, 0.0f, density, 1.0f);
            default:
                return float4(density, density, density, 1.0f);
            }
        }

        kernel void ajar_scope_accumulate(
            texture2d<float, access::read> sourceTexture [[texture(0)]],
            device atomic_uint *histogram [[buffer(0)]],
            device atomic_uint *waveform [[buffer(1)]],
            device atomic_uint *rgbParade [[buffer(2)]],
            device atomic_uint *vectorscope [[buffer(3)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= sourceTexture.get_width() || gid.y >= sourceTexture.get_height()) {
                return;
            }

            // Scope inputs are display-encoded samples, not the compositor's linear-light
            // working texture. Broadcast-style luma/Cb/Cr math below intentionally operates on
            // these raw sample values.
            float3 rgb = clamp(sourceTexture.read(gid).rgb, float3(0.0f), float3(1.0f));
            uint redBin = ajar_scope_bin(rgb.r);
            uint greenBin = ajar_scope_bin(rgb.g);
            uint blueBin = ajar_scope_bin(rgb.b);
            uint lumaBin = ajar_scope_bin(ajar_scope_luma(rgb));
            uint width = sourceTexture.get_width();

            atomic_fetch_add_explicit(&histogram[redBin], 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(
                &histogram[ajar_scope_bin_count + greenBin],
                1u,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &histogram[(2u * ajar_scope_bin_count) + blueBin],
                1u,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &histogram[(3u * ajar_scope_bin_count) + lumaBin],
                1u,
                memory_order_relaxed
            );

            atomic_fetch_add_explicit(
                &waveform[ajar_scope_waveform_index(gid.x, lumaBin)],
                1u,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &rgbParade[ajar_scope_parade_index(0u, gid.x, redBin, width)],
                1u,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &rgbParade[ajar_scope_parade_index(1u, gid.x, greenBin, width)],
                1u,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &rgbParade[ajar_scope_parade_index(2u, gid.x, blueBin, width)],
                1u,
                memory_order_relaxed
            );

            uint2 vectorPosition = ajar_scope_vectorscope_position(rgb);
            atomic_fetch_add_explicit(
                &vectorscope[ajar_scope_vectorscope_index(vectorPosition.x, vectorPosition.y)],
                1u,
                memory_order_relaxed
            );
        }

        kernel void ajar_scope_render_histogram(
            device atomic_uint *histogram [[buffer(0)]],
            texture2d<float, access::write> outputTexture [[texture(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
                return;
            }

            uint index = (gid.y * ajar_scope_bin_count) + gid.x;
            uint count = atomic_load_explicit(&histogram[index], memory_order_relaxed);
            outputTexture.write(ajar_scope_histogram_color(gid.y, count), gid);
        }

        kernel void ajar_scope_render_waveform(
            device atomic_uint *waveform [[buffer(0)]],
            texture2d<float, access::write> outputTexture [[texture(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
                return;
            }

            uint index = ajar_scope_waveform_index(gid.x, gid.y);
            uint count = atomic_load_explicit(&waveform[index], memory_order_relaxed);
            float value = ajar_scope_density(count);
            outputTexture.write(float4(value, value, value, 1.0f), gid);
        }

        kernel void ajar_scope_render_rgb_parade(
            device atomic_uint *rgbParade [[buffer(0)]],
            texture2d<float, access::write> outputTexture [[texture(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
                return;
            }

            uint sourceWidth = max(outputTexture.get_width() / 3u, 1u);
            uint channel = min(gid.x / sourceWidth, 2u);
            uint sourceX = min(gid.x - (channel * sourceWidth), sourceWidth - 1u);
            uint index = ajar_scope_parade_index(channel, sourceX, gid.y, sourceWidth);
            uint count = atomic_load_explicit(&rgbParade[index], memory_order_relaxed);
            if (count == 0u) {
                outputTexture.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
                return;
            }

            float3 color = channel == 0u
                ? float3(1.0f, 0.0f, 0.0f)
                : (channel == 1u ? float3(0.0f, 1.0f, 0.0f) : float3(0.0f, 0.0f, 1.0f));
            outputTexture.write(float4(color * ajar_scope_density(count), 1.0f), gid);
        }

        kernel void ajar_scope_render_vectorscope(
            device atomic_uint *vectorscope [[buffer(0)]],
            texture2d<float, access::write> outputTexture [[texture(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
                return;
            }

            uint index = ajar_scope_vectorscope_index(gid.x, gid.y);
            uint count = atomic_load_explicit(&vectorscope[index], memory_order_relaxed);
            float value = ajar_scope_density(count);
            outputTexture.write(float4(value, value, value, 1.0f), gid);
        }
        """
}
