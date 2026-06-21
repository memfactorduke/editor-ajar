// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import CoreVideo
import Foundation
import Metal
import XCTest

final class MetalRenderExecutorTests: XCTestCase {
    func testADR0006FRFX007ExecutesSingleClipGraphFromCVMetalTexture() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph()
        let sourceTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let expectedMediaID = try testUUID(TestIDs.media)
        let expectedClipID = try testUUID(TestIDs.clip)

        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: ClosureRenderSourceTextureProvider { source in
                XCTAssertEqual(source.mediaID, expectedMediaID)
                XCTAssertEqual(source.clipID, expectedClipID)
                return sourceTexture.texture
            }
        )

        try waitForRender(frame)

        XCTAssertFalse(frame.cacheHit)
        XCTAssertEqual(frame.texture.width, 1)
        XCTAssertEqual(frame.texture.height, 1)
        XCTAssertEqual(frame.contentHash, graph.outputNode?.contentHash)
        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [0, 0, 255, 255])
    }

    func testADR0009ContentHashCacheReturnsCachedTextureOnRepeat() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph()
        let sourceTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [255, 0, 0, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = CountingSourceTextureProvider(texture: sourceTexture.texture)
        let output = RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1))

        let first = try executor.render(graph: graph, output: output, sourceProvider: provider)
        try waitForRender(first)
        let second = try executor.render(graph: graph, output: output, sourceProvider: provider)

        XCTAssertFalse(first.cacheHit)
        XCTAssertTrue(second.cacheHit)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(executor.cacheEntryCount, 1)
        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertTrue(first.texture === second.texture)
    }

    func testNFRQUAL001TransparentCompositeClearsOutputTexture() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeTransparentGraph()
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: ClosureRenderSourceTextureProvider { _ in
                throw TestTextureError.unexpectedSourceRequest
            }
        )

        try waitForRender(frame)

        XCTAssertFalse(frame.cacheHit)
        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [0, 0, 0, 0])
    }
}

private enum TestIDs {
    static let media = "00000000-0000-0000-0000-000000000017"
    static let clip = "00000000-0000-0000-0000-000000000117"
}

private final class CountingSourceTextureProvider: RenderSourceTextureProvider {
    private let sourceTexture: MTLTexture
    private(set) var requestCount = 0

    init(texture: MTLTexture) {
        sourceTexture = texture
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        requestCount += 1
        return sourceTexture
    }
}

private enum TestTextureError: Error {
    case unexpectedSourceRequest
    case pixelBufferCreationFailed(Int32)
    case pixelBufferBaseAddressUnavailable
    case textureCacheCreationFailed(Int32)
    case metalTextureCreationFailed(Int32)
    case metalTextureUnavailable
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
}

private final class CVMetalTextureFixture {
    let pixelBuffer: CVPixelBuffer
    let cache: CVMetalTextureCache
    let metalTexture: CVMetalTexture
    let texture: MTLTexture

    init(
        pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        metalTexture: CVMetalTexture,
        texture: MTLTexture
    ) {
        self.pixelBuffer = pixelBuffer
        self.cache = cache
        self.metalTexture = metalTexture
        self.texture = texture
    }
}

private func makeSingleClipGraph() throws -> RenderGraph {
    let mediaID = try testUUID(TestIDs.media)
    let clipID = try testUUID(TestIDs.clip)
    let media = MediaRef(
        id: mediaID,
        sourceURL: URL(fileURLWithPath: "/media/synthetic.mov"),
        contentHash: ContentHash.sha256(data: Data("synthetic".utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try time(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try range(startFrame: 0, durationFrames: 24),
        timelineRange: try range(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Synthetic"
    )
    let sequence = Sequence(
        id: UUID(),
        name: "Render",
        videoTracks: [Track(id: UUID(), kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: 1,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1, height: 1),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [media],
        sequences: [sequence]
    )

    return try buildRenderGraph(for: sequence, at: try time(0), in: project)
}

private func makeTransparentGraph() throws -> RenderGraph {
    let sequence = Sequence(
        id: UUID(),
        name: "Empty",
        videoTracks: [],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: 1,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1, height: 1),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [],
        sequences: [sequence]
    )

    return try buildRenderGraph(for: sequence, at: try time(0), in: project)
}

private func makeCVMetalTextureFixture(
    device: MTLDevice,
    width: Int,
    height: Int,
    bgra: [UInt8]
) throws -> CVMetalTextureFixture {
    var attributes: [String: Any] = [:]
    attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
    attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]

    var pixelBuffer: CVPixelBuffer?
    let pixelBufferResult = CVPixelBufferCreate(
        nil,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )

    guard pixelBufferResult == kCVReturnSuccess, let pixelBuffer else {
        throw TestTextureError.pixelBufferCreationFailed(pixelBufferResult)
    }

    try fill(pixelBuffer: pixelBuffer, width: width, height: height, bgra: bgra)

    var cache: CVMetalTextureCache?
    let cacheResult = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    guard cacheResult == kCVReturnSuccess, let cache else {
        throw TestTextureError.textureCacheCreationFailed(cacheResult)
    }

    var metalTexture: CVMetalTexture?
    let textureResult = CVMetalTextureCacheCreateTextureFromImage(
        nil,
        cache,
        pixelBuffer,
        nil,
        .bgra8Unorm,
        width,
        height,
        0,
        &metalTexture
    )

    guard textureResult == kCVReturnSuccess, let metalTexture else {
        throw TestTextureError.metalTextureCreationFailed(textureResult)
    }
    guard let texture = CVMetalTextureGetTexture(metalTexture) else {
        throw TestTextureError.metalTextureUnavailable
    }

    return CVMetalTextureFixture(
        pixelBuffer: pixelBuffer,
        cache: cache,
        metalTexture: metalTexture,
        texture: texture
    )
}

private func fill(
    pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int,
    bgra: [UInt8]
) throws {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw TestTextureError.pixelBufferBaseAddressUnavailable
    }

    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = baseAddress.bindMemory(to: UInt8.self, capacity: rowBytes * height)
    for yPosition in 0..<height {
        for xPosition in 0..<width {
            let destination = (yPosition * rowBytes) + (xPosition * 4)
            bytes[destination] = bgra[0]
            bytes[destination + 1] = bgra[1]
            bytes[destination + 2] = bgra[2]
            bytes[destination + 3] = bgra[3]
        }
    }
}

private func readBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw TestTextureError.commandBufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw TestTextureError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw TestTextureError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw TestTextureError.blitEncoderCreationFailed
    }

    blitEncoder.copy(
        from: texture,
        sourceSlice: 0,
        sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
        to: buffer,
        destinationOffset: 0,
        destinationBytesPerRow: rowBytes,
        destinationBytesPerImage: byteCount
    )
    blitEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: byteCount)
    return Array(UnsafeBufferPointer(start: pointer, count: byteCount))
}

private func waitForRender(_ frame: RenderedFrame) throws {
    guard let commandBuffer = frame.commandBuffer else {
        return
    }

    commandBuffer.waitUntilCompleted()
    XCTAssertNil(commandBuffer.error)
    XCTAssertEqual(commandBuffer.status, .completed)
}

private func metalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

private func testUUID(_ string: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: string))
}

private func range(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: try time(startFrame), duration: try time(durationFrames))
}

private func time(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}
