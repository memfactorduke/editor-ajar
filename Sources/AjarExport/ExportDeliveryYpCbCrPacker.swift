// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation

/// CPU-deterministic packing into `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`x420`).
///
/// Accelerate's `vImageCVImageFormat` does not recognize `x420` ("unknown CVPixelFormatType"),
/// so conversion is explicit: host ARGB16U → BT.709 Y'CbCr → 4:2:0 subsample → 10-bit codes
/// stored in the MSBs of `UInt16` (`code << 6`), video range Y∈[64,940], Cb/Cr∈[64,960].
enum ExportDeliveryYpCbCrPacker {
    /// BT.709 luma weights (ITU-R BT.709-6).
    private static let wr: Float = 0.2126
    private static let wg: Float = 0.7152
    private static let wb: Float = 0.0722
    /// Chroma scale factors such that Cb/Cr ∈ [-0.5, 0.5] for unit RGB.
    private static let cbDenom: Float = 1.8556
    private static let crDenom: Float = 1.5748
    /// 10-bit video-range encoding (8-bit 16/235/128/240 × 4).
    private static let yBias = 64
    private static let yRange = 876 // 940 - 64
    private static let chromaBias = 512
    private static let chromaRange = 896 // 960 - 64, full swing about mid
    private static let tenBitMax = 1_023
    private static let msbShift = 6

    static func pack10BitBiPlanar(
        source: ExportRGBA16FBuffer,
        destination: CVPixelBuffer
    ) throws {
        guard source.width.isMultiple(of: 2), source.height.isMultiple(of: 2) else {
            throw ExportDeliveryPixelConverter.ConversionError.invalidDestinationGeometry
        }
        let host = try ExportDeliveryPixelConverter.makeHostARGB16UBuffer(from: source)
        defer { host.data?.deallocate() }
        guard let hostData = host.data else {
            throw ExportDeliveryPixelConverter.ConversionError.allocationFailed
        }

        try ExportDeliveryPixelConverter.lock(destination)
        defer { ExportDeliveryPixelConverter.unlock(destination) }

        guard
            let yBase = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
            let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(destination, 1)
        else {
            throw ExportDeliveryPixelConverter.ConversionError.destinationLockFailed
        }

        let planes = decodeBT709Planes(
            hostARGB16U: hostData,
            width: source.width,
            height: source.height,
            sourceRowBytes: host.rowBytes
        )
        let size = (width: source.width, height: source.height)
        writeLumaPlane(
            planes.y,
            size: size,
            destination: yBase,
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        )
        writeChromaPlane(
            cb: planes.cb,
            cr: planes.cr,
            size: size,
            destination: cbcrBase,
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        )
    }

    /// Unit tests: BT.709 video-range 10-bit luma code for unit RGB (premultiplied).
    static func lumaCode10(r: Float, g: Float, b: Float) -> Int {
        encodeLuma(wr * r + wg * g + wb * b)
    }

    /// Unit tests: BT.709 video-range 10-bit chroma codes for unit RGB.
    static func chromaCodes10(r: Float, g: Float, b: Float) -> (cb: Int, cr: Int) {
        let y = wr * r + wg * g + wb * b
        return (
            encodeChroma((b - y) / cbDenom),
            encodeChroma((r - y) / crDenom)
        )
    }

    /// Unit tests: 10-bit code packed into `UInt16` MSBs (`code << 6`).
    static func pack10BitForTests(_ code: Int) -> UInt16 {
        pack10Bit(code: code)
    }

    // MARK: - Internals

    private struct BT709Planes {
        var y: [Float]
        var cb: [Float]
        var cr: [Float]
    }

    private static func decodeBT709Planes(
        hostARGB16U: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        sourceRowBytes: Int
    ) -> BT709Planes {
        var yPlane = [Float](repeating: 0, count: width * height)
        var cbPlane = [Float](repeating: 0, count: width * height)
        var crPlane = [Float](repeating: 0, count: width * height)
        let srcU16 = hostARGB16U.assumingMemoryBound(to: UInt16.self)
        for row in 0..<height {
            let srcRow = srcU16.advanced(by: row * (sourceRowBytes / 2))
            let outRow = row * width
            for col in 0..<width {
                let pixel = srcRow.advanced(by: col * 4)
                // Host ARGB16U: A,R,G,B. Premultiplied RGB over black is the encoder input.
                let r = Float(pixel[1]) / 65_535
                let g = Float(pixel[2]) / 65_535
                let b = Float(pixel[3]) / 65_535
                let y = wr * r + wg * g + wb * b
                let index = outRow + col
                yPlane[index] = y
                cbPlane[index] = (b - y) / cbDenom
                crPlane[index] = (r - y) / crDenom
            }
        }
        return BT709Planes(y: yPlane, cb: cbPlane, cr: crPlane)
    }

    private static func writeLumaPlane(
        _ yPlane: [Float],
        size: (width: Int, height: Int),
        destination: UnsafeMutableRawPointer,
        bytesPerRow: Int
    ) {
        for row in 0..<size.height {
            let yRow = destination.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            let srcRow = row * size.width
            for col in 0..<size.width {
                yRow[col] = pack10Bit(code: encodeLuma(yPlane[srcRow + col]))
            }
        }
    }

    private static func writeChromaPlane(
        cb: [Float],
        cr: [Float],
        size: (width: Int, height: Int),
        destination: UnsafeMutableRawPointer,
        bytesPerRow: Int
    ) {
        // 4:2:0 box average of each 2×2 (centered siting).
        let chromaHeight = size.height / 2
        let chromaWidth = size.width / 2
        for row in 0..<chromaHeight {
            let cbcrRow = destination.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            let y0 = row * 2
            let y1 = y0 + 1
            for col in 0..<chromaWidth {
                let x0 = col * 2
                let x1 = x0 + 1
                let i00 = y0 * size.width + x0
                let i01 = y0 * size.width + x1
                let i10 = y1 * size.width + x0
                let i11 = y1 * size.width + x1
                let cbAvg = (cb[i00] + cb[i01] + cb[i10] + cb[i11]) * 0.25
                let crAvg = (cr[i00] + cr[i01] + cr[i10] + cr[i11]) * 0.25
                let out = col * 2
                cbcrRow[out] = pack10Bit(code: encodeChroma(cbAvg))
                cbcrRow[out + 1] = pack10Bit(code: encodeChroma(crAvg))
            }
        }
    }

    private static func encodeLuma(_ y: Float) -> Int {
        let code = Int((Float(yBias) + Float(yRange) * clamp01(y)).rounded())
        return min(max(code, 0), tenBitMax)
    }

    private static func encodeChroma(_ chroma: Float) -> Int {
        let code = Int((Float(chromaBias) + Float(chromaRange) * chroma).rounded())
        return min(max(code, 0), tenBitMax)
    }

    private static func pack10Bit(code: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: code << msbShift)
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
