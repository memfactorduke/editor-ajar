// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import XCTest

enum MaskTestIDs {
    static let bottomMedia = "00000000-0000-0000-0000-000000000510"
    static let topMedia = "00000000-0000-0000-0000-000000000511"
    static let singleMedia = "00000000-0000-0000-0000-000000000512"
    static let bottomClip = "00000000-0000-0000-0000-000000000610"
    static let topClip = "00000000-0000-0000-0000-000000000611"
    static let singleClip = "00000000-0000-0000-0000-000000000612"
    static let mask = "00000000-0000-0000-0000-000000000710"
}

final class MaskClipTextureProvider: RenderSourceTextureProvider {
    private let textures: [UUID: MTLTexture]

    init(textures: [UUID: MTLTexture]) {
        self.textures = textures
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = textures[source.clipID] else {
            throw MaskTextureError.metalTextureUnavailable
        }
        return texture
    }
}

enum MaskTextureError: Error {
    case metalTextureUnavailable
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case pixelBufferBaseAddressUnavailable
}

struct MaskCompositeTextures {
    let background: MTLTexture
    let source: MTLTexture
}

let maskBlue: [UInt8] = [255, 0, 0, 255]
let maskRed: [UInt8] = [0, 0, 255, 255]
let maskWhite: [UInt8] = [255, 255, 255, 255]
let maskClear: [UInt8] = [0, 0, 0, 0]

func makeMaskCompositeTextures(device: MTLDevice) throws -> MaskCompositeTextures {
    MaskCompositeTextures(
        background: try makeMaskTexture(
            device: device,
            width: 4,
            height: 1,
            bgraPixels: repeatedMaskBGRA(maskBlue, count: 4)
        ),
        source: try makeMaskTexture(
            device: device,
            width: 4,
            height: 1,
            bgraPixels: repeatedMaskBGRA(maskRed, count: 4)
        )
    )
}

func renderMaskSingleClipPixels(
    device: MTLDevice,
    effects: ClipEffects,
    texture: MTLTexture,
    width: Int,
    height: Int
) throws -> [UInt8] {
    try renderMaskPixels(
        device: device,
        graph: try makeMaskSingleClipGraph(effects: effects, width: width, height: height),
        textures: [try maskUUID(MaskTestIDs.singleClip): texture],
        outputWidth: width,
        outputHeight: height
    )
}

func renderMaskTwoClipPixels(
    device: MTLDevice,
    topEffects: ClipEffects,
    topTransform: ClipTransform = .identity,
    bottomTexture: MTLTexture,
    topTexture: MTLTexture,
    dimensions: PixelDimensions
) throws -> [UInt8] {
    try renderMaskPixels(
        device: device,
        graph: try makeMaskTwoClipGraph(
            topEffects: topEffects,
            topTransform: topTransform,
            width: dimensions.width,
            height: dimensions.height
        ),
        textures: [
            try maskUUID(MaskTestIDs.bottomClip): bottomTexture,
            try maskUUID(MaskTestIDs.topClip): topTexture
        ],
        outputWidth: dimensions.width,
        outputHeight: dimensions.height
    )
}

func renderMaskPixels(
    device: MTLDevice,
    graph: RenderGraph,
    textures: [UUID: MTLTexture],
    outputWidth: Int,
    outputHeight: Int
) throws -> [UInt8] {
    let executor = try MetalRenderExecutor(device: device)
    let frame = try executor.render(
        graph: graph,
        output: RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: outputWidth, height: outputHeight)
        ),
        sourceProvider: MaskClipTextureProvider(textures: textures)
    )
    try waitForMaskRender(frame)
    return try readMaskBGRA8(texture: frame.texture, device: device)
}

func makeMaskSingleClipGraph(
    effects: ClipEffects,
    width: Int,
    height: Int
) throws -> RenderGraph {
    let mediaID = try maskUUID(MaskTestIDs.singleMedia)
    let clipID = try maskUUID(MaskTestIDs.singleClip)
    let sequence = try makeMaskSequence(
        clips: [
            try makeMaskRenderClip(id: clipID, mediaID: mediaID, effects: effects)
        ],
        width: width,
        height: height
    )
    let project = try makeMaskProject(
        mediaPool: [try makeMaskRenderMedia(id: mediaID, width: width, height: height)],
        sequence: sequence,
        width: width,
        height: height
    )

    return try buildRenderGraph(for: sequence, at: try maskTime(0), in: project)
}

func makeMaskTwoClipGraph(
    topEffects: ClipEffects,
    topTransform: ClipTransform = .identity,
    width: Int,
    height: Int
) throws -> RenderGraph {
    let bottomMediaID = try maskUUID(MaskTestIDs.bottomMedia)
    let topMediaID = try maskUUID(MaskTestIDs.topMedia)
    let sequence = try makeMaskSequence(
        clips: [
            try makeMaskRenderClip(
                id: try maskUUID(MaskTestIDs.bottomClip),
                mediaID: bottomMediaID,
                effects: .none
            ),
            try makeMaskRenderClip(
                id: try maskUUID(MaskTestIDs.topClip),
                mediaID: topMediaID,
                effects: topEffects,
                transform: topTransform
            )
        ],
        width: width,
        height: height
    )
    let project = try makeMaskProject(
        mediaPool: [
            try makeMaskRenderMedia(id: bottomMediaID, width: width, height: height),
            try makeMaskRenderMedia(id: topMediaID, width: width, height: height)
        ],
        sequence: sequence,
        width: width,
        height: height
    )

    return try buildRenderGraph(for: sequence, at: try maskTime(0), in: project)
}

