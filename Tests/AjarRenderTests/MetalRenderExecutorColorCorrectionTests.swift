// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import XCTest

final class MetalRenderExecutorColorCorrectionTests: XCTestCase {
    func testFRCOL001ExposureBrightensSourceInLinearLight() throws {
        let pixel = try renderColorCorrectionPixel(
            sourceBGRA: [64, 64, 64, 255],
            correction: ClipColorCorrection(exposure: RationalValue(1))
        )

        XCTAssertGreaterThan(pixel[0], 64)
        XCTAssertGreaterThan(pixel[1], 64)
        XCTAssertGreaterThan(pixel[2], 64)
        XCTAssertEqual(pixel[3], 255)
    }

    func testFRCOL001ContrastDarkensBelowPivotPatch() throws {
        let pixel = try renderColorCorrectionPixel(
            sourceBGRA: [64, 64, 64, 255],
            correction: ClipColorCorrection(contrast: RationalValue(2))
        )

        XCTAssertLessThan(pixel[0], 64)
        XCTAssertLessThan(pixel[1], 64)
        XCTAssertLessThan(pixel[2], 64)
        XCTAssertEqual(pixel[3], 255)
    }

    func testFRCOL001SaturationCanRemoveChroma() throws {
        let pixel = try renderColorCorrectionPixel(
            sourceBGRA: [32, 64, 192, 255],
            correction: ClipColorCorrection(saturation: .zero)
        )

        XCTAssertEqual(pixel[3], 255)
        XCTAssertLessThanOrEqual(abs(Int(pixel[0]) - Int(pixel[1])), 2)
        XCTAssertLessThanOrEqual(abs(Int(pixel[1]) - Int(pixel[2])), 2)
    }

    func testFRCOL001TemperatureTintShiftNeutralPatch() throws {
        let pixel = try renderColorCorrectionPixel(
            sourceBGRA: [128, 128, 128, 255],
            correction: ClipColorCorrection(temperature: .one, tint: .one)
        )

        let blue = pixel[0]
        let green = pixel[1]
        let red = pixel[2]
        XCTAssertGreaterThan(red, green)
        XCTAssertGreaterThan(blue, green)
        XCTAssertEqual(pixel[3], 255)
    }
}

private enum ColorCorrectionTestIDs {
    static let media = "00000000-0000-0000-0000-000000000317"
    static let clip = "00000000-0000-0000-0000-000000000417"
}

private final class ColorCorrectionTextureProvider: RenderSourceTextureProvider {
    private let texture: MTLTexture

    init(texture: MTLTexture) {
        self.texture = texture
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        texture
    }
}

private enum ColorCorrectionTextureError: Error {
    case textureUnavailable
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case unexpectedByteCount
}

private func renderColorCorrectionPixel(
    sourceBGRA: [UInt8],
    correction: ClipColorCorrection
) throws -> [UInt8] {
    let device = try colorCorrectionMetalDeviceOrSkip()
    let graph = try makeColorCorrectionGraph(correction: correction)
    let sourceTexture = try makeColorCorrectionTexture(device: device, bgraPixels: sourceBGRA)
    let executor = try MetalRenderExecutor(device: device)
    let frame = try executor.render(
        graph: graph,
        output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
        sourceProvider: ColorCorrectionTextureProvider(texture: sourceTexture)
    )

    guard let commandBuffer = frame.commandBuffer else {
        return try readColorCorrectionBGRA8(texture: frame.texture, device: device)
    }
    commandBuffer.waitUntilCompleted()
    XCTAssertNil(commandBuffer.error)
    XCTAssertEqual(commandBuffer.status, .completed)
    return try readColorCorrectionBGRA8(texture: frame.texture, device: device)
}

private func makeColorCorrectionGraph(correction: ClipColorCorrection) throws -> RenderGraph {
    let mediaID = try colorCorrectionUUID(ColorCorrectionTestIDs.media)
    let clipID = try colorCorrectionUUID(ColorCorrectionTestIDs.clip)
    let media = try makeColorCorrectionMedia(id: mediaID)
    let clip = Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try colorCorrectionRange(startFrame: 0, durationFrames: 24),
        timelineRange: try colorCorrectionRange(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Color correction synthetic",
        effects: ClipEffects(colorCorrection: correction)
    )
    let sequence = try makeColorCorrectionSequence(clip: clip)
    let project = try makeColorCorrectionProject(media: media, sequence: sequence)
    return try buildRenderGraph(for: sequence, at: try colorCorrectionTime(0), in: project)
}

private func makeColorCorrectionMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/color-correction.mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try colorCorrectionTime(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeColorCorrectionSequence(clip: Clip) throws -> Sequence {
    Sequence(
        id: UUID(),
        name: "Color correction render",
        videoTracks: [Track(id: UUID(), kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeColorCorrectionProject(media: MediaRef, sequence: Sequence) throws -> Project {
    Project(
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
}

private func makeColorCorrectionTexture(
    device: MTLDevice,
    bgraPixels: [UInt8]
) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: 1,
        height: 1,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]

    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw ColorCorrectionTextureError.textureUnavailable
    }
    guard bgraPixels.count == 4 else {
        throw ColorCorrectionTextureError.unexpectedByteCount
    }

    texture.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: bgraPixels,
        bytesPerRow: 4
    )
    return texture
}

private func readColorCorrectionBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    guard let buffer = device.makeBuffer(length: 4, options: .storageModeShared) else {
        throw ColorCorrectionTextureError.commandBufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw ColorCorrectionTextureError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw ColorCorrectionTextureError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw ColorCorrectionTextureError.blitEncoderCreationFailed
    }

    blitEncoder.copy(
        from: texture,
        sourceSlice: 0,
        sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: 1, height: 1, depth: 1),
        to: buffer,
        destinationOffset: 0,
        destinationBytesPerRow: 4,
        destinationBytesPerImage: 4
    )
    blitEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: 4)
    return Array(UnsafeBufferPointer(start: pointer, count: 4))
}

private func colorCorrectionMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

private func colorCorrectionUUID(_ string: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: string))
}

private func colorCorrectionRange(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(
        start: try colorCorrectionTime(startFrame),
        duration: try colorCorrectionTime(durationFrames)
    )
}

private func colorCorrectionTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}
