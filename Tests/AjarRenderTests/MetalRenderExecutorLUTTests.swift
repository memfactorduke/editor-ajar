// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarRender

/// FR-COL-004 GPU LUT application coverage.
final class MetalRenderExecutorLUTTests: XCTestCase {
    func testFRCOL004StrengthZeroIsBitIdenticalToNoLUT() throws {
        let device = try lutMetalDeviceOrSkip()
        let sourceBGRA: [UInt8] = [64, 96, 160, 255]
        let table = try makeRenderInvertCube(size: 8)

        let withoutLUT = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: .empty
        )
        let strengthZero = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try lutUUID(LUTTestIDs.node),
                        definition: .lut(
                            ClipLUTEffectParameters(table: table, strength: .zero)
                        )
                    )
                ]
            )
        )

        XCTAssertEqual(withoutLUT, strengthZero)
        XCTAssertEqual(
            ContentHash.sha256(data: Data(withoutLUT)),
            ContentHash.sha256(data: Data(strengthZero))
        )
    }

    /// Texel-center remap: identity 1D ramps of size 2 and 33 preserve a mid-grey patch.
    func testFRCOL004IdentityRampTexelCenterExactForSizes2And33() throws {
        let device = try lutMetalDeviceOrSkip()
        // Display-encoded mid-grey patch; identity LUT in linear after decode must round-trip.
        let sourceBGRA: [UInt8] = [64, 64, 64, 255]
        let baseline = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: .empty
        )

        for size in [2, 33] {
            let identity = CubeLUTTable.identityOneD(size: size)
            let withIdentity = try renderLUTPixels(
                device: device,
                sourceBGRA: sourceBGRA,
                effectStack: ClipEffectStack(
                    nodes: [
                        ClipEffectNode(
                            id: try lutUUID(LUTTestIDs.node),
                            definition: .lut(
                                ClipLUTEffectParameters(table: identity, strength: .one)
                            )
                        )
                    ]
                )
            )
            // Bit-identical to no-LUT (identity + texel centers, not left-edge sampling).
            XCTAssertEqual(
                withIdentity,
                baseline,
                "identity 1D size \(size) must match no-LUT (texel-center sampling)"
            )
        }
    }

    /// All enabled LUT nodes compose in stack order (invert then half-strength teal).
    func testFRCOL004TwoLUTsComposeSequentiallyInStackOrder() throws {
        let device = try lutMetalDeviceOrSkip()
        let sourceBGRA: [UInt8] = [80, 100, 140, 255]
        let invert = try makeRenderInvertCube(size: 8)
        let teal = try makeRenderTealCube(size: 8)
        let half = try RationalValue(numerator: 1, denominator: 2)

        let stacked = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: try twoNodeStack(
                invert: invert,
                teal: teal,
                invertStrength: .one,
                tealStrength: half
            )
        )
        let invertOnly = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: try singleNodeStack(id: LUTTestIDs.node, table: invert, strength: .one)
        )
        let tealOnly = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: try singleNodeStack(id: LUTTestIDs.nodeB, table: teal, strength: half)
        )
        XCTAssertNotEqual(stacked, invertOnly)
        XCTAssertNotEqual(stacked, tealOnly)

        let zeroThenTeal = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: try twoNodeStack(
                invert: invert,
                teal: teal,
                invertStrength: .zero,
                tealStrength: .one
            )
        )
        let tealFull = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: try singleNodeStack(id: LUTTestIDs.nodeB, table: teal, strength: .one)
        )
        XCTAssertEqual(zeroThenTeal, tealFull)
    }

    func testFRCOL004FullStrengthInvertChangesPixels() throws {
        let device = try lutMetalDeviceOrSkip()
        let sourceBGRA: [UInt8] = [64, 96, 160, 255]
        let table = try makeRenderInvertCube(size: 8)

        let baseline = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: .empty
        )
        let inverted = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try lutUUID(LUTTestIDs.node),
                        definition: .lut(
                            ClipLUTEffectParameters(table: table, strength: .one)
                        )
                    )
                ]
            )
        )

        XCTAssertNotEqual(baseline, inverted)
        XCTAssertEqual(inverted[3], 255)
    }

    func testFRCOL004HalfStrengthIsBetweenIdentityAndFull() throws {
        let device = try lutMetalDeviceOrSkip()
        let sourceBGRA: [UInt8] = [80, 80, 80, 255]
        let table = try makeRenderInvertCube(size: 8)

        let identity = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: .empty
        )
        let half = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try lutUUID(LUTTestIDs.node),
                        definition: .lut(
                            ClipLUTEffectParameters(
                                table: table,
                                strength: try RationalValue(numerator: 1, denominator: 2)
                            )
                        )
                    )
                ]
            )
        )
        let full = try renderLUTPixels(
            device: device,
            sourceBGRA: sourceBGRA,
            effectStack: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try lutUUID(LUTTestIDs.node),
                        definition: .lut(
                            ClipLUTEffectParameters(table: table, strength: .one)
                        )
                    )
                ]
            )
        )

        let identityLuma = Int(identity[0])
        let halfLuma = Int(half[0])
        let fullLuma = Int(full[0])
        let lo = min(identityLuma, fullLuma)
        let hi = max(identityLuma, fullLuma)
        XCTAssertGreaterThanOrEqual(halfLuma, lo - 1)
        XCTAssertLessThanOrEqual(halfLuma, hi + 1)
        XCTAssertNotEqual(half, identity)
        XCTAssertNotEqual(half, full)
    }
}

// MARK: - Helpers

