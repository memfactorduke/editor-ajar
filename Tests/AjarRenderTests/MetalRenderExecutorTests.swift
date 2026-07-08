// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

import AjarCore
import AjarRender
import CoreVideo
import Foundation
import Metal
import XCTest

final class MetalRenderExecutorTests: XCTestCase {
    func testADR0006FRFX007ExecutesSingleClipGraphFromCVMetalTexture() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph()
        let sourceTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let expectedMediaID = try testUUID(TestIDs.media)
        let expectedClipID = try testUUID(TestIDs.clip)

        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: ClosureRenderSourceTextureProvider { source in
                XCTAssertEqual(source.mediaID, expectedMediaID)
                XCTAssertEqual(source.clipID, expectedClipID)
                return sourceTexture.texture
            }
        )

        try waitForRender(frame)

        XCTAssertFalse(frame.cacheHit)
        XCTAssertEqual(frame.texture.width, 1)
        XCTAssertEqual(frame.texture.height, 1)
        XCTAssertEqual(frame.contentHash, graph.outputNode?.contentHash)
        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [0, 0, 255, 255])
    }

    func testADR0009ContentHashCacheReturnsCachedTextureOnRepeat() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph()
        let sourceTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [255, 0, 0, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = CountingSourceTextureProvider(texture: sourceTexture.texture)
        let output = RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1))

        let first = try executor.render(graph: graph, output: output, sourceProvider: provider)
        try waitForRender(first)
        let second = try executor.render(graph: graph, output: output, sourceProvider: provider)

        XCTAssertFalse(first.cacheHit)
        XCTAssertTrue(second.cacheHit)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(executor.cacheEntryCount, 1)
        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertTrue(first.texture === second.texture)
    }

    func testNFRQUAL001TransparentCompositeClearsOutputTexture() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeTransparentGraph()
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: ClosureRenderSourceTextureProvider { _ in
                throw TestTextureError.unexpectedSourceRequest
            }
        )

        try waitForRender(frame)

        XCTAssertFalse(frame.cacheHit)
        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [0, 0, 0, 0])
    }

    func testFRTL002CompositesInputsInOrderSoLaterSourcesRenderOnTop() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeTwoClipGraph()
        let bottomTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [255, 0, 0, 255]
        )
        let topTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = ClipTextureProvider(
            textures: [
                try testUUID(TestIDs.bottomClip): bottomTexture.texture,
                try testUUID(TestIDs.topClip): topTexture.texture
            ]
        )

        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(
                pixelDimensions: PixelDimensions(width: 1, height: 1)
            ),
            sourceProvider: provider
        )

        try waitForRender(frame)

        XCTAssertEqual(
            provider.requestedClipIDs,
            [try testUUID(TestIDs.bottomClip), try testUUID(TestIDs.topClip)]
        )
        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [0, 0, 255, 255])
    }

    func testFRXFORM001PositionOffsetsSourceInCanvasPixels() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph(
            transform: ClipTransform(
                position: CanvasPoint(x: RationalValue(1), y: RationalValue(1))
            )
        )
        let sourceTexture = try makeTexture(
            device: device,
            width: 2,
            height: 2,
            bgraPixels: repeatedBGRA([0, 0, 255, 255], count: 4)
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 4, height: 4)),
            sourceProvider: CountingSourceTextureProvider(texture: sourceTexture)
        )

        try waitForRender(frame)

        XCTAssertEqual(
            try readBGRA8(texture: frame.texture, device: device),
            pixels4x4(
                [
                    clear, clear, clear, clear,
                    clear, red, red, clear,
                    clear, red, red, clear,
                    clear, clear, clear, clear
                ]
            )
        )
    }

    func testFRXFORM002ScaleAboutAnchorExpandsSourceQuad() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph(
            transform: ClipTransform(
                scale: ClipScale(x: RationalValue(2), y: RationalValue(2)),
                anchorPoint: .zero
            )
        )
        let sourceTexture = try makeTexture(
            device: device,
            width: 2,
            height: 2,
            bgraPixels: repeatedBGRA([0, 255, 0, 255], count: 4)
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 4, height: 4)),
            sourceProvider: CountingSourceTextureProvider(texture: sourceTexture)
        )

        try waitForRender(frame)

        XCTAssertEqual(
            try readBGRA8(texture: frame.texture, device: device),
            repeatedBGRA([0, 255, 0, 255], count: 16)
        )
    }

    func testFRXFORM004FRCOMP007OpacityCompositesInLinearLight() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeTwoClipGraph(
            topTransform: ClipTransform(opacity: try RationalValue(numerator: 1, denominator: 2))
        )
        let bottomTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [255, 0, 0, 255]
        )
        let topTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: ClipTextureProvider(
                textures: [
                    try testUUID(TestIDs.bottomClip): bottomTexture,
                    try testUUID(TestIDs.topClip): topTexture
                ]
            )
        )

        try waitForRender(frame)

        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [180, 0, 180, 255])
    }

    func testFRCOL008UsesHalfFloatLinearWorkingTextureFormat() {
        XCTAssertEqual(MetalRenderExecutor.linearWorkingPixelFormat, .rgba16Float)
    }

    func testFRCOL005NFRQUAL002Rec709RoundTripPreservesKnownPatch() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph()
        let sourceTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [32, 64, 128, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: CountingSourceTextureProvider(texture: sourceTexture)
        )

        try waitForRender(frame)

        XCTAssertBGRA8(
            try readBGRA8(texture: frame.texture, device: device),
            approximatelyEquals: [32, 64, 128, 255],
            channelTolerance: 1
        )
    }

    func testFRXFORM004ScreenBlendModeCombinesSourceAndDestination() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeTwoClipGraph(topTransform: ClipTransform(blendMode: .screen))
        let bottomTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [255, 0, 0, 255]
        )
        let topTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
            sourceProvider: ClipTextureProvider(
                textures: [
                    try testUUID(TestIDs.bottomClip): bottomTexture,
                    try testUUID(TestIDs.topClip): topTexture
                ]
            )
        )

        try waitForRender(frame)

        XCTAssertEqual(try readBGRA8(texture: frame.texture, device: device), [255, 0, 255, 255])
    }

    func testFRXFORM005CropAndFlipAffectSourceSampling() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph(
            transform: ClipTransform(
                crop: ClipCropInsets(left: 1, top: 0, right: 0, bottom: 0),
                flip: ClipFlip(horizontal: true, vertical: false)
            )
        )
        let sourceTexture = try makeTexture(
            device: device,
            width: 2,
            height: 2,
            bgraPixels: [
                0, 0, 255, 255, 0, 255, 0, 255,
                255, 0, 0, 255, 255, 255, 255, 255
            ]
        )
        let executor = try MetalRenderExecutor(device: device)
        let frame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 2, height: 2)),
            sourceProvider: CountingSourceTextureProvider(texture: sourceTexture)
        )

        try waitForRender(frame)

        XCTAssertEqual(
            try readBGRA8(texture: frame.texture, device: device),
            [
                0, 0, 0, 0, 0, 0, 255, 255,
                0, 0, 0, 0, 255, 0, 0, 255
            ]
        )
    }
}

