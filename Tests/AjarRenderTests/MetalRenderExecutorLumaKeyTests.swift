// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import XCTest

final class MetalRenderExecutorLumaKeyTests: XCTestCase {
    func testFRCOMP005LumaKeyRemovesSelectedLumaRangeOverBackground() throws {
        let device = try lumaMetalDeviceOrSkip()
        let graph = try makeLumaTwoClipGraph(
            topEffects: try makeLumaKeyEffects(
                lowThreshold: try RationalValue(numerator: 1, denominator: 4),
                highThreshold: try RationalValue(numerator: 3, denominator: 4)
            )
        )
        let bottomTexture = try makeLumaTexture(
            device: device,
            width: 3,
            height: 1,
            bgraPixels: repeatedLumaBGRA([255, 0, 0, 255], count: 3)
        )
        let topTexture = try makeLumaTexture(
            device: device,
            width: 3,
            height: 1,
            bgraPixels: [
                0, 0, 0, 255,
                180, 180, 180, 255,
                255, 255, 255, 255
            ]
        )

        let pixels = try renderLumaGraph(
            device: device,
            graph: graph,
            output: PixelDimensions(width: 3, height: 1),
            textures: [
                try lumaUUID(LumaTestIDs.bottomClip): bottomTexture,
                try lumaUUID(LumaTestIDs.topClip): topTexture
            ]
        )

        XCTAssertEqual(pixels[0..<4], [0, 0, 0, 255])
        XCTAssertEqual(pixels[4..<8], [255, 0, 0, 255])
        XCTAssertEqual(pixels[8..<12], [255, 255, 255, 255])
    }

    func testFRCOMP005LumaKeyInvertFlipsMatte() throws {
        let device = try lumaMetalDeviceOrSkip()
        let graph = try makeLumaTwoClipGraph(
            topEffects: try makeLumaKeyEffects(
                lowThreshold: try RationalValue(numerator: 1, denominator: 4),
                highThreshold: try RationalValue(numerator: 3, denominator: 4),
                invert: true
            )
        )
        let bottomTexture = try makeLumaTexture(
            device: device,
            width: 3,
            height: 1,
            bgraPixels: repeatedLumaBGRA([255, 0, 0, 255], count: 3)
        )
        let topTexture = try makeLumaTexture(
            device: device,
            width: 3,
            height: 1,
            bgraPixels: [
                0, 0, 0, 255,
                180, 180, 180, 255,
                255, 255, 255, 255
            ]
        )

        let pixels = try renderLumaGraph(
            device: device,
            graph: graph,
            output: PixelDimensions(width: 3, height: 1),
            textures: [
                try lumaUUID(LumaTestIDs.bottomClip): bottomTexture,
                try lumaUUID(LumaTestIDs.topClip): topTexture
            ]
        )

        XCTAssertEqual(pixels[0..<4], [255, 0, 0, 255])
        XCTAssertEqual(pixels[4..<8], [180, 180, 180, 255])
        XCTAssertEqual(pixels[8..<12], [255, 0, 0, 255])
    }

    func testFRCOMP005LumaKeySoftnessRampsAlphaAtRangeEdge() throws {
        let device = try lumaMetalDeviceOrSkip()
        let graph = try makeLumaSingleClipGraph(
            effects: try makeLumaKeyEffects(
                lowThreshold: try RationalValue(numerator: 1, denominator: 2),
                highThreshold: .one,
                softness: try RationalValue(numerator: 1, denominator: 2)
            )
        )
        let sourceTexture = try makeLumaTexture(
            device: device,
            width: 4,
            height: 1,
            bgraPixels: [
                0, 0, 0, 255,
                100, 100, 100, 255,
                160, 160, 160, 255,
                255, 255, 255, 255
            ]
        )
        let pixels = try renderLumaGraph(
            device: device,
            graph: graph,
            output: PixelDimensions(width: 4, height: 1),
            textures: [try lumaUUID(LumaTestIDs.clip): sourceTexture]
        )

        XCTAssertGreaterThan(pixels[3], pixels[7])
        XCTAssertGreaterThan(pixels[7], pixels[11])
        XCTAssertGreaterThan(pixels[11], pixels[15])
        XCTAssertEqual(pixels[15], 0)
    }

