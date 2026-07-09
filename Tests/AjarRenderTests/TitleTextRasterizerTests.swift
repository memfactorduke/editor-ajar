// SPDX-License-Identifier: GPL-3.0-or-later

import AjarRender
import Foundation
import Metal
import XCTest

@testable import AjarCore

// TEMP #184 diagnostics — unbuffered stderr so phase lines survive XCTest worker death on CI.
private func titleTrace(_ message: String) {
    fputs("TITLETRACE: " + message + "\n", stderr)
    fflush(stderr)
}

final class TitleTextRasterizerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // TEMP #184 diagnostics — enable production-side TITLETRACE-R: lines in AjarRender.
        setenv("AJAR_TITLE_TRACE", "1", 1)
    }

    func testFRTXT001FRTXT007RasterizesTitleAndReusesContentHashCache() throws {
        titleTrace("cacheReuse: begin")
        titleTrace("cacheReuse: before device acquire")
        let device = try titleMetalDeviceOrSkip()
        titleTrace("cacheReuse: after device acquire name=\(device.name)")

        titleTrace("cacheReuse: before fixture build")
        let title = try makeTitleFixture(
            text: "Hello",
            color: ClipRGBColor(red: .one, green: .one, blue: .zero)
        )
        titleTrace("cacheReuse: after fixture build boxes=\(title.boxes.count)")

        titleTrace("cacheReuse: before graph build")
        let graph = try makeTitleGraph(
            title: title,
            clipID: try titleUUID("00000000-0000-0000-0000-000000009001")
        )
        titleTrace("cacheReuse: after graph build nodes=\(graph.nodes.count)")

        titleTrace("cacheReuse: before executor init")
        let executor = try MetalRenderExecutor(device: device)
        titleTrace("cacheReuse: after executor init")

        let output = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 64, height: 32)
        )
        let provider = ClosureRenderSourceTextureProvider { _ in
            throw TitleTestError.unexpectedSourceRequest
        }

        titleTrace("cacheReuse: before render#1")
        let first = try executor.render(graph: graph, output: output, sourceProvider: provider)
        titleTrace("cacheReuse: after render#1 cacheHit=\(first.cacheHit)")

        titleTrace("cacheReuse: before waitForTitleRender#1")
        try waitForTitleRender(first)
        titleTrace("cacheReuse: after waitForTitleRender#1")

        titleTrace("cacheReuse: before render#2")
        let second = try executor.render(graph: graph, output: output, sourceProvider: provider)
        titleTrace("cacheReuse: after render#2 cacheHit=\(second.cacheHit)")

        titleTrace("cacheReuse: before cache-hit asserts")
        XCTAssertFalse(first.cacheHit)
        XCTAssertTrue(second.cacheHit)
        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertTrue(first.texture === second.texture)
        titleTrace("cacheReuse: after cache-hit asserts")

        titleTrace("cacheReuse: before readTitleBGRA8")
        let pixels = try readTitleBGRA8(texture: first.texture, device: device)
        titleTrace("cacheReuse: after readTitleBGRA8 count=\(pixels.count)")
        XCTAssertTrue(
            pixels.contains(where: { $0 > 0 }),
            "expected rasterized title to write non-zero pixels"
        )
        titleTrace("cacheReuse: complete")
    }

    func testFRTXT001StyleChangeInvalidatesTitleCacheIdentity() throws {
        titleTrace("styleChange: begin")
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
        titleTrace("styleChange: complete")
    }

    func testFRTXT007EmojiAndRTLRasterizeWithoutCrash() throws {
        titleTrace("emojiRTL: begin")
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
        titleTrace("emojiRTL: complete")
    }

    func testFRTXT001MissingFontFallsBackDeterministically() throws {
        titleTrace("fontFallback: begin")
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
        titleTrace("fontFallback: complete")
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

private func readTitleBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    titleTrace("readTitleBGRA8: entry w=\(texture.width) h=\(texture.height)")
    let bytesPerRow = texture.width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
    guard let queue = device.makeCommandQueue() else {
        throw TitleTestError.commandQueueCreationFailed
    }
    guard let commandBuffer = queue.makeCommandBuffer() else {
        throw TitleTestError.commandBufferCreationFailed
    }
    guard let blit = commandBuffer.makeBlitCommandEncoder() else {
        throw TitleTestError.blitEncoderCreationFailed
    }
    // Shared storage textures can be read back directly.
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    titleTrace("readTitleBGRA8: before texture.getBytes")
    texture.getBytes(
        &pixels,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    titleTrace("readTitleBGRA8: after texture.getBytes")
    titleTrace("readTitleBGRA8: complete")
    return pixels
}
