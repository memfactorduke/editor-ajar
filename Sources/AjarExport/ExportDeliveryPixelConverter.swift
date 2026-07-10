// SPDX-License-Identifier: GPL-3.0-or-later

import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

/// Host-endian ARGB16U sample used by unit tests and ProRes packing.
struct ExportARGB16UPixel: Equatable, Sendable {
    var a: UInt16
    var r: UInt16
    var g: UInt16
    var b: UInt16
}

/// Presented half-float RGBA sample (graph delivery intermediate).
struct ExportRGBA16FPixel: Equatable, Sendable {
    var r: Float16
    var g: Float16
    var b: Float16
    var a: Float16
}

/// Source geometry for a presented `rgba16Float` buffer.
///
/// Not `Sendable`: it holds a non-owning pointer valid only for the caller's conversion scope.
struct ExportRGBA16FBuffer {
    let baseAddress: UnsafeRawPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

/// CPU-deterministic delivery conversion from presented `rgba16Float` graph output into the
/// encoder pixel formats declared by `AssetWriterSettings` (ADR-0019 / FR-EXP-007).
///
/// Uses Accelerate/vImage only — never Core Image — so conversion is bit-stable across devices
/// for the same source pixels, scale, and destination format.
enum ExportDeliveryPixelConverter {
    private static let sourceBytesPerPixel = 8
    private static let flags = vImage_Flags(kvImageDoNotTile)

    /// Converts presented half-float RGBA pixels into `destination`.
    ///
    /// Source layout is Metal order: top-left origin, interleaved R,G,B,A as IEEE-754 binary16.
    /// Destination format must match `AssetWriterSettings.pixelFormat(for:)`:
    /// `32BGRA`, `64ARGB` (big-endian 16-bit samples), or `420YpCbCr10BiPlanarVideoRange`.
    static func convert(
        source: ExportRGBA16FBuffer,
        destination: CVPixelBuffer
    ) throws {
        guard source.width > 0,
              source.height > 0,
              source.bytesPerRow >= source.width * sourceBytesPerPixel
        else {
            throw ConversionError.invalidSourceGeometry
        }

        let destWidth = CVPixelBufferGetWidth(destination)
        let destHeight = CVPixelBufferGetHeight(destination)
        let destFormat = CVPixelBufferGetPixelFormatType(destination)
        guard destWidth > 0, destHeight > 0 else {
            throw ConversionError.invalidDestinationGeometry
        }

        if source.width == destWidth, source.height == destHeight {
            try convertSameSize(source: source, destination: destination, format: destFormat)
            return
        }

        var scaled = try allocateInterleaved16(width: destWidth, height: destHeight)
        defer { scaled.data?.deallocate() }
        try scaleRGBA16F(source: source, destination: &scaled)
        guard let scaledBase = scaled.data else {
            throw ConversionError.allocationFailed
        }
        let scaledSource = ExportRGBA16FBuffer(
            baseAddress: UnsafeRawPointer(scaledBase),
            width: destWidth,
            height: destHeight,
            bytesPerRow: scaled.rowBytes
        )
        try convertSameSize(
            source: scaledSource,
            destination: destination,
            format: destFormat
        )
    }

    /// Host-endian ARGB16U conversion of a single presented pixel for unit tests.
    ///
    /// Values outside [0, 1] clamp. Output maps 0…1 → 0…65535.
    static func hostARGB16U(from pixel: ExportRGBA16FPixel) throws -> ExportARGB16UPixel {
        var source: [Float16] = [pixel.r, pixel.g, pixel.b, pixel.a]
        var host = [UInt16](repeating: 0, count: 4)
        try source.withUnsafeMutableBytes { sourceBytes in
            guard let sourceBase = sourceBytes.baseAddress else {
                throw ConversionError.invalidSourceGeometry
            }
            try host.withUnsafeMutableBytes { hostBytes in
                guard let hostBase = hostBytes.baseAddress else {
                    throw ConversionError.allocationFailed
                }
                try convertRGBA16FToHostARGB16U(
                    source: ExportRGBA16FBuffer(
                        baseAddress: sourceBase,
                        width: 1,
                        height: 1,
                        bytesPerRow: sourceBytesPerPixel
                    ),
                    destination: hostBase,
                    destinationBytesPerRow: sourceBytesPerPixel
                )
            }
        }
        return ExportARGB16UPixel(a: host[0], r: host[1], g: host[2], b: host[3])
    }

    /// Big-endian sample packing used by `kCVPixelFormatType_64ARGB`.
    static func bigEndianARGB16U(_ host: ExportARGB16UPixel) -> ExportARGB16UPixel {
        ExportARGB16UPixel(
            a: host.a.bigEndian,
            r: host.r.bigEndian,
            g: host.g.bigEndian,
            b: host.b.bigEndian
        )
    }

    // MARK: - Format dispatch

