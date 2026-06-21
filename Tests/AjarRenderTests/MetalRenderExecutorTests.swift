// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

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

    func testFRTL002CompositesInputsInOrderSoLaterSourcesRenderOnTop() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeTwoClipGraph()
        let bottomTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [255, 0, 0, 255]
        )
        let topTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = ClipTextureProvider(
            textures: [
                try testUUID(TestIDs.bottomClip): bottomTexture.texture,
                try testUUID(TestIDs.topClip): topTexture.texture
            ]
        )

        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(
                pixelDimensions: PixelDimensions(width: 1, height: 1)
            ),
            sourceProvider: provider
        )

        try waitForRender(frame)

        XCTAssertEqual(
            provider.requestedClipIDs,
            [try testUUID(TestIDs.bottomClip), try testUUID(TestIDs.topClip)]
        )
        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [0, 0, 255, 255])
    }

    func testFRXFORM001PositionOffsetsSourceInCanvasPixels() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph(
            transform: ClipTransform(
                position: CanvasPoint(x: RationalValue(1), y: RationalValue(1))
            )
        )
        let sourceTexture = try makeTexture(
            device: device,
            width: 2,
            height: 2,
            bgraPixels: repeatedBGRA([0, 0, 255, 255], count: 4)
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 4, height: 4)),
            sourceProvider: CountingSourceTextureProvider(texture: sourceTexture)
        )

        try waitForRender(frame)

        XCTAssertEqual(
            try readBGRA8(texture: frame.texture, device: device),
            pixels4x4(
                [
                    clear, clear, clear, clear,
                    clear, red, red, clear,
                    clear, red, red, clear,
                    clear, clear, clear, clear
                ]
            )
        )
    }

    func testFRXFORM002ScaleAboutAnchorExpandsSourceQuad() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph(
            transform: ClipTransform(
                scale: ClipScale(x: RationalValue(2), y: RationalValue(2)),
                anchorPoint: .zero
            )
        )
        let sourceTexture = try makeTexture(
            device: device,
            width: 2,
            height: 2,
            bgraPixels: repeatedBGRA([0, 255, 0, 255], count: 4)
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 4, height: 4)),
            sourceProvider: CountingSourceTextureProvider(texture: sourceTexture)
        )

        try waitForRender(frame)

        XCTAssertEqual(
            try readBGRA8(texture: frame.texture, device: device),
            repeatedBGRA([0, 255, 0, 255], count: 16)
        )
    }

    func testFRXFORM004OpacityCompositesPremultipliedOverDestination() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeTwoClipGraph(
            topTransform: ClipTransform(opacity: try RationalValue(numerator: 1, denominator: 2))
        )
        let bottomTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [255, 0, 0, 255]
        )
        let topTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: ClipTextureProvider(
                textures: [
                    try testUUID(TestIDs.bottomClip): bottomTexture,
                    try testUUID(TestIDs.topClip): topTexture
                ]
            )
        )

        try waitForRender(frame)

        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [128, 0, 128, 255])
    }

    func testFRXFORM004ScreenBlendModeCombinesSourceAndDestination() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeTwoClipGraph(topTransform: ClipTransform(blendMode: .screen))
        let bottomTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [255, 0, 0, 255]
        )
        let topTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: ClipTextureProvider(
                textures: [
                    try testUUID(TestIDs.bottomClip): bottomTexture,
                    try testUUID(TestIDs.topClip): topTexture
                ]
            )
        )

        try waitForRender(frame)

        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [255, 0, 255, 255])
    }

    func testFRXFORM005CropAndFlipAffectSourceSampling() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph(
            transform: ClipTransform(
                crop: ClipCropInsets(left: 1, top: 0, right: 0, bottom: 0),
                flip: ClipFlip(horizontal: true, vertical: false)
            )
        )
        let sourceTexture = try makeTexture(
            device: device,
            width: 2,
            height: 2,
            bgraPixels: [
                0, 0, 255, 255, 0, 255, 0, 255,
                255, 0, 0, 255, 255, 255, 255, 255
            ]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 2, height: 2)),
            sourceProvider: CountingSourceTextureProvider(texture: sourceTexture)
        )

        try waitForRender(frame)

        XCTAssertEqual(
            try readBGRA8(texture: frame.texture, device: device),
            [
                0, 0, 0, 0, 0, 0, 255, 255,
                0, 0, 0, 0, 255, 0, 0, 255
            ]
        )
    }
}

