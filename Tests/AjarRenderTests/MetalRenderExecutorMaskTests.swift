// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal
import XCTest

final class MetalRenderExecutorMaskTests: XCTestCase {
    func testFRCOMP003RectangleMaskCompositesSourceOverBackground() throws {
        let device = try maskMetalDeviceOrSkip()
        let graph = try makeMaskTwoClipGraph(
            topEffects: ClipEffects(
                masks: [
                    try makeMaskRectangle(x: 1, y: 0, width: 2, height: 1)
                ]
            ),
            width: 4,
            height: 1
        )
        let pixels = try renderMaskPixels(
            device: device,
            graph: graph,
            textures: [
                try maskUUID(MaskTestIDs.bottomClip): try makeMaskTexture(
                    device: device,
                    width: 4,
                    height: 1,
                    bgraPixels: repeatedMaskBGRA(maskBlue, count: 4)
                ),
                try maskUUID(MaskTestIDs.topClip): try makeMaskTexture(
                    device: device,
                    width: 4,
                    height: 1,
                    bgraPixels: repeatedMaskBGRA(maskRed, count: 4)
                )
            ],
            outputWidth: 4,
            outputHeight: 1
        )

        XCTAssertEqual(
            pixels,
            maskBlue + maskRed + maskRed + maskBlue
        )
    }

    func testFRCOMP003EllipseAndPolygonMasksRasterizeOnGPU() throws {
        let device = try maskMetalDeviceOrSkip()
        let sourceTexture = try makeMaskTexture(
            device: device,
            width: 3,
            height: 3,
            bgraPixels: repeatedMaskBGRA(maskWhite, count: 9)
        )
        let ellipsePixels = try renderMaskSingleClipPixels(
            device: device,
            effects: ClipEffects(
                masks: [
                    try makeMaskEllipse(centerX: 3, centerY: 3, radiusX: 2, radiusY: 2)
                ]
            ),
            texture: sourceTexture,
            width: 3,
            height: 3
        )
        let polygonPixels = try renderMaskSingleClipPixels(
            device: device,
            effects: ClipEffects(
                masks: [
                    ClipMask(
                        id: try maskUUID(MaskTestIDs.mask),
                        shape: .polygon(
                            ClipPolygonMask(
                                points: [
                                    try maskPoint(0, 0),
                                    try maskPoint(2, 0),
                                    try maskPoint(2, 2),
                                    try maskPoint(0, 2)
                                ]
                            )
                        )
                    )
                ]
            ),
            texture: sourceTexture,
            width: 3,
            height: 3
        )

        XCTAssertEqual(
            ellipsePixels,
            maskClear + maskWhite + maskClear
                + maskWhite + maskWhite + maskWhite
                + maskClear + maskWhite + maskClear
        )
        XCTAssertEqual(
            polygonPixels,
            maskWhite + maskWhite + maskClear
                + maskWhite + maskWhite + maskClear
                + maskClear + maskClear + maskClear
        )
    }

    func testFRCOMP003SubtractMaskRemovesFromPreviousMatte() throws {
        let device = try maskMetalDeviceOrSkip()
        let textures = try makeMaskCompositeTextures(device: device)
        let pixels = try renderMaskTwoClipPixels(
            device: device,
            topEffects: ClipEffects(
                masks: [
                    try makeMaskRectangle(x: 0, y: 0, width: 4, height: 1),
                    try makeMaskRectangle(
                        x: 1,
                        y: 0,
                        width: 2,
                        height: 1,
                        combine: .subtract
                    )
                ]
            ),
            bottomTexture: textures.background,
            topTexture: textures.source,
            dimensions: PixelDimensions(width: 4, height: 1)
        )

        XCTAssertEqual(pixels, maskRed + maskBlue + maskBlue + maskRed)
    }

    func testFRCOMP003InvertMaskFlipsMatteBeforeCombine() throws {
        let device = try maskMetalDeviceOrSkip()
        let textures = try makeMaskCompositeTextures(device: device)
        let pixels = try renderMaskTwoClipPixels(
            device: device,
            topEffects: ClipEffects(
                masks: [
                    try makeMaskRectangle(
                        x: 1,
                        y: 0,
                        width: 2,
                        height: 1,
                        invert: true
                    )
                ]
            ),
            bottomTexture: textures.background,
            topTexture: textures.source,
            dimensions: PixelDimensions(width: 4, height: 1)
        )

        XCTAssertEqual(pixels, maskRed + maskBlue + maskBlue + maskRed)
    }

    func testFRCOMP003MaskStaysInPreFlipLocalGeometry() throws {
        let device = try maskMetalDeviceOrSkip()
        let background = try makeMaskTexture(
            device: device,
            width: 4,
            height: 1,
            bgraPixels: repeatedMaskBGRA(maskBlue, count: 4)
        )
        let mirroredSource = try makeMaskTexture(
            device: device,
            width: 4,
            height: 1,
            bgraPixels: maskRed + maskRed + maskWhite + maskWhite
        )
        let pixels = try renderMaskTwoClipPixels(
            device: device,
            topEffects: ClipEffects(
                masks: [
                    try makeMaskRectangle(x: 0, y: 0, width: 2, height: 1)
                ]
            ),
            topTransform: ClipTransform(flip: ClipFlip(horizontal: true, vertical: false)),
            bottomTexture: background,
            topTexture: mirroredSource,
            dimensions: PixelDimensions(width: 4, height: 1)
        )

        XCTAssertEqual(pixels, maskWhite + maskWhite + maskBlue + maskBlue)
    }

    func testFRCOMP003IntersectMaskKeepsOverlapWithPreviousMatte() throws {
        let device = try maskMetalDeviceOrSkip()
        let textures = try makeMaskCompositeTextures(device: device)
        let pixels = try renderMaskTwoClipPixels(
            device: device,
            topEffects: ClipEffects(
                masks: [
                    try makeMaskRectangle(x: 0, y: 0, width: 3, height: 1),
                    try makeMaskRectangle(
                        x: 1,
                        y: 0,
                        width: 3,
                        height: 1,
                        combine: .intersect
                    )
                ]
            ),
            bottomTexture: textures.background,
            topTexture: textures.source,
            dimensions: PixelDimensions(width: 4, height: 1)
        )

        XCTAssertEqual(pixels, maskBlue + maskRed + maskRed + maskBlue)
    }

    func testFRCOMP003FeatherProducesSoftMaskEdge() throws {
        let device = try maskMetalDeviceOrSkip()
        let sourceTexture = try makeMaskTexture(
            device: device,
            width: 4,
            height: 1,
            bgraPixels: repeatedMaskBGRA(maskWhite, count: 4)
        )
        let pixels = try renderMaskSingleClipPixels(
            device: device,
            effects: ClipEffects(
                chromaKey: ClipChromaKeySettings(
                    enabled: false,
                    keyColor: .green,
                    tolerance: .zero,
                    edgeSoftness: .zero,
                    spillSuppression: .zero,
                    viewMatte: true
                ),
                masks: [
                    try makeMaskRectangle(
                        x: 1,
                        y: 0,
                        width: 2,
                        height: 1,
                        featherRadius: RationalValue(1)
                    )
                ]
            ),
            texture: sourceTexture,
            width: 4,
            height: 1
        )
        let outsideEdgeBlue = pixels[0]
        let insideBlue = pixels[4]

        XCTAssertGreaterThan(outsideEdgeBlue, 0)
        XCTAssertLessThan(outsideEdgeBlue, insideBlue)
        XCTAssertLessThan(insideBlue, 255)
        XCTAssertEqual(pixels[3], 255)
    }
}
