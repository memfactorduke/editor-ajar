// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// BGRA8 image payload used by the offline PNG harness.
public struct PNGImage: Equatable, Sendable {
    /// Pixel width.
    public let width: Int

    /// Pixel height.
    public let height: Int

    /// BGRA8 bytes, one row after another.
    public let bgra8: [UInt8]

    /// Creates a BGRA8 image payload.
    public init(width: Int, height: Int, bgra8: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra8 = bgra8
    }
}

/// PNG encoder/decoder used by `ajar render` and golden-frame tests.
public enum PNGCodec {
    /// Writes a BGRA8 image as PNG.
    public static func write(_ image: PNGImage, to url: URL) throws {
        guard image.width > 0, image.height > 0 else {
            throw AjarCLIError.pngFailed("image dimensions must be positive")
        }
        guard image.bgra8.count == image.width * image.height * 4 else {
            throw AjarCLIError.pngFailed("image byte count does not match dimensions")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = Data(image.bgra8)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw AjarCLIError.pngFailed("could not create image data provider")
        }
        guard
            let cgImage = CGImage(
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bgraBitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw AjarCLIError.pngFailed("could not create CGImage")
        }
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw AjarCLIError.pngFailed("could not create PNG destination")
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AjarCLIError.pngFailed("could not finalize PNG")
        }
    }

    /// Reads a PNG into BGRA8 bytes.
    public static func read(from url: URL) throws -> PNGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AjarCLIError.pngFailed("could not read PNG at \(url.path)")
        }

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw AjarCLIError.pngFailed("could not pin decode bitmap buffer")
            }
            guard
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bgraBitmapInfo.rawValue
                )
            else {
                throw AjarCLIError.pngFailed("could not create decode bitmap context")
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.flush()
        }
        return PNGImage(width: width, height: height, bgra8: bytes)
    }

    private static let bgraBitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
    )
    .union(.byteOrder32Little)
}
