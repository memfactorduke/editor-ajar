// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreVideo
import Foundation

/// Typed failures while copying a delivery BGRA buffer into Core Graphics-owned storage.
enum BGRAImageBridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedPixelFormat(OSType)
    case invalidDimensions(width: Int, height: Int)
    case invalidBytesPerRow(actual: Int, minimum: Int)
    case lockFailed(CVReturn)
    case missingBaseAddress
    case allocationOverflow(width: Int, height: Int)
    case colorSpaceUnavailable(String)
    case dataProviderCreationFailed
    case imageCreationFailed
    case colorConversionContextCreationFailed

    var description: String {
        switch self {
        case .unsupportedPixelFormat(let format):
            "pixel buffer format \(format) is not 32BGRA"
        case .invalidDimensions(let width, let height):
            "pixel buffer dimensions \(width)x\(height) are invalid"
        case .invalidBytesPerRow(let actual, let minimum):
            "pixel buffer row stride \(actual) is smaller than \(minimum)"
        case .lockFailed(let status):
            "could not lock BGRA pixel buffer (\(status))"
        case .missingBaseAddress:
            "BGRA pixel buffer has no base address"
        case .allocationOverflow(let width, let height):
            "BGRA storage size overflows for \(width)x\(height)"
        case .colorSpaceUnavailable(let name):
            "Core Graphics color space \(name) is unavailable"
        case .dataProviderCreationFailed:
            "could not create a BGRA data provider"
        case .imageCreationFailed:
            "could not create a CGImage from BGRA pixels"
        case .colorConversionContextCreationFailed:
            "could not create the sRGB color-conversion context"
        }
    }
}

/// Bridges reusable CVPixelBuffers into images whose pixel bytes remain valid after unlock/reuse.
enum BGRAImageBridge {
    private static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    )

    /// Copies a 32BGRA pixel buffer into immutable provider-owned storage and tags it correctly.
    ///
    /// `CGImageDestinationAddImage` may retain its image until destination finalization. Building a
    /// CGImage over a locked CVPixelBuffer would therefore be unsafe once that buffer is unlocked or
    /// reused for the next rendered frame. The data provider returned here retains an immutable
    /// `CFData` copy, so the image has no lifetime dependency on the source pixel buffer.
    static func makeOwnedCGImage(
        from pixelBuffer: CVPixelBuffer,
        colorSpace: ExportColorSpace
    ) throws -> CGImage {
        let storage = try packedBGRA8(from: pixelBuffer)
        let cgColorSpace: CGColorSpace
        do {
            cgColorSpace = try ExportColorTagging.cgColorSpace(for: colorSpace)
        } catch {
            throw BGRAImageBridgeError.colorSpaceUnavailable(colorSpace.rawValue)
        }
        return try makeOwnedCGImage(
            storage: storage,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            colorSpace: cgColorSpace
        )
    }

    /// Converts delivery-tagged pixels into owned sRGB pixels for GIF palette generation.
    ///
    /// GIF has no dependable wide-gamut/Rec.709 color-profile path. Core Graphics performs a real
    /// source-to-sRGB conversion here; assigning an sRGB label to the source bytes would visibly
    /// shift Display P3 and Rec.709 exports. Both contexts use premultiplied-alpha BGRA, preserving
    /// coverage while the color components are converted.
    static func makeOwnedSRGBCGImage(
        from pixelBuffer: CVPixelBuffer,
        sourceColorSpace: ExportColorSpace,
        colorConversionPolicy: AnimatedGIFColorConversionPolicy
    ) throws -> CGImage {
        switch colorConversionPolicy {
        case .convertToSRGB:
            break
        }
        let sourceImage = try makeOwnedCGImage(
            from: pixelBuffer,
            colorSpace: sourceColorSpace
        )
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw BGRAImageBridgeError.colorSpaceUnavailable("sRGB")
        }

        let dimensions = try storageDimensions(
            width: sourceImage.width,
            height: sourceImage.height
        )
        var converted = Data(count: dimensions.byteCount)
        let madeContext = converted.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else {
                return false
            }
            guard let context = CGContext(
                data: baseAddress,
                width: sourceImage.width,
                height: sourceImage.height,
                bitsPerComponent: 8,
                bytesPerRow: dimensions.bytesPerRow,
                space: sRGB,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                sourceImage,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: sourceImage.width,
                    height: sourceImage.height
                )
            )
            return true
        }
        guard madeContext else {
            throw BGRAImageBridgeError.colorConversionContextCreationFailed
        }

        // GIF carries only binary transparency. Preserve pixels that are fully transparent,
        // but matte every partially covered pixel over the editor's black canvas by keeping its
        // premultiplied RGB and making it opaque. Doing this before ImageIO avoids OS-dependent
        // alpha thresholding/unpremultiplication and keeps antialiased title edges deterministic.
        applyGIFBinaryAlpha(to: &converted, pixelCount: sourceImage.width * sourceImage.height)

        return try makeOwnedCGImage(
            storage: converted,
            width: sourceImage.width,
            height: sourceImage.height,
            colorSpace: sRGB
        )
    }

    private static func applyGIFBinaryAlpha(to data: inout Data, pixelCount: Int) {
        data.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                if bytes[offset + 3] == 0 {
                    bytes[offset] = 0
                    bytes[offset + 1] = 0
                    bytes[offset + 2] = 0
                } else {
                    bytes[offset + 3] = 255
                }
            }
        }
    }

    /// Copies tightly packed BGRA8 row-by-row, excluding any CVPixelBuffer row padding.
    static func packedBGRA8(from pixelBuffer: CVPixelBuffer) throws -> Data {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw BGRAImageBridgeError.unsupportedPixelFormat(
                CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let dimensions = try storageDimensions(width: width, height: height)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sourceBytesPerRow >= dimensions.bytesPerRow else {
            throw BGRAImageBridgeError.invalidBytesPerRow(
                actual: sourceBytesPerRow,
                minimum: dimensions.bytesPerRow
            )
        }

        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw BGRAImageBridgeError.lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw BGRAImageBridgeError.missingBaseAddress
        }
        var storage = Data(count: dimensions.byteCount)
        storage.withUnsafeMutableBytes { rawBuffer in
            guard let destinationBaseAddress = rawBuffer.baseAddress else {
                return
            }
            for row in 0..<height {
                memcpy(
                    destinationBaseAddress.advanced(by: row * dimensions.bytesPerRow),
                    sourceBaseAddress.advanced(by: row * sourceBytesPerRow),
                    dimensions.bytesPerRow
                )
            }
        }
        return storage
    }

    private static func makeOwnedCGImage(
        storage: Data,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        let dimensions = try storageDimensions(width: width, height: height)
        guard storage.count == dimensions.byteCount else {
            throw BGRAImageBridgeError.invalidBytesPerRow(
                actual: storage.count,
                minimum: dimensions.byteCount
            )
        }
        guard let provider = CGDataProvider(data: storage as CFData) else {
            throw BGRAImageBridgeError.dataProviderCreationFailed
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: dimensions.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw BGRAImageBridgeError.imageCreationFailed
        }
        return image
    }

    private static func storageDimensions(
        width: Int,
        height: Int
    ) throws -> (bytesPerRow: Int, byteCount: Int) {
        guard width > 0, height > 0 else {
            throw BGRAImageBridgeError.invalidDimensions(width: width, height: height)
        }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !countOverflow else {
            throw BGRAImageBridgeError.allocationOverflow(width: width, height: height)
        }
        return (bytesPerRow, byteCount)
    }
}
