// SPDX-License-Identifier: GPL-3.0-or-later

import AjarRender
import Foundation
import Metal
import XCTest

@testable import AjarCore

final class TitleTextRasterizerTests: XCTestCase {
    func testFRTXT001FRTXT007RasterizesTitleAndReusesContentHashCache() throws {
        let device = try titleMetalDeviceOrSkip()
        let title = try makeTitleFixture(
            text: "Hello",
            color: ClipRGBColor(red: .one, green: .one, blue: .zero)
        )
        let graph = try makeTitleGraph(
            title: title,
            clipID: try titleUUID("00000000-0000-0000-0000-000000009001")
        )
        let executor = try MetalRenderExecutor(device: device)
        let output = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 64, height: 32)
        )
        let provider = ClosureRenderSourceTextureProvider { _ in
            throw TitleTestError.unexpectedSourceRequest
        }

        let first = try executor.render(graph: graph, output: output, sourceProvider: provider)
        try waitForTitleRender(first)
        let second = try executor.render(graph: graph, output: output, sourceProvider: provider)

        XCTAssertFalse(first.cacheHit)
        XCTAssertTrue(second.cacheHit)
        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertTrue(first.texture === second.texture)

        // Blit-to-shared-buffer readback (same path as AjarCLI TextureReadback / golden harness).
        let pixels = try readTitleBGRA8(texture: first.texture, device: device)
        XCTAssertTrue(
            pixels.contains(where: { $0 > 0 }),
            "expected rasterized title to write non-zero pixels"
        )
    }

    func testFRTXT001StyleChangeInvalidatesTitleCacheIdentity() throws {
        let device = try titleMetalDeviceOrSkip()
        let clipID = try titleUUID("00000000-0000-0000-0000-000000009002")
        let base = try makeTitleFixture(
            text: "Aa",
            color: ClipRGBColor(red: .one, green: .one, blue: .one)
        )
        let editedBoxes = base.boxes.map { box in
            TitleTextBox(
                id: box.id,
                text: box.text,
                origin: box.origin,
                width: box.width,
                height: box.height,
                style: TitleTextStyle(
                    fontFamily: box.style.fontFamily,
                    fontSize: RationalValue(48),
                    fontWeight: .black,
                    color: ClipRGBColor(red: .one, green: .zero, blue: .zero),
                    alignment: .center
                )
            )
        }
        let edited = TitleSource(boxes: editedBoxes)
        let baseGraph = try makeTitleGraph(title: base, clipID: clipID)
        let editedGraph = try makeTitleGraph(title: edited, clipID: clipID)
        XCTAssertNotEqual(
            baseGraph.outputNode?.contentHash,
            editedGraph.outputNode?.contentHash,
            "style change must discriminate content hash for golden/cache invalidation"
        )

        let executor = try MetalRenderExecutor(device: device)
        let output = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 64, height: 32)
        )
        let provider = ClosureRenderSourceTextureProvider { _ in
            throw TitleTestError.unexpectedSourceRequest
        }
        let baseFrame = try executor.render(
            graph: baseGraph, output: output, sourceProvider: provider
        )
        try waitForTitleRender(baseFrame)
        let editedFrame = try executor.render(
            graph: editedGraph, output: output, sourceProvider: provider
        )
        try waitForTitleRender(editedFrame)
        XCTAssertNotEqual(baseFrame.contentHash, editedFrame.contentHash)
        XCTAssertFalse(baseFrame.texture === editedFrame.texture)
    }

    func testFRTXT007EmojiAndRTLRasterizeWithoutCrash() throws {
        let device = try titleMetalDeviceOrSkip()
        let emoji = try makeTitleFixture(text: "Hello 🎬✨", color: .titleWhite)
        let rtl = try makeTitleFixture(text: "مرحبا بالعالم", color: .titleWhite)
        let emojiResult = try TitleTextRasterizer.rasterize(
            title: emoji, width: 128, height: 64, device: device
        )
        let rtlResult = try TitleTextRasterizer.rasterize(
            title: rtl, width: 128, height: 64, device: device
        )
        XCTAssertEqual(emojiResult.texture.width, 128)
        XCTAssertEqual(rtlResult.texture.height, 64)
        XCTAssertTrue(emojiResult.diagnostics.isEmpty)
        XCTAssertTrue(rtlResult.diagnostics.isEmpty)
    }

    func testFRTXT001MissingFontFallsBackDeterministically() throws {
        let device = try titleMetalDeviceOrSkip()
        let title = TitleSource(boxes: [
            TitleTextBox(
                id: try titleUUID("00000000-0000-0000-0000-000000009010"),
                text: "Fallback",
                origin: CanvasPoint(x: RationalValue(4), y: RationalValue(4)),
                width: RationalValue(120),
                height: RationalValue(40),
                style: TitleTextStyle(fontFamily: "DefinitelyNotARealFont_ZZZ_184")
            )
        ])
        let result = try TitleTextRasterizer.rasterize(
            title: title, width: 64, height: 32, device: device
        )
        XCTAssertEqual(
            result.diagnostics,
            [
                .fontUnavailable(
                    requested: "DefinitelyNotARealFont_ZZZ_184",
                    fallback: TitleTextRasterizer.deterministicFontFamily
                )
            ]
        )
        XCTAssertEqual(result.texture.width, 64)
    }

    private func makeTitleFixture(text: String, color: ClipRGBColor) throws -> TitleSource {
        TitleSource(boxes: [
            TitleTextBox(
                id: try titleUUID("00000000-0000-0000-0000-000000009100"),
                text: text,
                origin: CanvasPoint(x: RationalValue(4), y: RationalValue(4)),
                width: RationalValue(120),
                height: RationalValue(28),
                style: TitleTextStyle(
                    fontFamily: TitleSource.deterministicFontFamily,
                    fontSize: RationalValue(18),
                    fontWeight: .regular,
                    color: color,
                    alignment: .left
                )
            )
        ])
    }

    private func makeTitleGraph(title: TitleSource, clipID: UUID) throws -> RenderGraph {
        let titleNode = try RenderNodeFactory.makeTitleNode(
            clipID: clipID,
            title: title,
            colorSpace: .rec709
        )
        let composite = try RenderNodeFactory.makeCompositeNode(
            inputs: [
                RenderCompositeNodeInput(
                    node: titleNode,
                    transform: .identity,
                    effects: .none,
                    effectStack: nil,
                    trackOpacity: .one,
                    trackBlendMode: .normal
                )
            ],
            workingColorSpace: .rec709,
            outputColorSpace: .rec709
        )
        return RenderGraph(nodes: [titleNode, composite], outputNodeID: composite.id)
    }
}

