// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import XCTest

final class MetalRenderExecutorChromaKeyTests: XCTestCase {
    func testFRCOMP001ChromaKeyCompositesSubjectOverBackground() throws {
        let device = try chromaMetalDeviceOrSkip()
        let graph = try makeChromaTwoClipGraph(
            topEffects: try makeChromaKeyEffects(
                tolerance: try RationalValue(numerator: 1, denominator: 10)
            )
        )
        let bottomTexture = try makeChromaTexture(
            device: device,
            width: 2,
            height: 1,
            bgraPixels: repeatedChromaBGRA([255, 0, 0, 255], count: 2)
        )
        let topTexture = try makeChromaTexture(
            device: device,
            width: 2,
            height: 1,
            bgraPixels: [
                0, 255, 0, 255,
                0, 0, 255, 255
            ]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 2, height: 1)),
            sourceProvider: ChromaClipTextureProvider(
                textures: [
                    try chromaUUID(ChromaTestIDs.bottomClip): bottomTexture,
                    try chromaUUID(ChromaTestIDs.topClip): topTexture
                ]
            )
        )

        try waitForChromaRender(frame)

        XCTAssertEqual(
            try readChromaBGRA8(texture: frame.texture, device: device),
            [
                255, 0, 0, 255,
                0, 0, 255, 255
            ]
        )
    }

    func testFRCOMP001SpillSuppressionReducesKeyColorSpill() throws {
        let device = try chromaMetalDeviceOrSkip()
        let sourceTexture = try makeChromaTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 200, 120, 255]
        )
        let withoutSpill = try renderChromaSinglePixel(
            device: device,
            effects: try makeChromaKeyEffects(spillSuppression: .zero),
            texture: sourceTexture
        )
        let withSpill = try renderChromaSinglePixel(
            device: device,
            effects: try makeChromaKeyEffects(spillSuppression: .one),
            texture: sourceTexture
        )

        XCTAssertLessThan(withSpill[1], withoutSpill[1])
        XCTAssertEqual(withSpill[0], withoutSpill[0])
        XCTAssertEqual(withSpill[2], withoutSpill[2])
    }

    func testFRCOMP002ViewMatteOutputsAlphaPreview() throws {
        let device = try chromaMetalDeviceOrSkip()
        let graph = try makeChromaSingleClipGraph(
            effects: try makeChromaKeyEffects(
                tolerance: try RationalValue(numerator: 1, denominator: 10),
                viewMatte: true
            )
        )
        let sourceTexture = try makeChromaTexture(
            device: device,
            width: 2,
            height: 1,
            bgraPixels: [
                0, 255, 0, 255,
                0, 0, 255, 255
            ]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 2, height: 1)),
            sourceProvider: ChromaCountingTextureProvider(texture: sourceTexture)
        )

        try waitForChromaRender(frame)

        XCTAssertEqual(
            try readChromaBGRA8(texture: frame.texture, device: device),
            [
                0, 0, 0, 255,
                255, 255, 255, 255
            ]
        )
    }
}

private enum ChromaTestIDs {
    static let media = "00000000-0000-0000-0000-000000000217"
    static let clip = "00000000-0000-0000-0000-000000000317"
    static let bottomMedia = "00000000-0000-0000-0000-000000000218"
    static let topMedia = "00000000-0000-0000-0000-000000000219"
    static let bottomClip = "00000000-0000-0000-0000-000000000318"
    static let topClip = "00000000-0000-0000-0000-000000000319"
}

private final class ChromaCountingTextureProvider: RenderSourceTextureProvider {
    private let sourceTexture: MTLTexture

    init(texture: MTLTexture) {
        sourceTexture = texture
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        sourceTexture
    }
}

private final class ChromaClipTextureProvider: RenderSourceTextureProvider {
    private let textures: [UUID: MTLTexture]

    init(textures: [UUID: MTLTexture]) {
        self.textures = textures
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = textures[source.clipID] else {
            throw ChromaTextureError.metalTextureUnavailable
        }
        return texture
    }
}

private enum ChromaTextureError: Error {
    case metalTextureUnavailable
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case pixelBufferBaseAddressUnavailable
}

