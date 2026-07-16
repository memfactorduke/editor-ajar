// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import CoreGraphics
import CoreVideo
import Foundation
import Metal

/// Sequential export frame provider backed by the same immutable render graph as playback.
///
/// Export graphs are built **original-only** (`proxyFileExists` always false) so
/// `preferProxyPlayback` never bakes `.proxy` tiers into export content hashes (ADR-0019 /
/// FR-EXP-007). Per-frame observed tiers are exposed for the session audit trail.
public final class RenderGraphExportFrameProvider: ExportVideoFrameProvider,
    ExportGraphSourceAuditing {
    private let project: Project
    private let sequence: Sequence
    private let deliveryResolution: PixelDimensions
    private let deliveryColorSpace: ExportColorSpace
    private let deliveryCodec: ExportVideoCodec?
    private let sourceProvider: any ExportRenderSourceProvider
    private let executor: MetalRenderExecutor
    private let device: MTLDevice
    private let readbackQueue: MTLCommandQueue
    private let lock = NSLock()
    private var lastRenderedExportSourceTiersStorage:
        [(mediaID: UUID, tier: ExportMediaSourceTier)] = []

    /// Source tiers observed in the most recently rendered export graph (FR-EXP-007).
    public var lastRenderedExportSourceTiers: [(mediaID: UUID, tier: ExportMediaSourceTier)] {
        lock.lock()
        defer { lock.unlock() }
        return lastRenderedExportSourceTiersStorage
    }

    init(
        project: Project,
        sequence: Sequence,
        resolution: PixelDimensions,
        colorSpace: ExportColorSpace,
        codec: ExportVideoCodec?,
        sourceProvider: any ExportRenderSourceProvider,
        device: MTLDevice
    ) throws {
        let validDimensionRange = 1...16_384
        guard validDimensionRange.contains(resolution.width),
              validDimensionRange.contains(resolution.height)
        else {
            throw ExportError.invalidSettings(.resolutionOutOfRange(resolution))
        }
        guard project.settings.colorSpace == colorSpace.mediaColorSpace else {
            throw ExportError.colorSpaceMismatch(
                project: project.settings.colorSpace,
                export: colorSpace
            )
        }
        self.project = project
        self.sequence = sequence
        deliveryResolution = resolution
        deliveryColorSpace = colorSpace
        deliveryCodec = codec
        self.sourceProvider = sourceProvider
        self.device = device
        do {
            executor = try MetalRenderExecutor(device: device)
        } catch {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: String(describing: error)
            )
        }
        guard let readbackQueue = device.makeCommandQueue() else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "Metal command queue unavailable for export readback"
            )
        }
        self.readbackQueue = readbackQueue
    }

    /// Pulls one graph, executes it in presented color, and CPU-converts into the encoder buffer.
    ///
    /// **Premultiplied alpha contract (verified against `MetalRenderExecutor` present pass):**
    /// the graph runs in linear working space with premultiplied coverage, then the present
    /// fragment returns `float4(encoded * alpha, alpha)` — display-encoded, premultiplied RGBA
    /// half-float. Delivery conversion preserves that layout into ProRes `64ARGB` and tags
    /// ProRes 4444 buffers with `kCVImageBufferAlphaChannelMode_PremultipliedAlpha`. Callers must
    /// not re-premultiply; opaque titles satisfy the contract with alpha `1`.
    public func renderFrame(
        at timelineTime: RationalTime,
        into pixelBuffer: CVPixelBuffer
    ) async throws {
        guard CVPixelBufferGetWidth(pixelBuffer) == deliveryResolution.width,
              CVPixelBufferGetHeight(pixelBuffer) == deliveryResolution.height
        else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "delivery pixel buffer dimensions do not match "
                    + "\(deliveryResolution.width)x\(deliveryResolution.height)"
            )
        }
        // ADR-0019 / FR-EXP-007: export never selects proxy files, even when the project
        // prefers proxy playback and a ready proxy is on disk.
        let graph = try buildRenderGraph(
            for: sequence,
            at: timelineTime,
            in: project,
            proxyFileExists: { _ in false }
        )
        let observedTiers = Self.sourceTiers(in: graph)
        if observedTiers.contains(where: { $0.tier == .proxy }) {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "export graph selected proxy media (FR-EXP-007 / ADR-0019)"
            )
        }
        lock.withLock {
            lastRenderedExportSourceTiersStorage = observedTiers
        }

        try await sourceProvider.prepare(graph: graph)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(
                pixelDimensions: project.settings.resolution,
                pixelFormat: MetalRenderExecutor.linearWorkingPixelFormat,
                colorMode: .presented
            ),
            sourceProvider: sourceProvider
        )
        try await frame.waitForCompletion()

        let readback = try await readbackPresentedRGBA16F(texture: frame.texture)
        if let deliveryCodec {
            try ExportColorTagging.attach(
                to: pixelBuffer,
                colorSpace: deliveryColorSpace,
                codec: deliveryCodec
            )
        } else {
            try ExportColorTagging.attach(to: pixelBuffer, colorSpace: deliveryColorSpace)
        }
        try convertReadback(readback, into: pixelBuffer)
    }

    /// Scale transform that maps the captured project canvas onto the delivery raster.
    ///
    /// Kept as pure geometry for tests and diagnostics; actual scaling is performed by
    /// `ExportDeliveryPixelConverter` via `vImageScale_ARGB16F`.
    static func deliveryTransform(
        from projectResolution: PixelDimensions,
        to exportResolution: PixelDimensions
    ) -> CGAffineTransform {
        CGAffineTransform(
            scaleX: CGFloat(exportResolution.width) / CGFloat(projectResolution.width),
            y: CGFloat(exportResolution.height) / CGFloat(projectResolution.height)
        )
    }

    // MARK: - Offline GPU readback (export path only; never on playback)

    private struct ReadbackPayload {
        let bytes: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    private static func sourceTiers(
        in graph: RenderGraph
    ) -> [(mediaID: UUID, tier: ExportMediaSourceTier)] {
        graph.exportSourceNodes().map { source in
            let tier: ExportMediaSourceTier =
                source.mediaSourceTier == .proxy ? .proxy : .original
            return (mediaID: source.mediaID, tier: tier)
        }
    }

    private func convertReadback(
        _ readback: ReadbackPayload,
        into pixelBuffer: CVPixelBuffer
    ) throws {
        do {
            try readback.bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    throw ExportError.frameRenderFailed(
                        frameIndex: 0,
                        reason: "export readback buffer was empty"
                    )
                }
                try ExportDeliveryPixelConverter.convert(
                    source: ExportRGBA16FBuffer(
                        baseAddress: base,
                        width: readback.width,
                        height: readback.height,
                        bytesPerRow: readback.bytesPerRow
                    ),
                    destination: pixelBuffer
                )
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "delivery pixel conversion failed: \(error)"
            )
        }
    }

    private func readbackPresentedRGBA16F(texture: MTLTexture) async throws -> ReadbackPayload {
        guard texture.pixelFormat == MetalRenderExecutor.linearWorkingPixelFormat else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason:
                    "export readback expected rgba16Float, got \(texture.pixelFormat.rawValue)"
            )
        }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 8
        let byteCount = bytesPerRow * height
        let buffer = try makeReadbackBuffer(byteCount: byteCount)
        try await blitTexture(texture, width: width, height: height, into: buffer)

        return ReadbackPayload(
            bytes: Data(bytes: buffer.contents(), count: byteCount),
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }

    private func makeReadbackBuffer(byteCount: Int) throws -> MTLBuffer {
        guard byteCount > 0,
              let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
        else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "could not allocate export readback buffer"
            )
        }
        return buffer
    }

    private func blitTexture(
        _ texture: MTLTexture,
        width: Int,
        height: Int,
        into buffer: MTLBuffer
    ) async throws {
        let bytesPerRow = width * 8
        let byteCount = bytesPerRow * height
        guard let commandBuffer = readbackQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "could not create export readback encoder"
            )
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blit.endEncoding()
        try await awaitCommandBuffer(commandBuffer)
    }

    private func awaitCommandBuffer(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { completed in
                Self.finishReadback(continuation, commandBuffer: completed)
            }
            commandBuffer.commit()
        }
    }

    private static func finishReadback(
        _ continuation: CheckedContinuation<Void, any Error>,
        commandBuffer: MTLCommandBuffer
    ) {
        if let error = commandBuffer.error {
            continuation.resume(
                throwing: ExportError.frameRenderFailed(
                    frameIndex: 0,
                    reason: "export readback failed: \(error)"
                )
            )
        } else {
            continuation.resume()
        }
    }
}

private extension RenderGraph {
    func exportSourceNodes() -> [RenderSourceNode] {
        var sources: [RenderSourceNode] = []
        for node in nodes {
            switch node.kind {
            case .source(let source):
                sources.append(source)
            case .compound(let compound):
                sources.append(contentsOf: compound.graph.exportSourceNodes())
            case .title, .transition, .composite:
                continue
            }
        }
        return sources
    }
}