private enum TitleTestError: Error {
    case unexpectedSourceRequest
    case commandBufferCreationFailed
    case commandQueueCreationFailed
    case blitEncoderCreationFailed
    case textureReadbackFailed
}

private extension ClipRGBColor {
    static let titleWhite = ClipRGBColor(red: .one, green: .one, blue: .one)
}

private func waitForTitleRender(_ frame: RenderedFrame) throws {
    guard let commandBuffer = frame.commandBuffer else {
        return
    }
    commandBuffer.waitUntilCompleted()
    if let error = commandBuffer.error {
        throw error
    }
}

private func titleMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

private func titleUUID(_ string: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: string))
}

/// Safe BGRA8 readback for private/GPU executor outputs: blit into a shared MTLBuffer then
/// copy CPU-side (mirrors `AjarCLI.TextureReadback.readBGRA8` / golden harness path).
/// Never call `MTLTexture.getBytes` on private storage — that segfaults on macos-14 CI GPUs.
private func readTitleBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw TitleTestError.textureReadbackFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw TitleTestError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw TitleTestError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw TitleTestError.blitEncoderCreationFailed
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
    if let error = commandBuffer.error {
        throw error
    }

    let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: byteCount)
    return Array(UnsafeBufferPointer(start: pointer, count: byteCount))
}
