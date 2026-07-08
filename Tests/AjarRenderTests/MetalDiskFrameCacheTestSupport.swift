// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import XCTest

enum DiskCacheTestError: Error {
    case unexpectedSourceRequest
    case textureCreationFailed
    case readbackFailed
    case cacheEntryFileMissing
}

enum DiskCacheTestIDs {
    static let media = "76A3B7BE-51D0-4374-8E20-6E043C1BE3B0"
    static let clip = "0F3C23BE-9A22-4A26-99D5-3B4E1F5C6A70"
}

func diskCacheTestDevice() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

func makeDiskCacheTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("editor-ajar-tests")
        .appendingPathComponent("disk-frame-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Builds a deterministic single-clip 1x1 graph; different `positionX` values model an edit
/// that changes the render graph output content hash.
func makeDiskCacheTestGraph(positionX: Int64 = 0) throws -> RenderGraph {
    let mediaID = try diskCacheTestUUID(DiskCacheTestIDs.media)
    let clipID = try diskCacheTestUUID(DiskCacheTestIDs.clip)
    let media = MediaRef(
        id: mediaID,
        sourceURL: URL(fileURLWithPath: "/media/disk-cache.mov"),
        contentHash: ContentHash.sha256(data: Data("disk-cache".utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try diskCacheTestTime(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try diskCacheTestRange(durationFrames: 24),
        timelineRange: try diskCacheTestRange(durationFrames: 24),
        kind: .video,
        name: "DiskCache",
        transform: ClipTransform(
            position: CanvasPoint(x: RationalValue(positionX), y: RationalValue(0))
        )
    )
    let sequence = AjarCore.Sequence(
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
        name: "DiskCacheRender",
        videoTracks: [
            Track(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)),
                kind: .video,
                items: [.clip(clip)]
            )
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
        mediaPool: [media],
        sequences: [sequence]
    )

    return try buildRenderGraph(
        for: sequence,
        at: try RationalTime(value: 0, timescale: 24),
        in: project
    )
}

func makeDiskCacheSolidTexture(device: MTLDevice, bgra: [UInt8]) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: 1,
        height: 1,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw DiskCacheTestError.textureCreationFailed
    }
    texture.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: bgra,
        bytesPerRow: 4
    )
    return texture
}

func readDiskCacheBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
          let commandQueue = device.makeCommandQueue(),
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw DiskCacheTestError.readbackFailed
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

func waitForDiskCacheRender(_ frame: RenderedFrame) throws {
    guard let commandBuffer = frame.commandBuffer else {
        return
    }
    commandBuffer.waitUntilCompleted()
    XCTAssertNil(commandBuffer.error)
}

func diskCacheEntryFileURLs(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "ajarframe" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func diskCacheTestUUID(_ string: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: string))
}

private func diskCacheTestTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func diskCacheTestRange(durationFrames: Int64) throws -> TimeRange {
    try TimeRange(
        start: try diskCacheTestTime(0),
        duration: try diskCacheTestTime(durationFrames)
    )
}