private enum TestIDs {
    static let media = "00000000-0000-0000-0000-000000000017"
    static let clip = "00000000-0000-0000-0000-000000000117"
    static let bottomMedia = "00000000-0000-0000-0000-000000000018"
    static let topMedia = "00000000-0000-0000-0000-000000000019"
    static let bottomClip = "00000000-0000-0000-0000-000000000118"
    static let topClip = "00000000-0000-0000-0000-000000000119"
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

private final class ClipTextureProvider: RenderSourceTextureProvider {
    private let textures: [UUID: MTLTexture]
    private(set) var requestedClipIDs: [UUID] = []

    init(textures: [UUID: MTLTexture]) {
        self.textures = textures
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        requestedClipIDs.append(source.clipID)
        guard let texture = textures[source.clipID] else {
            throw TestTextureError.metalTextureUnavailable
        }
        return texture
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

private let clear: [UInt8] = [0, 0, 0, 0]
private let red: [UInt8] = [0, 0, 255, 255]

private func makeSingleClipGraph(transform: ClipTransform = .identity) throws -> RenderGraph {
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
        name: "Synthetic",
        transform: transform
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
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
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

private func makeTwoClipGraph(topTransform: ClipTransform = .identity) throws -> RenderGraph {
    let bottomMediaID = try testUUID(TestIDs.bottomMedia)
    let topMediaID = try testUUID(TestIDs.topMedia)
    let bottomClip = try makeRenderClip(
        id: try testUUID(TestIDs.bottomClip),
        mediaID: bottomMediaID
    )
    let topClip = try makeRenderClip(
        id: try testUUID(TestIDs.topClip),
        mediaID: topMediaID,
        transform: topTransform
    )
    let sequence = Sequence(
        id: UUID(),
        name: "Composite",
        videoTracks: [
            Track(id: UUID(), kind: .video, items: [.clip(bottomClip)]),
            Track(id: UUID(), kind: .video, items: [.clip(topClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1, height: 1),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [
            try makeRenderMedia(id: bottomMediaID),
            try makeRenderMedia(id: topMediaID)
        ],
        sequences: [sequence]
    )

    return try buildRenderGraph(for: sequence, at: try time(0), in: project)
}

private func makeRenderMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
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
}

private func makeRenderClip(
    id: UUID,
    mediaID: UUID,
    transform: ClipTransform = .identity
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try range(startFrame: 0, durationFrames: 24),
        timelineRange: try range(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Synthetic",
        transform: transform
    )
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
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
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

private func makeTexture(
    device: MTLDevice,
    width: Int,
    height: Int,
    bgraPixels: [UInt8]
) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]

    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw TestTextureError.metalTextureUnavailable
    }
    guard bgraPixels.count == width * height * 4 else {
        throw TestTextureError.pixelBufferBaseAddressUnavailable
    }

    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: bgraPixels,
        bytesPerRow: width * 4
    )
    return texture
}

private func repeatedBGRA(_ pixel: [UInt8], count: Int) -> [UInt8] {
    var pixels: [UInt8] = []
    pixels.reserveCapacity(pixel.count * count)
    for _ in 0..<count {
        pixels.append(contentsOf: pixel)
    }
    return pixels
}

private func pixels4x4(_ pixels: [[UInt8]]) -> [UInt8] {
    pixels.flatMap { $0 }
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