func makeMaskSequence(
    clips: [Clip],
    width: Int,
    height: Int
) throws -> Sequence {
    Sequence(
        id: UUID(),
        name: "Mask \(width)x\(height)",
        videoTracks: clips.map { clip in
            Track(id: UUID(), kind: .video, items: [.clip(clip)])
        },
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

func makeMaskProject(
    mediaPool: [MediaRef],
    sequence: Sequence,
    width: Int,
    height: Int
) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 24),
            resolution: PixelDimensions(width: width, height: height),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: mediaPool,
        sequences: [sequence]
    )
}

func makeMaskRenderMedia(id: UUID, width: Int, height: Int) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: width, height: height),
            frameRate: try FrameRate(frames: 24),
            duration: try maskTime(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

func makeMaskRenderClip(
    id: UUID,
    mediaID: UUID,
    effects: ClipEffects,
    transform: ClipTransform = .identity
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try maskRange(startFrame: 0, durationFrames: 24),
        timelineRange: try maskRange(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Synthetic mask clip",
        transform: transform,
        effects: effects
    )
}

func makeMaskTexture(
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
        throw MaskTextureError.metalTextureUnavailable
    }
    guard bgraPixels.count == width * height * 4 else {
        throw MaskTextureError.pixelBufferBaseAddressUnavailable
    }

    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: bgraPixels,
        bytesPerRow: width * 4
    )
    return texture
}

func readMaskBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw MaskTextureError.commandBufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw MaskTextureError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw MaskTextureError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw MaskTextureError.blitEncoderCreationFailed
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

func makeMaskRectangle(
    x: Int64,
    y: Int64,
    width: Int64,
    height: Int64
) throws -> ClipMask {
    try makeMaskRectangle(
        spec: MaskRectangleSpec(x: x, y: y, width: width, height: height)
    )
}

func makeMaskRectangle(
    x: Int64,
    y: Int64,
    width: Int64,
    height: Int64,
    featherRadius: RationalValue
) throws -> ClipMask {
    try makeMaskRectangle(
        spec: MaskRectangleSpec(
            x: x,
            y: y,
            width: width,
            height: height,
            featherRadius: featherRadius
        )
    )
}

func makeMaskRectangle(
    x: Int64,
    y: Int64,
    width: Int64,
    height: Int64,
    invert: Bool
) throws -> ClipMask {
    try makeMaskRectangle(
        spec: MaskRectangleSpec(x: x, y: y, width: width, height: height, invert: invert)
    )
}

func makeMaskRectangle(
    x: Int64,
    y: Int64,
    width: Int64,
    height: Int64,
    combine: ClipMaskCombineOperation
) throws -> ClipMask {
    try makeMaskRectangle(
        spec: MaskRectangleSpec(x: x, y: y, width: width, height: height, combine: combine)
    )
}

func makeMaskEllipse(
    centerX: Int64,
    centerY: Int64,
    radiusX: Int64,
    radiusY: Int64
) throws -> ClipMask {
    ClipMask(
        id: try maskUUID(MaskTestIDs.mask),
        shape: .ellipse(
            ClipEllipseMask(
                centerX: try RationalValue(numerator: centerX, denominator: 2),
                centerY: try RationalValue(numerator: centerY, denominator: 2),
                radiusX: try RationalValue(numerator: radiusX, denominator: 2),
                radiusY: try RationalValue(numerator: radiusY, denominator: 2)
            )
        )
    )
}

func maskPoint(_ x: Int64, _ y: Int64) throws -> CanvasPoint {
    CanvasPoint(x: RationalValue(x), y: RationalValue(y))
}

func repeatedMaskBGRA(_ pixel: [UInt8], count: Int) -> [UInt8] {
    var pixels: [UInt8] = []
    pixels.reserveCapacity(pixel.count * count)
    for _ in 0..<count {
        pixels.append(contentsOf: pixel)
    }
    return pixels
}

func waitForMaskRender(_ frame: RenderedFrame) throws {
    guard let commandBuffer = frame.commandBuffer else {
        return
    }

    commandBuffer.waitUntilCompleted()
    XCTAssertNil(commandBuffer.error)
    XCTAssertEqual(commandBuffer.status, .completed)
}

func maskMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

func maskUUID(_ string: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: string))
}

func maskRange(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: try maskTime(startFrame), duration: try maskTime(durationFrames))
}

func maskTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

struct MaskRectangleSpec {
    let x: Int64
    let y: Int64
    let width: Int64
    let height: Int64
    var featherRadius: RationalValue = .zero
    var invert = false
    var combine = ClipMaskCombineOperation.add
}

func makeMaskRectangle(spec: MaskRectangleSpec) throws -> ClipMask {
    ClipMask(
        id: try maskUUID(MaskTestIDs.mask),
        shape: .rectangle(
            ClipRectangleMask(
                x: RationalValue(spec.x),
                y: RationalValue(spec.y),
                width: RationalValue(spec.width),
                height: RationalValue(spec.height)
            )
        ),
        featherRadius: spec.featherRadius,
        invert: spec.invert,
        combine: spec.combine
    )
}