final class MetalRenderExecutorCompoundTests: XCTestCase {
    func testFRTL013RendersCompoundClipFromNestedGraphAndCachesNestedOutput() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeCompoundClipGraph()
        let sourceTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = ClipTextureProvider(
            textures: [try testUUID(TestIDs.innerClip): sourceTexture]
        )
        let output = RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1))

        let first = try executor.render(graph: graph, output: output, sourceProvider: provider)
        try waitForRender(first)
        let outerEditGraph = try makeCompoundClipGraph(
            compoundTransform: ClipTransform(position: CanvasPoint(x: RationalValue(1), y: .zero))
        )
        let outerEdit = try executor.render(
            graph: outerEditGraph,
            output: output,
            sourceProvider: provider
        )
        try waitForRender(outerEdit)
        let innerEditGraph = try makeCompoundClipGraph(innerSourceStartFrame: 1)
        let innerEdit = try executor.render(
            graph: innerEditGraph,
            output: output,
            sourceProvider: provider
        )
        try waitForRender(innerEdit)

        XCTAssertFalse(first.cacheHit)
        XCTAssertEqual(try readBGRA8(texture: first.texture, device: device), [0, 0, 255, 255])
        XCTAssertFalse(outerEdit.cacheHit)
        XCTAssertFalse(innerEdit.cacheHit)
        XCTAssertEqual(
            provider.requestedClipIDs,
            [try testUUID(TestIDs.innerClip), try testUUID(TestIDs.innerClip)]
        )
        XCTAssertEqual(executor.cacheHitCount, 1)
        XCTAssertEqual(executor.cacheMissCount, 5)
    }

    func testFRTL013NestedCompoundOutputCachesAsHalfFloatTexture() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeCompoundClipGraph()
        let nestedGraph = try compoundNestedGraph(in: graph)
        let sourceTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = ClipTextureProvider(
            textures: [try testUUID(TestIDs.innerClip): sourceTexture]
        )
        let parentOutput = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 1, height: 1)
        )
        let nestedOutput = RenderOutputDescriptor(
            pixelDimensions: parentOutput.pixelDimensions,
            pixelFormat: MetalRenderExecutor.linearWorkingPixelFormat,
            colorMode: .linearWorking
        )

        let parent = try executor.render(
            graph: graph,
            output: parentOutput,
            sourceProvider: provider
        )
        try waitForRender(parent)
        let nested = try executor.render(
            graph: nestedGraph,
            output: nestedOutput,
            sourceProvider: provider
        )

        XCTAssertFalse(parent.cacheHit)
        XCTAssertTrue(nested.cacheHit)
        XCTAssertEqual(nested.texture.pixelFormat, MetalRenderExecutor.linearWorkingPixelFormat)
        XCTAssertEqual(provider.requestedClipIDs, [try testUUID(TestIDs.innerClip)])
    }

    func testNFRQUAL001NestedCompoundSkipsPerLevelPresentPass() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeCompoundClipGraph()
        let nestedGraph = try compoundNestedGraph(in: graph)
        let sourceTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = ClipTextureProvider(
            textures: [try testUUID(TestIDs.innerClip): sourceTexture]
        )
        let parentOutput = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 1, height: 1)
        )
        let nestedOutput = RenderOutputDescriptor(
            pixelDimensions: parentOutput.pixelDimensions,
            pixelFormat: MetalRenderExecutor.linearWorkingPixelFormat,
            colorMode: .linearWorking
        )

        let parent = try executor.render(
            graph: graph,
            output: parentOutput,
            sourceProvider: provider
        )
        try waitForRender(parent)
        let nested = try executor.render(
            graph: nestedGraph,
            output: nestedOutput,
            sourceProvider: provider
        )

        XCTAssertFalse(parent.cacheHit)
        XCTAssertTrue(nested.cacheHit)
        XCTAssertEqual(executor.outputPassCount, 1)
        XCTAssertEqual(nested.texture.pixelFormat, MetalRenderExecutor.linearWorkingPixelFormat)
        XCTAssertEqual(provider.requestedClipIDs, [try testUUID(TestIDs.innerClip)])
    }

    func testADR0009ContentHashCacheIsBoundedByEntryLimit() throws {
        let device = try metalDeviceOrSkip()
        let firstGraph = try makeSingleClipGraph()
        let secondGraph = try makeSingleClipGraph(
            transform: ClipTransform(position: CanvasPoint(x: RationalValue(1), y: .zero))
        )
        let sourceTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [255, 0, 0, 255]
        )
        let executor = try MetalRenderExecutor(device: device, maximumCacheEntryCount: 1)
        let provider = CountingSourceTextureProvider(texture: sourceTexture)
        let output = RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1))

        let first = try executor.render(graph: firstGraph, output: output, sourceProvider: provider)
        try waitForRender(first)
        let second = try executor.render(
            graph: secondGraph,
            output: output,
            sourceProvider: provider
        )
        try waitForRender(second)
        let repeatedFirst = try executor.render(
            graph: firstGraph,
            output: output,
            sourceProvider: provider
        )
        try waitForRender(repeatedFirst)

        XCTAssertFalse(first.cacheHit)
        XCTAssertFalse(second.cacheHit)
        XCTAssertFalse(repeatedFirst.cacheHit)
        XCTAssertEqual(executor.cacheEntryCount, 1)
        XCTAssertEqual(provider.requestCount, 3)
    }

    func testNFRPERF003ReusesPooledIntermediateTexturesAcrossCacheMisses() throws {
        let device = try metalDeviceOrSkip()
        let firstGraph = try makeSingleClipGraph()
        let secondGraph = try makeSingleClipGraph(
            transform: ClipTransform(position: CanvasPoint(x: RationalValue(1), y: .zero))
        )
        let sourceTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [255, 0, 0, 255]
        )
        let executor = try MetalRenderExecutor(
            device: device,
            maximumCacheEntryCount: 4,
            maximumPooledTextureCount: 2
        )
        let provider = CountingSourceTextureProvider(texture: sourceTexture)
        let output = RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 2, height: 2))

        let first = try executor.render(graph: firstGraph, output: output, sourceProvider: provider)
        try waitForRender(first)
        let poolHitsAfterFirstRender = executor.texturePoolHitCount
        let poolEntriesAfterFirstRender = executor.texturePoolEntryCount
        let second = try executor.render(
            graph: secondGraph,
            output: output,
            sourceProvider: provider
        )
        try waitForRender(second)

        XCTAssertFalse(first.cacheHit)
        XCTAssertFalse(second.cacheHit)
        XCTAssertEqual(poolEntriesAfterFirstRender, 2)
        XCTAssertEqual(executor.texturePoolEntryCount, 2)
        XCTAssertGreaterThanOrEqual(executor.texturePoolHitCount, poolHitsAfterFirstRender + 2)
    }

    func testNFRSTAB003ConcurrentCompoundRendersSynchronizeExecutorState() throws {
        let device = try metalDeviceOrSkip()
        let sourceTexture = try makeTexture(
            device: device,
            width: 2,
            height: 2,
            bgraPixels: repeatedBGRA([255, 0, 0, 255], count: 4)
        )
        let executor = try MetalRenderExecutor(
            device: device,
            maximumCacheEntryCount: 3,
            maximumPooledTextureCount: 4
        )
        let provider = ConstantSourceTextureProvider(texture: sourceTexture)
        let stressResult = runConcurrentCompoundRenderStress(
            executor: executor,
            graphs: try makeConcurrentCompoundStressGraphs(),
            outputs: concurrentCompoundStressOutputs(),
            sourceProvider: provider
        )

        XCTAssertTrue(stressResult.completed)
        guard stressResult.completed else {
            return
        }

        XCTAssertTrue(
            stressResult.failureMessages.isEmpty,
            stressResult.failureMessages.joined(separator: "\n")
        )
        XCTAssertLessThanOrEqual(executor.cacheEntryCount, 3)
        XCTAssertGreaterThan(executor.cacheMissCount, 0)
    }
}