    func testFRCOMP005PremultipliedAlphaSourceCompositesWithoutDarkFringe() throws {
        let device = try lumaMetalDeviceOrSkip()
        let graph = try makeLumaTwoClipGraph(topEffects: .none)
        let bottomTexture = try makeLumaTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [255, 0, 0, 255]
        )
        let topTexture = try makeLumaTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 128, 128]
        )

        let pixels = try renderLumaGraph(
            device: device,
            graph: graph,
            output: PixelDimensions(width: 1, height: 1),
            textures: [
                try lumaUUID(LumaTestIDs.bottomClip): bottomTexture,
                try lumaUUID(LumaTestIDs.topClip): topTexture
            ]
        )

        XCTAssertGreaterThan(pixels[0], 160)
        XCTAssertLessThan(pixels[1], 8)
        XCTAssertGreaterThan(pixels[2], 160)
        XCTAssertEqual(pixels[3], 255)
    }

    func testFRCOMP005PremultipliedSpatialAlphaEdgeCompositesWithoutDarkFringe() throws {
        let device = try lumaMetalDeviceOrSkip()
        let graph = try makeLumaTwoClipGraph(topEffects: .none)
        let bottomTexture = try makeLumaTexture(
            device: device,
            width: 2,
            height: 1,
            bgraPixels: repeatedLumaBGRA([255, 0, 0, 255], count: 2)
        )
        let topTexture = try makeLumaTexture(
            device: device,
            width: 2,
            height: 1,
            bgraPixels: [
                0, 0, 128, 128,
                0, 0, 0, 0
            ]
        )

        let pixels = try renderLumaGraph(
            device: device,
            graph: graph,
            output: PixelDimensions(width: 2, height: 1),
            textures: [
                try lumaUUID(LumaTestIDs.bottomClip): bottomTexture,
                try lumaUUID(LumaTestIDs.topClip): topTexture
            ]
        )

        XCTAssertGreaterThan(pixels[0], 160)
        XCTAssertLessThan(pixels[1], 8)
        XCTAssertGreaterThan(pixels[2], 160)
        XCTAssertEqual(pixels[3], 255)
        XCTAssertEqual(pixels[4..<8], [255, 0, 0, 255])
    }
}

private enum LumaTestIDs {
    static let media = "00000000-0000-0000-0000-000000000227"
    static let clip = "00000000-0000-0000-0000-000000000327"
    static let bottomMedia = "00000000-0000-0000-0000-000000000228"
    static let topMedia = "00000000-0000-0000-0000-000000000229"
    static let bottomClip = "00000000-0000-0000-0000-000000000328"
    static let topClip = "00000000-0000-0000-0000-000000000329"
}

private final class LumaClipTextureProvider: RenderSourceTextureProvider {
    private let textures: [UUID: MTLTexture]

    init(textures: [UUID: MTLTexture]) {
        self.textures = textures
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = textures[source.clipID] else {
            throw LumaTextureError.metalTextureUnavailable
        }
        return texture
    }
}

private enum LumaTextureError: Error {
    case metalTextureUnavailable
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case unexpectedPixelCount
}

private func renderLumaGraph(
    device: MTLDevice,
    graph: RenderGraph,
    output: PixelDimensions,
    textures: [UUID: MTLTexture]
) throws -> [UInt8] {
    let executor = try MetalRenderExecutor(device: device)
    let frame = try executor.render(
        graph: graph,
        output: RenderOutputDescriptor(pixelDimensions: output),
        sourceProvider: LumaClipTextureProvider(textures: textures)
    )
    try waitForLumaRender(frame)
    return try readLumaBGRA8(texture: frame.texture, device: device)
}