private enum LUTTestIDs {
    static let media = "00000000-0000-0000-0000-000000000618"
    static let clip = "00000000-0000-0000-0000-000000000718"
    static let node = "00000000-0000-0000-0000-000000000818"
    static let nodeB = "00000000-0000-0000-0000-000000000819"
}

private func lutMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable")
    }
    return device
}

private func lutUUID(_ raw: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: raw))
}

private func singleNodeStack(
    id: String,
    table: CubeLUTTable,
    strength: RationalValue
) throws -> ClipEffectStack {
    ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: try lutUUID(id),
                definition: .lut(ClipLUTEffectParameters(table: table, strength: strength))
            )
        ]
    )
}

private func twoNodeStack(
    invert: CubeLUTTable,
    teal: CubeLUTTable,
    invertStrength: RationalValue,
    tealStrength: RationalValue
) throws -> ClipEffectStack {
    ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: try lutUUID(LUTTestIDs.node),
                definition: .lut(
                    ClipLUTEffectParameters(table: invert, strength: invertStrength)
                )
            ),
            ClipEffectNode(
                id: try lutUUID(LUTTestIDs.nodeB),
                definition: .lut(
                    ClipLUTEffectParameters(table: teal, strength: tealStrength)
                )
            )
        ]
    )
}

private func renderLUTPixels(
    device: MTLDevice,
    sourceBGRA: [UInt8],
    effectStack: ClipEffectStack
) throws -> [UInt8] {
    let graph = try makeLUTGraph(effectStack: effectStack)
    let sourceTexture = try makeLUTTexture(device: device, bgraPixels: sourceBGRA)
    let executor = try MetalRenderExecutor(device: device)
    let frame = try executor.render(
        graph: graph,
        output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
        sourceProvider: LUTTextureProvider(texture: sourceTexture)
    )

    if let commandBuffer = frame.commandBuffer {
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        XCTAssertEqual(commandBuffer.status, .completed)
    }
    return try readLUTBGRA8(texture: frame.texture, device: device)
}

private func makeLUTGraph(effectStack: ClipEffectStack) throws -> RenderGraph {
    let mediaID = try lutUUID(LUTTestIDs.media)
    let clipID = try lutUUID(LUTTestIDs.clip)
    let media = MediaRef(
        id: mediaID,
        sourceURL: URL(fileURLWithPath: "/media/lut.mov"),
        contentHash: ContentHash.sha256(data: Data(mediaID.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try RationalTime.atFrame(24, frameRate: FrameRate(frames: 24)),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(
            start: .zero,
            duration: try RationalTime.atFrame(24, frameRate: FrameRate(frames: 24))
        ),
        timelineRange: try TimeRange(
            start: .zero,
            duration: try RationalTime.atFrame(24, frameRate: FrameRate(frames: 24))
        ),
        kind: .video,
        name: "LUT synthetic",
        effectStack: effectStack
    )
    let sequence = Sequence(
        id: UUID(),
        name: "LUT render",
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
    return try buildRenderGraph(
        for: sequence,
        at: try RationalTime.atFrame(0, frameRate: FrameRate(frames: 24)),
        in: project
    )
}

private func makeLUTTexture(device: MTLDevice, bgraPixels: [UInt8]) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: 1,
        height: 1,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw LUTTextureError.textureUnavailable
    }
    texture.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: bgraPixels,
        bytesPerRow: 4
    )
    return texture
}

private func readLUTBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    guard let buffer = device.makeBuffer(length: 4, options: .storageModeShared) else {
        throw LUTTextureError.commandBufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw LUTTextureError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw LUTTextureError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw LUTTextureError.blitEncoderCreationFailed
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

private func makeRenderInvertCube(size: Int) throws -> CubeLUTTable {
    var entries: [CubeLUTColor] = []
    entries.reserveCapacity(size * size * size)
    let denom = Float(max(size - 1, 1))
    for blue in 0..<size {
        for green in 0..<size {
            for red in 0..<size {
                entries.append(
                    CubeLUTColor(
                        r: 1.0 - (Float(red) / denom),
                        g: 1.0 - (Float(green) / denom),
                        b: 1.0 - (Float(blue) / denom)
                    )
                )
            }
        }
    }
    return try unwrapValidated(
        CubeLUTTable(
            title: "Invert \(size)",
            dimensions: .threeD,
            size: size,
            entries: entries
        )
    )
}

private func makeRenderTealCube(size: Int) throws -> CubeLUTTable {
    var entries: [CubeLUTColor] = []
    entries.reserveCapacity(size * size * size)
    let denom = Float(max(size - 1, 1))
    for blue in 0..<size {
        for green in 0..<size {
            for red in 0..<size {
                let r = Float(red) / denom
                let g = Float(green) / denom
                let b = Float(blue) / denom
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                entries.append(
                    CubeLUTColor(
                        r: min(1.0, r + (luma * 0.2)),
                        g: g,
                        b: min(1.0, b + ((1.0 - luma) * 0.2))
                    )
                )
            }
        }
    }
    return try unwrapValidated(
        CubeLUTTable(
            title: "Teal \(size)",
            dimensions: .threeD,
            size: size,
            entries: entries
        )
    )
}

private func unwrapValidated(_ table: CubeLUTTable) throws -> CubeLUTTable {
    switch table.validated() {
    case .success(let valid):
        return valid
    case .failure(let error):
        throw error
    }
}

private final class LUTTextureProvider: RenderSourceTextureProvider {
    let texture: MTLTexture

    init(texture: MTLTexture) {
        self.texture = texture
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        texture
    }
}

private enum LUTTextureError: Error {
    case textureUnavailable
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
}