final class MetalRenderExecutorCacheTests: XCTestCase {
    func testADR0009ContentHashCacheSeparatesOutputDescriptors() throws {
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph()
        let sourceTexture = try makeCVMetalTextureFixture(
            device: device,
            width: 1,
            height: 1,
            bgra: [255, 0, 0, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = CountingSourceTextureProvider(texture: sourceTexture.texture)
        let smallOutput = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 1, height: 1)
        )
        let largeOutput = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 2, height: 2)
        )

        let small = try executor.render(
            graph: graph,
            output: smallOutput,
            sourceProvider: provider
        )
        try waitForRender(small)
        let large = try executor.render(
            graph: graph,
            output: largeOutput,
            sourceProvider: provider
        )
        try waitForRender(large)
        let repeatedLarge = try executor.render(
            graph: graph,
            output: largeOutput,
            sourceProvider: provider
        )

        XCTAssertFalse(small.cacheHit)
        XCTAssertFalse(large.cacheHit)
        XCTAssertTrue(repeatedLarge.cacheHit)
        XCTAssertEqual(small.contentHash, large.contentHash)
        XCTAssertEqual(small.texture.width, 1)
        XCTAssertEqual(small.texture.height, 1)
        XCTAssertEqual(large.texture.width, 2)
        XCTAssertEqual(large.texture.height, 2)
        XCTAssertEqual(repeatedLarge.texture.width, 2)
        XCTAssertEqual(repeatedLarge.texture.height, 2)
        XCTAssertNotEqual(ObjectIdentifier(small.texture), ObjectIdentifier(large.texture))
        XCTAssertEqual(ObjectIdentifier(repeatedLarge.texture), ObjectIdentifier(large.texture))
        XCTAssertEqual(executor.cacheEntryCount, 2)
        XCTAssertEqual(provider.requestCount, 2)
    }
}