private func makeChromaSingleClipGraph(effects: ClipEffects) throws -> RenderGraph {
    let mediaID = try chromaUUID(ChromaTestIDs.media)
    let clipID = try chromaUUID(ChromaTestIDs.clip)
    let sequence = Sequence(
        id: UUID(),
        name: "Chroma",
        videoTracks: [
            Track(
                id: UUID(),
                kind: .video,
                items: [
                    .clip(
                        try makeChromaRenderClip(
                            id: clipID,
                            mediaID: mediaID,
                            effects: effects
                        )
                    )
                ]
            )
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = try makeChromaProject(
        mediaPool: [try makeChromaRenderMedia(id: mediaID)],
        sequence: sequence
    )

    return try buildRenderGraph(for: sequence, at: try chromaTime(0), in: project)
}

private func makeChromaTwoClipGraph(topEffects: ClipEffects) throws -> RenderGraph {
    let bottomMediaID = try chromaUUID(ChromaTestIDs.bottomMedia)
    let topMediaID = try chromaUUID(ChromaTestIDs.topMedia)
    let bottomClip = try makeChromaRenderClip(
        id: try chromaUUID(ChromaTestIDs.bottomClip),
        mediaID: bottomMediaID,
        effects: .none
    )
    let topClip = try makeChromaRenderClip(
        id: try chromaUUID(ChromaTestIDs.topClip),
        mediaID: topMediaID,
        effects: topEffects
    )
    let sequence = Sequence(
        id: UUID(),
        name: "Chroma Composite",
        videoTracks: [
            Track(id: UUID(), kind: .video, items: [.clip(bottomClip)]),
            Track(id: UUID(), kind: .video, items: [.clip(topClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = try makeChromaProject(
        mediaPool: [
            try makeChromaRenderMedia(id: bottomMediaID),
            try makeChromaRenderMedia(id: topMediaID)
        ],
        sequence: sequence
    )

    return try buildRenderGraph(for: sequence, at: try chromaTime(0), in: project)
}

private func makeChromaProject(mediaPool: [MediaRef], sequence: Sequence) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: 1, height: 1),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: mediaPool,
        sequences: [sequence]
    )
}

private func makeChromaRenderMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try chromaTime(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeChromaRenderClip(
    id: UUID,
    mediaID: UUID,
    effects: ClipEffects
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try chromaRange(startFrame: 0, durationFrames: 24),
        timelineRange: try chromaRange(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Synthetic",
        effects: effects
    )
}

private func makeChromaKeyEffects(
    tolerance: RationalValue = .zero,
    edgeSoftness: RationalValue = .zero,
    spillSuppression: RationalValue = .zero,
    choke: RationalValue = .zero,
    viewMatte: Bool = false
) throws -> ClipEffects {
    ClipEffects(
        chromaKey: ClipChromaKeySettings(
            enabled: true,
            keyColor: .green,
            tolerance: tolerance,
            edgeSoftness: edgeSoftness,
            spillSuppression: spillSuppression,
            choke: choke,
            viewMatte: viewMatte
        )
    )
}

private func renderChromaSinglePixel(
    device: MTLDevice,
    effects: ClipEffects,
    texture: MTLTexture
) throws -> [UInt8] {
    let executor = try MetalRenderExecutor(device: device)
    let frame = try executor.render(
        graph: try makeChromaSingleClipGraph(effects: effects),
        output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
        sourceProvider: ChromaCountingTextureProvider(texture: texture)
    )
    try waitForChromaRender(frame)
    return try readChromaBGRA8(texture: frame.texture, device: device)
}

private func makeChromaTexture(
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
        throw ChromaTextureError.metalTextureUnavailable
    }
    guard bgraPixels.count == width * height * 4 else {
        throw ChromaTextureError.pixelBufferBaseAddressUnavailable
    }

    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: bgraPixels,
        bytesPerRow: width * 4
    )
    return texture
}

private func repeatedChromaBGRA(_ pixel: [UInt8], count: Int) -> [UInt8] {
    var pixels: [UInt8] = []
    pixels.reserveCapacity(pixel.count * count)
    for _ in 0..<count {
        pixels.append(contentsOf: pixel)
    }
    return pixels
}

private func readChromaBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw ChromaTextureError.commandBufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw ChromaTextureError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw ChromaTextureError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw ChromaTextureError.blitEncoderCreationFailed
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

private func waitForChromaRender(_ frame: RenderedFrame) throws {
    guard let commandBuffer = frame.commandBuffer else {
        return
    }

    commandBuffer.waitUntilCompleted()
    XCTAssertNil(commandBuffer.error)
    XCTAssertEqual(commandBuffer.status, .completed)
}

private func chromaMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

private func chromaUUID(_ string: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: string))
}

private func chromaRange(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: try chromaTime(startFrame), duration: try chromaTime(durationFrames))
}

private func chromaTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}
