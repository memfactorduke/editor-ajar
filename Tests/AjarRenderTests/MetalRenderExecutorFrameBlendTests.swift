// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import XCTest

/// FR-SPD-004 executor coverage: the frame-blend pass mixes the two adjacent decoded frames in
/// linear working space, and the nearest/default paths never pay for it.
final class MetalRenderExecutorFrameBlendTests: XCTestCase {
    func testFRSPD004BlendsAdjacentFramesInLinearWorkingSpace() throws {
        let device = try blendMetalDeviceOrSkip()
        let graph = try makeFrameBlendGraph(frameSampling: .frameBlend)
        let provider = FrameBlendCountingProvider(
            single: try makeBlendTexture(device: device, bgra: [0, 0, 255, 255]),
            blend: RenderSourceFrameBlendTextures(
                earlierTexture: try makeBlendTexture(device: device, bgra: [0, 0, 255, 255]),
                laterTexture: try makeBlendTexture(device: device, bgra: [255, 0, 0, 255]),
                laterWeight: 0.5
            )
        )
        let executor = try MetalRenderExecutor(device: device)

        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: provider
        )
        try waitForBlendRender(frame)

        // Half red + half blue mixed in LINEAR light then re-encoded with the Rec.709 OETF:
        // encode(0.5) = 1.099 * 0.5^0.45 - 0.099 = 0.7047 -> byte 180. A display-encoded
        // (wrong-space) blend would produce byte 128 instead.
        XCTAssertEqual(provider.blendRequestCount, 1)
        XCTAssertEqual(provider.singleRequestCount, 0)
        let pixel = try readBlendBGRA8(texture: frame.texture, device: device)
        XCTAssertEqual(pixel.count, 4)
        XCTAssertEqual(pixel[3], 255)
        XCTAssertEqual(pixel[1], 0)
        assertChannel(pixel[0], near: 180)
        assertChannel(pixel[2], near: 180)
    }

    func testFRSPD004NearestDefaultNeverConsultsBlendProviderOrExtraPasses() throws {
        let device = try blendMetalDeviceOrSkip()
        let graph = try makeFrameBlendGraph(frameSampling: .nearest)
        let provider = FrameBlendCountingProvider(
            single: try makeBlendTexture(device: device, bgra: [0, 0, 255, 255]),
            blend: nil
        )
        let executor = try MetalRenderExecutor(device: device)

        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: provider
        )
        try waitForBlendRender(frame)

        XCTAssertEqual(provider.blendRequestCount, 0)
        XCTAssertEqual(provider.singleRequestCount, 1)
        XCTAssertEqual(
            try readBlendBGRA8(texture: frame.texture, device: device),
            [0, 0, 255, 255]
        )
    }

    func testFRSPD004NilBlendTexturesFallBackToNearestSingleFramePath() throws {
        let device = try blendMetalDeviceOrSkip()
        let graph = try makeFrameBlendGraph(frameSampling: .frameBlend)
        let provider = FrameBlendCountingProvider(
            single: try makeBlendTexture(device: device, bgra: [0, 0, 255, 255]),
            blend: nil
        )
        let executor = try MetalRenderExecutor(device: device)

        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: provider
        )
        try waitForBlendRender(frame)

        XCTAssertEqual(provider.blendRequestCount, 1)
        XCTAssertEqual(provider.singleRequestCount, 1)
        XCTAssertEqual(
            try readBlendBGRA8(texture: frame.texture, device: device),
            [0, 0, 255, 255]
        )
    }

    func testFRSPD004DegenerateWeightFallsBackToNearestSingleFramePath() throws {
        let device = try blendMetalDeviceOrSkip()
        let graph = try makeFrameBlendGraph(frameSampling: .frameBlend)
        let provider = FrameBlendCountingProvider(
            single: try makeBlendTexture(device: device, bgra: [0, 0, 255, 255]),
            blend: RenderSourceFrameBlendTextures(
                earlierTexture: try makeBlendTexture(device: device, bgra: [0, 0, 255, 255]),
                laterTexture: try makeBlendTexture(device: device, bgra: [255, 0, 0, 255]),
                laterWeight: 0
            )
        )
        let executor = try MetalRenderExecutor(device: device)

        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: provider
        )
        try waitForBlendRender(frame)

        XCTAssertEqual(provider.singleRequestCount, 1)
        XCTAssertEqual(
            try readBlendBGRA8(texture: frame.texture, device: device),
            [0, 0, 255, 255]
        )
    }

    private func assertChannel(
        _ actual: UInt8,
        near expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            abs(Int(actual) - expected),
            3,
            "channel \(actual) not within 3 of \(expected)",
            file: file,
            line: line
        )
    }
}

private final class FrameBlendCountingProvider: RenderSourceTextureProvider {
    private let single: MTLTexture
    private let blend: RenderSourceFrameBlendTextures?
    private(set) var singleRequestCount = 0
    private(set) var blendRequestCount = 0

    init(single: MTLTexture, blend: RenderSourceFrameBlendTextures?) {
        self.single = single
        self.blend = blend
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        singleRequestCount += 1
        return single
    }

    func frameBlendTextures(
        for source: RenderSourceNode
    ) throws -> RenderSourceFrameBlendTextures? {
        blendRequestCount += 1
        return blend
    }
}

/// Builds a single-clip graph whose clip carries the FR-SPD-004 sampling mode and resolves a
/// fractional source frame position (1/2x speed sampled at an odd timeline frame).
private func makeFrameBlendGraph(frameSampling: ClipFrameSamplingMode) throws -> RenderGraph {
    let mediaID = try blendUUID(7_001)
    let media = MediaRef(
        id: mediaID,
        sourceURL: URL(fileURLWithPath: "/media/frame-blend.mov"),
        contentHash: ContentHash.sha256(data: Data("frame-blend".utf8)),
        metadata: MediaMetadata(
            codecID: "prores4444",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try blendTime(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: try blendUUID(7_002),
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: blendTime(0), duration: blendTime(24)),
        timelineRange: try TimeRange(start: blendTime(0), duration: blendTime(48)),
        kind: .video,
        name: "FR-SPD-004 blend clip",
        speed: try RationalValue(numerator: 1, denominator: 2),
        frameSampling: frameSampling
    )
    let sequence = Sequence(
        id: try blendUUID(7_003),
        name: "FR-SPD-004 blend sequence",
        videoTracks: [Track(id: try blendUUID(7_004), kind: .video, items: [.clip(clip)])],
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

    // Timeline frame 3 -> source frame 1.5: a strictly fractional source frame position.
    return try buildRenderGraph(for: sequence, at: try blendTime(3), in: project)
}

private func makeBlendTexture(device: MTLDevice, bgra: [UInt8]) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: 1,
        height: 1,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]

    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw FrameBlendTestError.textureCreationFailed
    }
    texture.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: bgra,
        bytesPerRow: 4
    )
    return texture
}

private func readBlendBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw FrameBlendTestError.readbackFailed
    }
    guard let commandQueue = device.makeCommandQueue(),
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let blitEncoder = commandBuffer.makeBlitCommandEncoder()
    else {
        throw FrameBlendTestError.readbackFailed
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

private func waitForBlendRender(_ frame: RenderedFrame) throws {
    guard let commandBuffer = frame.commandBuffer else {
        return
    }

    commandBuffer.waitUntilCompleted()
    XCTAssertNil(commandBuffer.error)
    XCTAssertEqual(commandBuffer.status, .completed)
}

private func blendMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

private func blendTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func blendUUID(_ value: Int) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)))
}

private enum FrameBlendTestError: Error {
    case textureCreationFailed
    case readbackFailed
}
