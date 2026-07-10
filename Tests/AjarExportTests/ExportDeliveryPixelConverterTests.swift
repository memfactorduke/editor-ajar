// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

final class ExportDeliveryPixelConverterTests: XCTestCase {
    func testFREXP007HostARGB16UMapsHalfFloatUnitInterval() throws {
        let black = try ExportDeliveryPixelConverter.hostARGB16U(
            from: ExportRGBA16FPixel(r: 0, g: 0, b: 0, a: 1)
        )
        XCTAssertEqual(black.a, 65_535)
        XCTAssertEqual(black.r, 0)
        XCTAssertEqual(black.g, 0)
        XCTAssertEqual(black.b, 0)

        let white = try ExportDeliveryPixelConverter.hostARGB16U(
            from: ExportRGBA16FPixel(r: 1, g: 1, b: 1, a: 1)
        )
        XCTAssertEqual(white.a, 65_535)
        XCTAssertEqual(white.r, 65_535)
        XCTAssertEqual(white.g, 65_535)
        XCTAssertEqual(white.b, 65_535)

        let mid = try ExportDeliveryPixelConverter.hostARGB16U(
            from: ExportRGBA16FPixel(r: 0.5, g: 0, b: 0, a: 0.5)
        )
        XCTAssertEqual(mid.a, 32_768)
        XCTAssertEqual(mid.r, 32_768)
        XCTAssertEqual(mid.g, 0)
        XCTAssertEqual(mid.b, 0)
    }

    func testFREXP007ProRes64ARGBUsesBigEndianSamples() throws {
        let host = try ExportDeliveryPixelConverter.hostARGB16U(
            from: ExportRGBA16FPixel(r: 1, g: 0.5, b: 0, a: 1)
        )
        let be = ExportDeliveryPixelConverter.bigEndianARGB16U(host)
        XCTAssertEqual(be.a, host.a.bigEndian)
        XCTAssertEqual(be.r, host.r.bigEndian)
        XCTAssertEqual(be.g, host.g.bigEndian)
        XCTAssertEqual(be.b, host.b.bigEndian)
    }

    func testFREXP007ConvertsPresentedRGBA16FIntoProRes64ARGBBuffer() throws {
        // One red opaque pixel: R=1, G=0, B=0, A=1 as half-float.
        let source: [Float16] = [1, 0, 0, 1]
        let buffer = try makePixelBuffer(width: 1, height: 1, format: kCVPixelFormatType_64ARGB)
        try convert(source: source, width: 1, height: 1, into: buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let samples = base.assumingMemoryBound(to: UInt16.self)
        // Big-endian ARGB: A=1, R=1, G=0, B=0
        XCTAssertEqual(UInt16(bigEndian: samples[0]), 65_535)
        XCTAssertEqual(UInt16(bigEndian: samples[1]), 65_535)
        XCTAssertEqual(UInt16(bigEndian: samples[2]), 0)
        XCTAssertEqual(UInt16(bigEndian: samples[3]), 0)
    }

    func testFREXP007ConvertsPresentedRGBA16FIntoH26432BGRABuffer() throws {
        let source: [Float16] = [1, 0, 0, 1]
        let buffer = try makePixelBuffer(width: 1, height: 1, format: kCVPixelFormatType_32BGRA)
        try convert(source: source, width: 1, height: 1, into: buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let samples = base.assumingMemoryBound(to: UInt8.self)
        // BGRA: B=0, G=0, R=255, A=255
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0)
        XCTAssertEqual(samples[2], 255)
        XCTAssertEqual(samples[3], 255)
    }

    func testFREXP007ScalesDeliveryRasterBeforeFormatPacking() throws {
        // 2×2 solid green → 1×1 BGRA.
        let source: [Float16] = [
            0, 1, 0, 1,
            0, 1, 0, 1,
            0, 1, 0, 1,
            0, 1, 0, 1
        ]
        let buffer = try makePixelBuffer(width: 1, height: 1, format: kCVPixelFormatType_32BGRA)
        try convert(source: source, width: 2, height: 2, into: buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let samples = base.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(samples[0], 0) // B
        XCTAssertEqual(samples[1], 255) // G
        XCTAssertEqual(samples[2], 0) // R
        XCTAssertEqual(samples[3], 255) // A
    }

    func testFREXP001YpCbCr10VideoRangeCodesMatchBT709() {
        // Black → Y=64, white → Y=940, mid-chroma = 512; packed as code << 6.
        XCTAssertEqual(ExportDeliveryYpCbCrPacker.lumaCode10(r: 0, g: 0, b: 0), 64)
        XCTAssertEqual(ExportDeliveryYpCbCrPacker.lumaCode10(r: 1, g: 1, b: 1), 940)
        let blackChroma = ExportDeliveryYpCbCrPacker.chromaCodes10(r: 0, g: 0, b: 0)
        XCTAssertEqual(blackChroma.cb, 512)
        XCTAssertEqual(blackChroma.cr, 512)
        let whiteChroma = ExportDeliveryYpCbCrPacker.chromaCodes10(r: 1, g: 1, b: 1)
        XCTAssertEqual(whiteChroma.cb, 512)
        XCTAssertEqual(whiteChroma.cr, 512)
        XCTAssertEqual(ExportDeliveryYpCbCrPacker.pack10BitForTests(940), 940 << 6)
        XCTAssertEqual(ExportDeliveryYpCbCrPacker.pack10BitForTests(64), 64 << 6)
    }

    func testFREXP001ConvertsPresentedRGBA16FIntoHEVC10X420Buffer() throws {
        // 2×2 white opaque → one chroma sample at neutral, luma 940.
        let source: [Float16] = [
            1, 1, 1, 1,
            1, 1, 1, 1,
            1, 1, 1, 1,
            1, 1, 1, 1
        ]
        let buffer = try makePixelBuffer(
            width: 2,
            height: 2,
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        try convert(source: source, width: 2, height: 2, into: buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let y0 = yBase.assumingMemoryBound(to: UInt16.self)[0]
        let y1 = yBase.advanced(by: yRowBytes).assumingMemoryBound(to: UInt16.self)[0]
        XCTAssertEqual(y0, UInt16(940 << 6))
        XCTAssertEqual(y1, UInt16(940 << 6))

        let cbcrBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let cbcr = cbcrBase.assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(cbcr[0], UInt16(512 << 6)) // Cb
        XCTAssertEqual(cbcr[1], UInt16(512 << 6)) // Cr
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        format: OSType
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, nil, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func convert(
        source: [Float16],
        width: Int,
        height: Int,
        into destination: CVPixelBuffer
    ) throws {
        try source.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                XCTFail("source buffer was empty")
                return
            }
            try ExportDeliveryPixelConverter.convert(
                source: ExportRGBA16FBuffer(
                    baseAddress: base,
                    width: width,
                    height: height,
                    bytesPerRow: width * 8
                ),
                destination: destination
            )
        }
    }
}
