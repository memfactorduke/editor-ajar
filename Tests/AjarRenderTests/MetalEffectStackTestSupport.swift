// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarRender

// Shared fixtures for FR-FX-002 Metal effect-stack tests.

func effectStackMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

func effectStackUUID(_ value: Int) throws -> UUID {
    let string = String(format: "00000000-0000-0000-0000-%012d", value)
    guard let uuid = UUID(uuidString: string) else {
        throw EffectStackDiscriminationError.invalidUUID
    }
    return uuid
}

enum EffectStackDiscriminationError: Error {
    case textureUnavailable
    case bufferUnavailable
    case commandQueueUnavailable
    case commandBufferUnavailable
    case blitUnavailable
    case invalidUUID
}

final class EffectStackTextureProvider: RenderSourceTextureProvider {
    private let texture: MTLTexture

    init(texture: MTLTexture) {
        self.texture = texture
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        texture
    }
}

/// Mid-tone BGRA checkerboard for FR-FX discrimination (blur / sharpen / glow).
///
/// Saturated binary red/blue is invariant under sharpen-with-clamp; keep midtones with
/// headroom so unsharp overshoot is representable (NFR-QUAL-001).
func makeCheckerboardTexture(
    device: MTLDevice,
    size: Int,
    cellSize: Int
) throws -> MTLTexture {
    // Midtones (not 0/255): colorA = BGRA(64,96,160,255), colorB = BGRA(160,96,64,255).
    let colorA: [UInt8] = [64, 96, 160, 255]
    let colorB: [UInt8] = [160, 96, 64, 255]
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for yPosition in 0..<size {
        for xPosition in 0..<size {
            let useA = ((xPosition / cellSize) + (yPosition / cellSize)).isMultiple(of: 2)
            let color = useA ? colorA : colorB
            let offset = ((yPosition * size) + xPosition) * 4
            pixels[offset] = color[0]
            pixels[offset + 1] = color[1]
            pixels[offset + 2] = color[2]
            pixels[offset + 3] = color[3]
        }
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: size,
        height: size,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw EffectStackDiscriminationError.textureUnavailable
    }
    pixels.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else {
            return
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: base,
            bytesPerRow: size * 4
        )
    }
    return texture
}

func readEffectStackBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw EffectStackDiscriminationError.bufferUnavailable
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw EffectStackDiscriminationError.commandQueueUnavailable
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw EffectStackDiscriminationError.commandBufferUnavailable
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw EffectStackDiscriminationError.blitUnavailable
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

/// Fraction of pixels whose any BGRA channel differs by more than `channelDeltaThreshold`.
func changedPixelFraction(
    left: [UInt8],
    right: [UInt8],
    channelDeltaThreshold: Int
) -> Double {
    precondition(left.count == right.count)
    precondition(left.count.isMultiple(of: 4))
    let pixelCount = left.count / 4
    var changed = 0
    var index = 0
    while index < left.count {
        let d0 = abs(Int(left[index]) - Int(right[index]))
        let d1 = abs(Int(left[index + 1]) - Int(right[index + 1]))
        let d2 = abs(Int(left[index + 2]) - Int(right[index + 2]))
        let d3 = abs(Int(left[index + 3]) - Int(right[index + 3]))
        if max(d0, max(d1, max(d2, d3))) > channelDeltaThreshold {
            changed += 1
        }
        index += 4
    }
    return Double(changed) / Double(pixelCount)
}

func waitForEffectStackFrame(_ frame: RenderedFrame) {
    if let commandBuffer = frame.commandBuffer {
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        XCTAssertEqual(commandBuffer.status, .completed)
    }
}

func effectStackMediaRef(id: UUID, size: Int, path: String) throws -> MediaRef {
    let frameRate = try FrameRate(frames: 24)
    let duration = try RationalTime.atFrame(24, frameRate: frameRate)
    return MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: path),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: size, height: size),
            frameRate: frameRate,
            duration: duration,
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

func effectStackProjectSettings(size: Int) throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: size, height: size),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}

func renderEffectStackGraph(
    device: MTLDevice,
    source: MTLTexture,
    size: Int,
    graph: RenderGraph
) throws -> [UInt8] {
    let executor = try MetalRenderExecutor(device: device)
    let frame = try executor.render(
        graph: graph,
        output: RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: size, height: size)
        ),
        sourceProvider: EffectStackTextureProvider(texture: source)
    )
    waitForEffectStackFrame(frame)
    return try readEffectStackBGRA8(texture: frame.texture, device: device)
}

func makeEffectStackGraph(size: Int, stack: ClipEffectStack) throws -> RenderGraph {
    let mediaID = try effectStackUUID(6_001)
    let clipID = try effectStackUUID(6_002)
    let frameRate = try FrameRate(frames: 24)
    let duration = try RationalTime.atFrame(24, frameRate: frameRate)
    let media = try effectStackMediaRef(
        id: mediaID,
        size: size,
        path: "/media/effect-stack-discrimination.mov"
    )
    let clip = Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(start: .zero, duration: duration),
        kind: .video,
        name: "Effect stack discrimination",
        effectStack: stack
    )
    let sequence = Sequence(
        id: try effectStackUUID(6_003),
        name: "Effect stack discrimination",
        videoTracks: [
            Track(id: try effectStackUUID(6_004), kind: .video, items: [.clip(clip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: frameRate
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try effectStackProjectSettings(size: size),
        mediaPool: [media],
        sequences: [sequence]
    )
    return try buildRenderGraph(
        for: sequence,
        at: try RationalTime.atFrame(0, frameRate: frameRate),
        in: project
    )
}

/// Nested media under a compound outer clip that carries `stack` (linear effect path).
func makeCompoundOuterEffectStackGraph(
    size: Int,
    stack: ClipEffectStack
) throws -> RenderGraph {
    let mediaID = try effectStackUUID(6_011)
    let innerClipID = try effectStackUUID(6_012)
    let innerSequenceID = try effectStackUUID(6_013)
    let compoundClipID = try effectStackUUID(6_014)
    let frameRate = try FrameRate(frames: 24)
    let duration = try RationalTime.atFrame(24, frameRate: frameRate)
    let media = try effectStackMediaRef(
        id: mediaID,
        size: size,
        path: "/media/effect-stack-compound.mov"
    )
    let range = try TimeRange(start: .zero, duration: duration)
    let innerClip = Clip(
        id: innerClipID,
        source: .media(id: mediaID),
        sourceRange: range,
        timelineRange: range,
        kind: .video,
        name: "Inner media"
    )
    let compoundClip = Clip(
        id: compoundClipID,
        source: .sequence(id: innerSequenceID),
        sourceRange: range,
        timelineRange: range,
        kind: .video,
        name: "Compound with effects",
        effectStack: stack
    )
    let outerSequence = Sequence(
        id: try effectStackUUID(6_015),
        name: "Outer",
        videoTracks: [
            Track(id: try effectStackUUID(6_016), kind: .video, items: [.clip(compoundClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: frameRate
    )
    let innerSequence = Sequence(
        id: innerSequenceID,
        name: "Inner",
        videoTracks: [
            Track(id: try effectStackUUID(6_017), kind: .video, items: [.clip(innerClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: frameRate
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try effectStackProjectSettings(size: size),
        mediaPool: [media],
        sequences: [outerSequence, innerSequence]
    )
    return try buildRenderGraph(
        for: outerSequence,
        at: try RationalTime.atFrame(0, frameRate: frameRate),
        in: project
    )
}