private func makeLumaSingleClipGraph(effects: ClipEffects) throws -> RenderGraph {
    let mediaID = try lumaUUID(LumaTestIDs.media)
    let clipID = try lumaUUID(LumaTestIDs.clip)
    let sequence = Sequence(
        id: UUID(),
        name: "Luma",
        videoTracks: [
            Track(
                id: UUID(),
                kind: .video,
                items: [
                    .clip(
                        try makeLumaRenderClip(
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
    let project = try makeLumaProject(
        mediaPool: [try makeLumaRenderMedia(id: mediaID)],
        sequence: sequence
    )

    return try buildRenderGraph(for: sequence, at: try lumaTime(0), in: project)
}

private func makeLumaTwoClipGraph(topEffects: ClipEffects) throws -> RenderGraph {
    let bottomMediaID = try lumaUUID(LumaTestIDs.bottomMedia)
    let topMediaID = try lumaUUID(LumaTestIDs.topMedia)
    let bottomClip = try makeLumaRenderClip(
        id: try lumaUUID(LumaTestIDs.bottomClip),
        mediaID: bottomMediaID,
        effects: .none
    )
    let topClip = try makeLumaRenderClip(
        id: try lumaUUID(LumaTestIDs.topClip),
        mediaID: topMediaID,
        effects: topEffects
    )
    let sequence = Sequence(
        id: UUID(),
        name: "Luma Composite",
        videoTracks: [
            Track(id: UUID(), kind: .video, items: [.clip(bottomClip)]),
            Track(id: UUID(), kind: .video, items: [.clip(topClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let project = try makeLumaProject(
        mediaPool: [
            try makeLumaRenderMedia(id: bottomMediaID),
            try makeLumaRenderMedia(id: topMediaID)
        ],
        sequence: sequence
    )

    return try buildRenderGraph(for: sequence, at: try lumaTime(0), in: project)
}

private func makeLumaProject(mediaPool: [MediaRef], sequence: Sequence) throws -> Project {
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

private func makeLumaRenderMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "prores4444",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try lumaTime(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeLumaRenderClip(
    id: UUID,
    mediaID: UUID,
    effects: ClipEffects
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try lumaRange(startFrame: 0, durationFrames: 24),
        timelineRange: try lumaRange(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Synthetic luma clip",
        effects: effects
    )
}

private func makeLumaKeyEffects(
    lowThreshold: RationalValue = .zero,
    highThreshold: RationalValue = .one,
    softness: RationalValue = .zero,
    invert: Bool = false
) throws -> ClipEffects {
    ClipEffects(
        lumaKey: ClipLumaKeySettings(
            enabled: true,
            lowThreshold: lowThreshold,
            highThreshold: highThreshold,
            softness: softness,
            invert: invert
        )
    )
}

private func makeLumaTexture(
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
        throw LumaTextureError.metalTextureUnavailable
    }
    guard bgraPixels.count == width * height * 4 else {
        throw LumaTextureError.unexpectedPixelCount
    }

    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: bgraPixels,
        bytesPerRow: width * 4
    )
    return texture
}

private func repeatedLumaBGRA(_ pixel: [UInt8], count: Int) -> [UInt8] {
    var pixels: [UInt8] = []
    pixels.reserveCapacity(pixel.count * count)
    for _ in 0..<count {
        pixels.append(contentsOf: pixel)
    }
    return pixels
}

private func readLumaBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw LumaTextureError.commandBufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw LumaTextureError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw LumaTextureError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw LumaTextureError.blitEncoderCreationFailed
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

private func waitForLumaRender(_ frame: RenderedFrame) throws {
    guard let commandBuffer = frame.commandBuffer else {
        return
    }

    commandBuffer.waitUntilCompleted()
    XCTAssertNil(commandBuffer.error)
    XCTAssertEqual(commandBuffer.status, .completed)
}

private func lumaMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

private func lumaUUID(_ string: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: string))
}

private func lumaRange(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: try lumaTime(startFrame), duration: try lumaTime(durationFrames))
}

private func lumaTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}