    private static func convertSameSize(
        source: ExportRGBA16FBuffer,
        destination: CVPixelBuffer,
        format: OSType
    ) throws {
        switch format {
        case kCVPixelFormatType_64ARGB:
            try ExportDeliveryRGBPacker.pack64ARGB(source: source, destination: destination)
        case kCVPixelFormatType_32BGRA:
            try ExportDeliveryRGBPacker.pack32BGRA(source: source, destination: destination)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            try ExportDeliveryYpCbCrPacker.pack10BitBiPlanar(
                source: source,
                destination: destination
            )
        default:
            throw ConversionError.unsupportedDestinationFormat(format)
        }
    }

    // MARK: - Shared half-float helpers

    static func convertRGBA16FToHostARGB16U(
        source: ExportRGBA16FBuffer,
        destination: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int
    ) throws {
        // RGBA16F → ARGB16F (channel permute), then half-float → unsigned 16-bit host ARGB.
        var permuted = try allocateInterleaved16(width: source.width, height: source.height)
        defer { permuted.data?.deallocate() }

        var srcBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source.baseAddress),
            height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width),
            rowBytes: source.bytesPerRow
        )
        // dest[i] = src[permuteMap[i]]; ARGB from RGBA ⇒ indices [3,0,1,2].
        let rgbaToARGB: [UInt8] = [3, 0, 1, 2]
        try check(
            vImagePermuteChannels_ARGB16U(&srcBuffer, &permuted, rgbaToARGB, flags),
            operation: "permute presented RGBA16F to ARGB16F"
        )

        var argb16F = permuted
        argb16F.width = vImagePixelCount(source.width * 4)
        var destBuffer = vImage_Buffer(
            data: destination,
            height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width * 4),
            rowBytes: destinationBytesPerRow
        )
        try check(
            vImageConvert_16Fto16U(&argb16F, &destBuffer, flags),
            operation: "convert ARGB16F to host ARGB16U"
        )
    }

    static func makeHostARGB16UBuffer(
        from source: ExportRGBA16FBuffer
    ) throws -> vImage_Buffer {
        let host = try allocateInterleaved16(width: source.width, height: source.height)
        guard let hostBase = host.data else {
            host.data?.deallocate()
            throw ConversionError.allocationFailed
        }
        do {
            try convertRGBA16FToHostARGB16U(
                source: source,
                destination: hostBase,
                destinationBytesPerRow: host.rowBytes
            )
        } catch {
            host.data?.deallocate()
            throw error
        }
        return host
    }

    /// Scales interleaved half-float RGBA to `destination` (also interleaved half-float).
    ///
    /// Portable path used on every OS: **16F → FFFF → `vImageScale_ARGBFFFF` → 16F**.
    /// `vImageScale_ARGB16F` returns `kvImageInvalidImageFormat` (-21775) on some macOS 14
    /// vImage builds; branching on OS would make CI and local pixels diverge (FR-EXP-007).
    private static func scaleRGBA16F(
        source: ExportRGBA16FBuffer,
        destination: inout vImage_Buffer
    ) throws {
        let destWidth = Int(destination.width)
        let destHeight = Int(destination.height)
        var sourceFloat = try allocateInterleavedFloat(
            width: source.width,
            height: source.height
        )
        defer { sourceFloat.data?.deallocate() }
        var scaledFloat = try allocateInterleavedFloat(width: destWidth, height: destHeight)
        defer { scaledFloat.data?.deallocate() }

        try convertInterleaved16FtoFloat(source: source, destination: &sourceFloat)
        try check(
            vImageScale_ARGBFFFF(
                &sourceFloat,
                &scaledFloat,
                nil,
                flags | vImage_Flags(kvImageHighQualityResampling)
            ),
            operation: "scale presented RGBA float to delivery raster"
        )
        try convertInterleavedFloatTo16F(source: &scaledFloat, destination: &destination)
    }

    /// Interleaved half-float (any 4-channel order) → interleaved Float32.
    private static func convertInterleaved16FtoFloat(
        source: ExportRGBA16FBuffer,
        destination: inout vImage_Buffer
    ) throws {
        // Treat 4-channel rows as planar with width × 4 (documented for Planar16FtoPlanarF).
        var srcBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source.baseAddress),
            height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width * 4),
            rowBytes: source.bytesPerRow
        )
        let pixelWidth = destination.width
        destination.width = vImagePixelCount(Int(pixelWidth) * 4)
        defer { destination.width = pixelWidth }
        try check(
            vImageConvert_Planar16FtoPlanarF(&srcBuffer, &destination, flags),
            operation: "promote RGBA16F to float for portable scaling"
        )
    }

    /// Interleaved Float32 → interleaved half-float (same channel order).
    private static func convertInterleavedFloatTo16F(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer
    ) throws {
        let srcPixelWidth = source.width
        let destPixelWidth = destination.width
        source.width = vImagePixelCount(Int(srcPixelWidth) * 4)
        destination.width = vImagePixelCount(Int(destPixelWidth) * 4)
        defer {
            source.width = srcPixelWidth
            destination.width = destPixelWidth
        }
        try check(
            vImageConvert_PlanarFtoPlanar16F(&source, &destination, flags),
            operation: "demote scaled float back to RGBA16F"
        )
    }

    static func allocateInterleaved16(width: Int, height: Int) throws -> vImage_Buffer {
        try allocateInterleaved(width: width, height: height, bitsPerPixel: 64)
    }

    static func allocateInterleavedFloat(width: Int, height: Int) throws -> vImage_Buffer {
        try allocateInterleaved(width: width, height: height, bitsPerPixel: 128)
    }

    private static func allocateInterleaved(
        width: Int,
        height: Int,
        bitsPerPixel: UInt32
    ) throws -> vImage_Buffer {
        var buffer = vImage_Buffer()
        let error = vImageBuffer_Init(
            &buffer,
            vImagePixelCount(height),
            vImagePixelCount(width),
            bitsPerPixel,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError, buffer.data != nil else {
            throw ConversionError.allocationFailed
        }
        return buffer
    }

    static func lock(_ pixelBuffer: CVPixelBuffer) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw ConversionError.destinationLockFailed
        }
    }

    static func unlock(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    static func check(_ error: vImage_Error, operation: String) throws {
        guard error == kvImageNoError else {
            throw ConversionError.vImageFailed("\(operation) failed with vImage error \(error)")
        }
    }

    enum ConversionError: Error, Equatable, CustomStringConvertible {
        case invalidSourceGeometry
        case invalidDestinationGeometry
        case unsupportedDestinationFormat(OSType)
        case allocationFailed
        case destinationLockFailed
        case colorSpaceUnavailable
        case vImageFailed(String)

        var description: String {
            switch self {
            case .invalidSourceGeometry:
                "delivery conversion source geometry is invalid"
            case .invalidDestinationGeometry:
                "delivery conversion destination geometry is invalid"
            case .unsupportedDestinationFormat(let format):
                "unsupported delivery pixel format \(fourCC(format))"
            case .allocationFailed:
                "delivery conversion could not allocate a working buffer"
            case .destinationLockFailed:
                "delivery conversion could not lock the encoder pixel buffer"
            case .colorSpaceUnavailable:
                "delivery conversion Rec.709 color space is unavailable"
            case .vImageFailed(let reason):
                reason
            }
        }

        private func fourCC(_ value: OSType) -> String {
            let bytes = [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
            return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
        }
    }
}

// MARK: - RGB packers (32BGRA / 64ARGB)

enum ExportDeliveryRGBPacker {
    private static let flags = vImage_Flags(kvImageDoNotTile)

    static func pack64ARGB(
        source: ExportRGBA16FBuffer,
        destination: CVPixelBuffer
    ) throws {
        let host = try ExportDeliveryPixelConverter.makeHostARGB16UBuffer(from: source)
        defer { host.data?.deallocate() }

        try ExportDeliveryPixelConverter.lock(destination)
        defer { ExportDeliveryPixelConverter.unlock(destination) }

        guard let base = CVPixelBufferGetBaseAddress(destination), let hostData = host.data else {
            throw ExportDeliveryPixelConverter.ConversionError.destinationLockFailed
        }
        let destRowBytes = CVPixelBufferGetBytesPerRow(destination)
        var srcBuffer = vImage_Buffer(
            data: hostData,
            height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width * 4),
            rowBytes: host.rowBytes
        )
        var destBuffer = vImage_Buffer(
            data: base,
            height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width * 4),
            rowBytes: destRowBytes
        )
        try ExportDeliveryPixelConverter.check(
            vImageByteSwap_Planar16U(&srcBuffer, &destBuffer, flags),
            operation: "byte-swap host ARGB16U to big-endian 64ARGB"
        )
    }

    static func pack32BGRA(
        source: ExportRGBA16FBuffer,
        destination: CVPixelBuffer
    ) throws {
        let host = try ExportDeliveryPixelConverter.makeHostARGB16UBuffer(from: source)
        defer { host.data?.deallocate() }

        try ExportDeliveryPixelConverter.lock(destination)
        defer { ExportDeliveryPixelConverter.unlock(destination) }

        guard let base = CVPixelBufferGetBaseAddress(destination), let hostData = host.data else {
            throw ExportDeliveryPixelConverter.ConversionError.destinationLockFailed
        }
        let destRowBytes = CVPixelBufferGetBytesPerRow(destination)
        var srcBuffer = vImage_Buffer(
            data: hostData,
            height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width),
            rowBytes: host.rowBytes
        )
        var destBuffer = vImage_Buffer(
            data: base,
            height: vImagePixelCount(source.height),
            width: vImagePixelCount(source.width),
            rowBytes: destRowBytes
        )
        // ARGB host → BGRA8888: dest [B,G,R,A] from src [A,R,G,B] indices [3,2,1,0].
        let permuteMap: [UInt8] = [3, 2, 1, 0]
        var background: [UInt8] = [0, 0, 0, 0]
        try ExportDeliveryPixelConverter.check(
            vImageConvert_ARGB16UToARGB8888(
                &srcBuffer,
                &destBuffer,
                permuteMap,
                0,
                &background,
                flags
            ),
            operation: "convert host ARGB16U to 32BGRA"
        )
    }
}