final class MetalRenderExecutorBlendModeTests: XCTestCase {
    func testFRCOMP006NewBlendModesMatchLinearLightFormulas() throws {
        let device = try metalDeviceOrSkip()
        let destinationBGRA: [UInt8] = [64, 128, 192, 255]
        let sourceBGRA: [UInt8] = [32, 200, 96, 255]
        let modes: [ClipBlendMode] = [
            .colorDodge, .colorBurn, .hardLight, .softLight, .difference, .exclusion,
            .subtract, .hue, .saturation, .color, .luminosity
        ]

        for mode in modes {
            let pixels = try renderBlendFixture(
                device: device,
                sourceBGRA: sourceBGRA,
                destinationBGRA: destinationBGRA,
                blendMode: mode
            )
            XCTAssertBGRA8(
                pixels,
                approximatelyEquals: expectedCompositeBGRA(
                    sourceBGRA: sourceBGRA,
                    destinationBGRA: destinationBGRA,
                    blendMode: mode
                ),
                channelTolerance: 2
            )
        }
    }

    func testFRCOMP006TrackBlendAndOpacityCompositeOverLowerTrack() throws {
        let device = try metalDeviceOrSkip()
        let opacity = try RationalValue(numerator: 1, denominator: 2)
        let sourceBGRA: [UInt8] = [32, 200, 96, 255]
        let destinationBGRA: [UInt8] = [64, 128, 192, 255]
        let pixels = try renderBlendFixture(
            device: device,
            sourceBGRA: sourceBGRA,
            destinationBGRA: destinationBGRA,
            trackOpacity: .constant(opacity),
            trackBlendMode: .difference
        )

        XCTAssertBGRA8(
            pixels,
            approximatelyEquals: expectedCompositeBGRA(
                sourceBGRA: sourceBGRA,
                destinationBGRA: destinationBGRA,
                blendMode: .difference,
                opacity: Double(opacity.numerator) / Double(opacity.denominator)
            ),
            channelTolerance: 2
        )
    }

    func testFRCOMP006PremultipliedAlphaNormalOverOpaqueHasNoFringe() throws {
        let device = try metalDeviceOrSkip()
        let pixels = try renderBlendFixture(
            device: device,
            sourceBGRA: [0, 0, 128, 128],
            destinationBGRA: [255, 0, 0, 255],
            blendMode: .normal
        )

        XCTAssertBGRA8(
            pixels,
            approximatelyEquals: expectedCompositeBGRA(
                sourceBGRA: [0, 0, 128, 128],
                destinationBGRA: [255, 0, 0, 255],
                blendMode: .normal
            ),
            channelTolerance: 2
        )
        XCTAssertGreaterThan(pixels[0], 160)
        XCTAssertGreaterThan(pixels[2], 160)
    }
}

final class MetalRenderExecutorOutputColorModeTests: XCTestCase {
    func testNFRQUAL001PresentedHalfFloatOutputStillEncodesPresentPass() throws {
        // NFR-QUAL-001: linear-working output is an explicit descriptor property, never
        // inferred from the pixel format. A future HDR-presented rgba16Float output must
        // still receive the display-transfer present pass.
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph()
        let sourceTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let output = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            pixelFormat: MetalRenderExecutor.linearWorkingPixelFormat
        )

        let frame = try executor.render(
            graph: graph,
            output: output,
            sourceProvider: CountingSourceTextureProvider(texture: sourceTexture)
        )
        try waitForRender(frame)

        XCTAssertEqual(output.colorMode, .presented)
        XCTAssertFalse(frame.cacheHit)
        XCTAssertEqual(executor.outputPassCount, 1)
    }

    func testNFRQUAL001LinearWorkingOutputSkipsPresentPassAndCachesSeparately() throws {
        // NFR-QUAL-001: `.linearWorking` skips the present pass, and its frames must never
        // collide in the content-hash cache with a presented output of identical dimensions
        // and pixel format.
        let device = try metalDeviceOrSkip()
        let graph = try makeSingleClipGraph()
        let sourceTexture = try makeTexture(
            device: device,
            width: 1,
            height: 1,
            bgraPixels: [0, 0, 255, 255]
        )
        let executor = try MetalRenderExecutor(device: device)
        let provider = CountingSourceTextureProvider(texture: sourceTexture)
        let presentedOutput = RenderOutputDescriptor(
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            pixelFormat: MetalRenderExecutor.linearWorkingPixelFormat
        )
        let linearOutput = RenderOutputDescriptor(
            pixelDimensions: presentedOutput.pixelDimensions,
            pixelFormat: presentedOutput.pixelFormat,
            colorMode: .linearWorking
        )

        let presented = try executor.render(
            graph: graph,
            output: presentedOutput,
            sourceProvider: provider
        )
        try waitForRender(presented)
        let linear = try executor.render(
            graph: graph,
            output: linearOutput,
            sourceProvider: provider
        )
        try waitForRender(linear)
        let linearRepeat = try executor.render(
            graph: graph,
            output: linearOutput,
            sourceProvider: provider
        )
        let presentedRepeat = try executor.render(
            graph: graph,
            output: presentedOutput,
            sourceProvider: provider
        )

        XCTAssertFalse(presented.cacheHit)
        XCTAssertFalse(linear.cacheHit)
        XCTAssertTrue(linearRepeat.cacheHit)
        XCTAssertTrue(presentedRepeat.cacheHit)
        XCTAssertFalse(presented.texture === linear.texture)
        XCTAssertEqual(executor.outputPassCount, 1)
    }
}

private enum TestIDs {
    static let media = "00000000-0000-0000-0000-000000000017"
    static let clip = "00000000-0000-0000-0000-000000000117"
    static let bottomMedia = "00000000-0000-0000-0000-000000000018"
    static let topMedia = "00000000-0000-0000-0000-000000000019"
    static let bottomClip = "00000000-0000-0000-0000-000000000118"
    static let topClip = "00000000-0000-0000-0000-000000000119"
    static let innerMedia = "00000000-0000-0000-0000-000000000020"
    static let innerClip = "00000000-0000-0000-0000-000000000120"
    static let compoundClip = "00000000-0000-0000-0000-000000000121"
    static let innerSequence = "00000000-0000-0000-0000-000000000122"
}

