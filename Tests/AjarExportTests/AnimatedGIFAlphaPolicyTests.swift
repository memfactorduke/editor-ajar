// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import XCTest

@testable import AjarExport

final class AnimatedGIFAlphaPolicyTests: XCTestCase {
    func testFREXP006GIFPreservesTransparentPixelsAndMattesPartialAlphaOverBlack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-gif-alpha-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("alpha.gif")

        let writer = try ImageIOAnimatedGIFWriter(
            url: url,
            expectedFrameCount: 1,
            loopPolicy: .playOnce
        )
        try writer.append(
            pixelBuffer: try makeAlphaPolicyBuffer(),
            sourceColorSpace: .rec709,
            colorConversionPolicy: .convertToSRGB,
            delayCentiseconds: 10
        )
        try writer.finalize()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = try decodeBGRA(image)

        XCTAssertEqual(bytes[3], 255, "partially covered pixel must become opaque")
        XCTAssertGreaterThan(bytes[2], 0, "premultiplied red must remain visible over black")
        XCTAssertLessThan(bytes[2], 220, "partial red must not be unpremultiplied to full red")
        XCTAssertEqual(Array(bytes[4...7]), [0, 0, 0, 0], "fully transparent pixel stays clear")
    }

    func testFREXP006DisplayP3PixelsAreConvertedToSRGBBeforePaletteGeneration() throws {
        let input = GIFTestRGB(b: 64, g: 128, r: 192)
        let pixelBuffer = try makeOpaqueColorBuffer(input)
        let image = try BGRAImageBridge.makeOwnedSRGBCGImage(
            from: pixelBuffer,
            sourceColorSpace: .displayP3,
            colorConversionPolicy: .convertToSRGB
        )
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)

        let provider = try XCTUnwrap(image.dataProvider)
        let storage = try XCTUnwrap(provider.data) as Data
        XCTAssertGreaterThanOrEqual(storage.count, 4)

        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let sourceColor = try XCTUnwrap(
            CGColor(
                colorSpace: p3,
                components: [
                    CGFloat(input.r) / 255,
                    CGFloat(input.g) / 255,
                    CGFloat(input.b) / 255,
                    1
                ]
            )
        )
        let converted = try XCTUnwrap(
            sourceColor.converted(to: sRGB, intent: .defaultIntent, options: nil)
        )
        let components = try XCTUnwrap(converted.components)
        XCTAssertLessThanOrEqual(abs(Int(storage[2]) - Int(expectedByte(components[0]))), 2)
        XCTAssertLessThanOrEqual(abs(Int(storage[1]) - Int(expectedByte(components[1]))), 2)
        XCTAssertLessThanOrEqual(abs(Int(storage[0]) - Int(expectedByte(components[2]))), 2)
        XCTAssertNotEqual(Array(storage[0...2]), [input.b, input.g, input.r])
    }
}

private func makeOpaqueColorBuffer(
    _ color: GIFTestRGB
) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
        throw ExportError.pixelBufferCreationFailed(status)
    }
    let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
    guard lockStatus == kCVReturnSuccess,
          let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
    else {
        throw ExportError.pixelBufferCreationFailed(lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    bytes[0] = color.b
    bytes[1] = color.g
    bytes[2] = color.r
    bytes[3] = 255
    return buffer
}

private struct GIFTestRGB {
    let b: UInt8
    let g: UInt8
    let r: UInt8
}

private func expectedByte(_ component: CGFloat) -> UInt8 {
    UInt8((min(1, max(0, component)) * 255).rounded())
}

private func makeAlphaPolicyBuffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 2, 1, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
        throw ExportError.pixelBufferCreationFailed(status)
    }
    let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
    guard lockStatus == kCVReturnSuccess,
          let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
    else {
        throw ExportError.pixelBufferCreationFailed(lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    // Premultiplied half-red at alpha 128, followed by a deliberately dirty transparent pixel.
    bytes[0] = 0
    bytes[1] = 0
    bytes[2] = 128
    bytes[3] = 128
    bytes[4] = 20
    bytes[5] = 30
    bytes[6] = 40
    bytes[7] = 0
    return buffer
}

private func decodeBGRA(_ image: CGImage) throws -> Data {
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw ExportError.animatedGIFFinalizeFailed("sRGB is unavailable")
    }
    var data = Data(count: image.width * image.height * 4)
    let drew = data.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress,
              let context = CGContext(
                data: base,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else {
            return false
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard drew else {
        throw ExportError.animatedGIFFinalizeFailed("could not decode GIF alpha fixture")
    }
    return data
}