private final class CountingSourceTextureProvider: RenderSourceTextureProvider {
    private let sourceTexture: MTLTexture
    private(set) var requestCount = 0

    init(texture: MTLTexture) {
        sourceTexture = texture
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        requestCount += 1
        return sourceTexture
    }
}

private final class ClipTextureProvider: RenderSourceTextureProvider {
    private let textures: [UUID: MTLTexture]
    private(set) var requestedClipIDs: [UUID] = []

    init(textures: [UUID: MTLTexture]) {
        self.textures = textures
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        requestedClipIDs.append(source.clipID)
        guard let texture = textures[source.clipID] else {
            throw TestTextureError.metalTextureUnavailable
        }
        return texture
    }
}

private final class ConstantSourceTextureProvider: RenderSourceTextureProvider {
    private let sourceTexture: MTLTexture

    init(texture: MTLTexture) {
        sourceTexture = texture
    }

    func texture(for _: RenderSourceNode) throws -> MTLTexture {
        sourceTexture
    }
}

private struct ConcurrentRenderStressResult {
    var completed: Bool
    var failureMessages: [String]
}

private func makeConcurrentCompoundStressGraphs() throws -> [RenderGraph] {
    try [
        makeCompoundClipGraph(),
        makeCompoundClipGraph(
            compoundTransform: ClipTransform(
                position: CanvasPoint(x: RationalValue(1), y: .zero)
            )
        ),
        makeCompoundClipGraph(innerSourceStartFrame: 1)
    ]
}

private func concurrentCompoundStressOutputs() -> [RenderOutputDescriptor] {
    [
        RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 2, height: 2)),
        RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 3, height: 2)),
        RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 2, height: 3))
    ]
}

private struct ConcurrentRenderStressContext {
    var executor: MetalRenderExecutor
    var graphs: [RenderGraph]
    var outputs: [RenderOutputDescriptor]
    var sourceProvider: any RenderSourceTextureProvider
}

private func runConcurrentCompoundRenderStress(
    executor: MetalRenderExecutor,
    graphs: [RenderGraph],
    outputs: [RenderOutputDescriptor],
    sourceProvider: any RenderSourceTextureProvider
) -> ConcurrentRenderStressResult {
    let workerCount = 8
    let iterationCount = 12
    let context = ConcurrentRenderStressContext(
        executor: executor,
        graphs: graphs,
        outputs: outputs,
        sourceProvider: sourceProvider
    )
    let startGate = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let failureRecorder = ConcurrentStressFailureRecorder()
    let queue = DispatchQueue(
        label: "MetalRenderExecutor.concurrentCompoundStress",
        qos: .userInitiated,
        attributes: .concurrent
    )

    for workerIndex in 0..<workerCount {
        group.enter()
        queue.async {
            startGate.wait()
            runConcurrentCompoundRenderStressWorker(
                workerIndex: workerIndex,
                iterationCount: iterationCount,
                context: context,
                failureRecorder: failureRecorder
            )
            group.leave()
        }
    }

    for _ in 0..<workerCount {
        startGate.signal()
    }

    return ConcurrentRenderStressResult(
        completed: group.wait(timeout: .now() + .seconds(30)) == .success,
        failureMessages: failureRecorder.messages()
    )
}

private func runConcurrentCompoundRenderStressWorker(
    workerIndex: Int,
    iterationCount: Int,
    context: ConcurrentRenderStressContext,
    failureRecorder: ConcurrentStressFailureRecorder
) {
    for iteration in 0..<iterationCount {
        if let message = concurrentRenderFailureMessage(
            workerIndex: workerIndex,
            iteration: iteration,
            context: context
        ) {
            failureRecorder.append(message)
        }
    }
}

private func concurrentRenderFailureMessage(
    workerIndex: Int,
    iteration: Int,
    context: ConcurrentRenderStressContext
) -> String? {
    let graph = context.graphs[(workerIndex + iteration) % context.graphs.count]
    let output = context.outputs[(workerIndex + iteration) % context.outputs.count]

    do {
        let frame = try context.executor.render(
            graph: graph,
            output: output,
            sourceProvider: context.sourceProvider
        )
        guard let commandBuffer = frame.commandBuffer else {
            return nil
        }

        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            return "worker \(workerIndex) iteration \(iteration) failed: \(error)"
        }
        guard commandBuffer.status == .completed else {
            return "worker \(workerIndex) iteration \(iteration) ended with \(commandBuffer.status)"
        }
        return nil
    } catch {
        return "worker \(workerIndex) iteration \(iteration) threw: \(error)"
    }
}

private final class ConcurrentStressFailureRecorder {
    private let lock = NSLock()
    private var recordedMessages: [String] = []

    func append(_ message: String) {
        lock.lock()
        recordedMessages.append(message)
        lock.unlock()
    }

    func messages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMessages
    }
}

private enum TestTextureError: Error {
    case unexpectedSourceRequest
    case pixelBufferCreationFailed(Int32)
    case pixelBufferBaseAddressUnavailable
    case textureCacheCreationFailed(Int32)
    case metalTextureCreationFailed(Int32)
    case metalTextureUnavailable
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
}

private final class CVMetalTextureFixture {
    let pixelBuffer: CVPixelBuffer
    let cache: CVMetalTextureCache
    let metalTexture: CVMetalTexture
    let texture: MTLTexture

    init(
        pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        metalTexture: CVMetalTexture,
        texture: MTLTexture
    ) {
        self.pixelBuffer = pixelBuffer
        self.cache = cache
        self.metalTexture = metalTexture
        self.texture = texture
    }
}

private let clear: [UInt8] = [0, 0, 0, 0]
private let red: [UInt8] = [0, 0, 255, 255]

private func makeSingleClipGraph(
    transform: ClipTransform = .identity,
    effects: ClipEffects = .none
) throws -> RenderGraph {
    let mediaID = try testUUID(TestIDs.media)
    let clipID = try testUUID(TestIDs.clip)
    let media = MediaRef(
        id: mediaID,
        sourceURL: URL(fileURLWithPath: "/media/synthetic.mov"),
        contentHash: ContentHash.sha256(data: Data("synthetic".utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try time(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try range(startFrame: 0, durationFrames: 24),
        timelineRange: try range(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Synthetic",
        transform: transform,
        effects: effects
    )
    let sequence = Sequence(
        id: UUID(),
        name: "Render",
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

    return try buildRenderGraph(for: sequence, at: try time(0), in: project)
}

private func makeTwoClipGraph(
    topTransform: ClipTransform = .identity,
    topEffects: ClipEffects = .none,
    topTrackOpacity: Animatable<RationalValue> = .constant(.one),
    topTrackBlendMode: ClipBlendMode = .normal
) throws -> RenderGraph {
    let bottomMediaID = try testUUID(TestIDs.bottomMedia)
    let topMediaID = try testUUID(TestIDs.topMedia)
    let bottomClip = try makeRenderClip(
        id: try testUUID(TestIDs.bottomClip),
        mediaID: bottomMediaID
    )
    let topClip = try makeRenderClip(
        id: try testUUID(TestIDs.topClip),
        mediaID: topMediaID,
        transform: topTransform,
        effects: topEffects
    )
    let sequence = Sequence(
        id: UUID(),
        name: "Composite",
        videoTracks: [
            Track(id: UUID(), kind: .video, items: [.clip(bottomClip)]),
            Track(
                id: UUID(),
                kind: .video,
                items: [.clip(topClip)],
                opacity: topTrackOpacity,
                blendMode: topTrackBlendMode
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
        mediaPool: [
            try makeRenderMedia(id: bottomMediaID),
            try makeRenderMedia(id: topMediaID)
        ],
        sequences: [sequence]
    )

    return try buildRenderGraph(for: sequence, at: try time(0), in: project)
}

private func makeCompoundClipGraph(
    compoundTransform: ClipTransform = .identity,
    innerSourceStartFrame: Int64 = 0
) throws -> RenderGraph {
    let innerMediaID = try testUUID(TestIDs.innerMedia)
    let innerSequenceID = try testUUID(TestIDs.innerSequence)
    let innerClip = try makeRenderClip(
        id: try testUUID(TestIDs.innerClip),
        mediaID: innerMediaID,
        sourceStartFrame: innerSourceStartFrame
    )
    let compoundClip = Clip(
        id: try testUUID(TestIDs.compoundClip),
        source: .sequence(id: innerSequenceID),
        sourceRange: try range(startFrame: 0, durationFrames: 24),
        timelineRange: try range(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Compound",
        transform: compoundTransform
    )
    let outerSequence = Sequence(
        id: UUID(),
        name: "Outer",
        videoTracks: [Track(id: UUID(), kind: .video, items: [.clip(compoundClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let innerSequence = Sequence(
        id: innerSequenceID,
        name: "Inner",
        videoTracks: [Track(id: UUID(), kind: .video, items: [.clip(innerClip)])],
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
        mediaPool: [try makeRenderMedia(id: innerMediaID)],
        sequences: [outerSequence, innerSequence]
    )

    return try buildRenderGraph(for: outerSequence, at: try time(0), in: project)
}

private func compoundNestedGraph(in graph: RenderGraph) throws -> RenderGraph {
    guard let node = graph.nodes.first(where: { node in
        if case .compound = node.kind {
            return true
        }
        return false
    }) else {
        throw TestTextureError.metalTextureUnavailable
    }
    guard case .compound(let compound) = node.kind else {
        throw TestTextureError.metalTextureUnavailable
    }
    return compound.graph
}

private func renderBlendFixture(
    device: MTLDevice,
    sourceBGRA: [UInt8],
    destinationBGRA: [UInt8],
    blendMode: ClipBlendMode,
    trackOpacity: Animatable<RationalValue> = .constant(.one),
    trackBlendMode: ClipBlendMode = .normal
) throws -> [UInt8] {
    try renderBlendFixture(
        device: device,
        sourceBGRA: sourceBGRA,
        destinationBGRA: destinationBGRA,
        topTransform: ClipTransform(blendMode: blendMode),
        trackOpacity: trackOpacity,
        trackBlendMode: trackBlendMode
    )
}

private func renderBlendFixture(
    device: MTLDevice,
    sourceBGRA: [UInt8],
    destinationBGRA: [UInt8],
    topTransform: ClipTransform = .identity,
    trackOpacity: Animatable<RationalValue> = .constant(.one),
    trackBlendMode: ClipBlendMode = .normal
) throws -> [UInt8] {
    let graph = try makeTwoClipGraph(
        topTransform: topTransform,
        topTrackOpacity: trackOpacity,
        topTrackBlendMode: trackBlendMode
    )
    let bottomTexture = try makeTexture(
        device: device,
        width: 1,
        height: 1,
        bgraPixels: destinationBGRA
    )
    let topTexture = try makeTexture(
        device: device,
        width: 1,
        height: 1,
        bgraPixels: sourceBGRA
    )
    let executor = try MetalRenderExecutor(device: device)
    let frame = try executor.render(
        graph: graph,
        output: RenderOutputDescriptor(pixelDimensions: PixelDimensions(width: 1, height: 1)),
        sourceProvider: ClipTextureProvider(
            textures: [
                try testUUID(TestIDs.bottomClip): bottomTexture,
                try testUUID(TestIDs.topClip): topTexture
            ]
        )
    )

    try waitForRender(frame)
    return try readBGRA8(texture: frame.texture, device: device)
}

private func makeRenderMedia(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1, height: 1),
            frameRate: try FrameRate(frames: 24),
            duration: try time(24),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeRenderClip(
    id: UUID,
    mediaID: UUID,
    sourceStartFrame: Int64 = 0,
    transform: ClipTransform = .identity,
    effects: ClipEffects = .none
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try range(startFrame: sourceStartFrame, durationFrames: 24),
        timelineRange: try range(startFrame: 0, durationFrames: 24),
        kind: .video,
        name: "Synthetic",
        transform: transform,
        effects: effects
    )
}

private func makeTransparentGraph() throws -> RenderGraph {
    let sequence = Sequence(
        id: UUID(),
        name: "Empty",
        videoTracks: [],
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
        mediaPool: [],
        sequences: [sequence]
    )

    return try buildRenderGraph(for: sequence, at: try time(0), in: project)
}

private func makeCVMetalTextureFixture(
    device: MTLDevice,
    width: Int,
    height: Int,
    bgra: [UInt8]
) throws -> CVMetalTextureFixture {
    var attributes: [String: Any] = [:]
    attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
    attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]

    var pixelBuffer: CVPixelBuffer?
    let pixelBufferResult = CVPixelBufferCreate(
        nil,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )

    guard pixelBufferResult == kCVReturnSuccess, let pixelBuffer else {
        throw TestTextureError.pixelBufferCreationFailed(pixelBufferResult)
    }

    try fill(pixelBuffer: pixelBuffer, width: width, height: height, bgra: bgra)

    var cache: CVMetalTextureCache?
    let cacheResult = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    guard cacheResult == kCVReturnSuccess, let cache else {
        throw TestTextureError.textureCacheCreationFailed(cacheResult)
    }

    var metalTexture: CVMetalTexture?
    let textureResult = CVMetalTextureCacheCreateTextureFromImage(
        nil,
        cache,
        pixelBuffer,
        nil,
        .bgra8Unorm,
        width,
        height,
        0,
        &metalTexture
    )

    guard textureResult == kCVReturnSuccess, let metalTexture else {
        throw TestTextureError.metalTextureCreationFailed(textureResult)
    }
    guard let texture = CVMetalTextureGetTexture(metalTexture) else {
        throw TestTextureError.metalTextureUnavailable
    }

    return CVMetalTextureFixture(
        pixelBuffer: pixelBuffer,
        cache: cache,
        metalTexture: metalTexture,
        texture: texture
    )
}

private func makeTexture(
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
        throw TestTextureError.metalTextureUnavailable
    }
    guard bgraPixels.count == width * height * 4 else {
        throw TestTextureError.pixelBufferBaseAddressUnavailable
    }

    texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: bgraPixels,
        bytesPerRow: width * 4
    )
    return texture
}

private func repeatedBGRA(_ pixel: [UInt8], count: Int) -> [UInt8] {
    var pixels: [UInt8] = []
    pixels.reserveCapacity(pixel.count * count)
    for _ in 0..<count {
        pixels.append(contentsOf: pixel)
    }
    return pixels
}

private func pixels4x4(_ pixels: [[UInt8]]) -> [UInt8] {
    pixels.flatMap { $0 }
}

private func fill(
    pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int,
    bgra: [UInt8]
) throws {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw TestTextureError.pixelBufferBaseAddressUnavailable
    }

    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = baseAddress.bindMemory(to: UInt8.self, capacity: rowBytes * height)
    for yPosition in 0..<height {
        for xPosition in 0..<width {
            let destination = (yPosition * rowBytes) + (xPosition * 4)
            bytes[destination] = bgra[0]
            bytes[destination + 1] = bgra[1]
            bytes[destination + 2] = bgra[2]
            bytes[destination + 3] = bgra[3]
        }
    }
}

private func readBGRA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw TestTextureError.commandBufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw TestTextureError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw TestTextureError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw TestTextureError.blitEncoderCreationFailed
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

private func XCTAssertBGRA8(
    _ actual: [UInt8],
    approximatelyEquals expected: [UInt8],
    channelTolerance: UInt8,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for index in actual.indices {
        let delta = abs(Int(actual[index]) - Int(expected[index]))
        XCTAssertLessThanOrEqual(delta, Int(channelTolerance), file: file, line: line)
    }
}

private func expectedCompositeBGRA(
    sourceBGRA: [UInt8],
    destinationBGRA: [UInt8],
    blendMode: ClipBlendMode,
    opacity: Double = 1
) -> [UInt8] {
    let sourceAlpha = alpha(sourceBGRA) * opacity
    let destinationAlpha = alpha(destinationBGRA)
    let source = linearRGB(sourceBGRA)
    let destination = linearRGB(destinationBGRA)
    let blended = blend(source: source, destination: destination, mode: blendMode)
    let outputAlpha = sourceAlpha + (destinationAlpha * (1 - sourceAlpha))
    let outputLinear = (0..<3).map { index in
        (blended[index] * sourceAlpha * destinationAlpha)
            + (source[index] * sourceAlpha * (1 - destinationAlpha))
            + (destination[index] * destinationAlpha * (1 - sourceAlpha))
    }
    let straight = outputAlpha > 0 ? outputLinear.map { $0 / outputAlpha } : [0, 0, 0]

    return [
        byte(encodeRec709(straight[2])),
        byte(encodeRec709(straight[1])),
        byte(encodeRec709(straight[0])),
        byte(outputAlpha)
    ]
}

private func linearRGB(_ bgra: [UInt8]) -> [Double] {
    let colorAlpha = alpha(bgra)
    guard colorAlpha > 0 else {
        return [0, 0, 0]
    }

    return [
        decodeRec709((Double(bgra[2]) / 255) / colorAlpha),
        decodeRec709((Double(bgra[1]) / 255) / colorAlpha),
        decodeRec709((Double(bgra[0]) / 255) / colorAlpha)
    ]
}

private func alpha(_ bgra: [UInt8]) -> Double {
    Double(bgra[3]) / 255
}

private func blend(source: [Double], destination: [Double], mode: ClipBlendMode) -> [Double] {
    switch mode {
    case .normal:
        return source
    case .multiply:
        return zip(source, destination).map(*)
    case .screen:
        return zip(source, destination).map { 1 - ((1 - $0) * (1 - $1)) }
    case .overlay:
        return zip(source, destination).map { overlay(source: $0, destination: $1) }
    case .add:
        return zip(source, destination).map { min($0 + $1, 1) }
    case .darken:
        return zip(source, destination).map(min)
    case .lighten:
        return zip(source, destination).map(max)
    default:
        return extendedBlend(source: source, destination: destination, mode: mode)
    }
}

private func extendedBlend(
    source: [Double],
    destination: [Double],
    mode: ClipBlendMode
) -> [Double] {
    switch mode {
    case .colorDodge:
        return zip(source, destination).map {
            $0 >= 1 ? 1 : min($1 / max(1 - $0, 0.00001), 1)
        }
    case .colorBurn:
        return zip(source, destination).map {
            $0 <= 0 ? 0 : 1 - min((1 - $1) / max($0, 0.00001), 1)
        }
    case .hardLight:
        return zip(source, destination).map { hardLight(source: $0, destination: $1) }
    case .softLight:
        return zip(source, destination).map { softLight(source: $0, destination: $1) }
    case .difference:
        return zip(source, destination).map { abs($1 - $0) }
    case .exclusion:
        return zip(source, destination).map { $1 + $0 - (2 * $1 * $0) }
    case .subtract:
        return zip(source, destination).map { max($1 - $0, 0) }
    case .hue, .saturation, .color, .luminosity:
        return hslBlend(source: source, destination: destination, mode: mode)
    default:
        return source
    }
}

private func overlay(source: Double, destination: Double) -> Double {
    destination <= 0.5
        ? 2 * source * destination
        : 1 - (2 * (1 - source) * (1 - destination))
}

private func hardLight(source: Double, destination: Double) -> Double {
    source <= 0.5
        ? 2 * source * destination
        : 1 - (2 * (1 - source) * (1 - destination))
}

private func softLight(source: Double, destination: Double) -> Double {
    if source <= 0.5 {
        return destination - ((1 - (2 * source)) * destination * (1 - destination))
    }
    let curve = destination <= 0.25
        ? (((16 * destination) - 12) * destination + 4) * destination
        : sqrt(destination)
    return destination + (((2 * source) - 1) * (curve - destination))
}

private func hslBlend(source: [Double], destination: [Double], mode: ClipBlendMode) -> [Double] {
    switch mode {
    case .hue:
        return setLum(setSat(source, saturation(destination)), luminosity(destination))
    case .saturation:
        return setLum(setSat(destination, saturation(source)), luminosity(destination))
    case .color:
        return setLum(source, luminosity(destination))
    case .luminosity:
        return setLum(destination, luminosity(source))
    default:
        return source
    }
}

private func luminosity(_ color: [Double]) -> Double {
    (0.2126 * color[0]) + (0.7152 * color[1]) + (0.0722 * color[2])
}

private func saturation(_ color: [Double]) -> Double {
    (color.max() ?? 0) - (color.min() ?? 0)
}

private func setLum(_ color: [Double], _ lum: Double) -> [Double] {
    clipColor(color.map { $0 + (lum - luminosity(color)) })
}

private func clipColor(_ color: [Double]) -> [Double] {
    let lum = luminosity(color)
    let minColor = color.min() ?? 0
    let lowClipped = minColor < 0
        ? color.map { lum + ((($0 - lum) * lum) / max(lum - minColor, 0.00001)) }
        : color
    let highMax = lowClipped.max() ?? 0
    return highMax > 1
        ? lowClipped.map { lum + ((($0 - lum) * (1 - lum)) / max(highMax - lum, 0.00001)) }
        : lowClipped
}

private func setSat(_ color: [Double], _ sat: Double) -> [Double] {
    let minColor = color.min() ?? 0
    let maxColor = color.max() ?? 0
    guard maxColor > minColor else {
        return [0, 0, 0]
    }
    return color.map { ($0 - minColor) * (sat / (maxColor - minColor)) }
}

private func decodeRec709(_ encoded: Double) -> Double {
    let value = min(max(encoded, 0), 1)
    return value < 0.081 ? value / 4.5 : pow((value + 0.099) / 1.099, 1 / 0.45)
}

private func encodeRec709(_ linear: Double) -> Double {
    let value = min(max(linear, 0), 1)
    return value < 0.018 ? value * 4.5 : (1.099 * pow(value, 0.45)) - 0.099
}

private func byte(_ value: Double) -> UInt8 {
    UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
}

private func waitForRender(_ frame: RenderedFrame) throws {
    guard let commandBuffer = frame.commandBuffer else {
        return
    }

    commandBuffer.waitUntilCompleted()
    XCTAssertNil(commandBuffer.error)
    XCTAssertEqual(commandBuffer.status, .completed)
}

private func metalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}

private func testUUID(_ string: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: string))
}

private func range(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: try time(startFrame), duration: try time(durationFrames))
}

private func time(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}
