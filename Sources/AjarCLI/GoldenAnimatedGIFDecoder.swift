// SPDX-License-Identifier: GPL-3.0-or-later

import AjarExport
import CoreGraphics
import Foundation
import ImageIO

/// Decoded pixels and structural timing metadata for one animated-GIF golden.
struct GoldenAnimatedGIFDecodeResult: Equatable, Sendable {
    let frames: [ExportDecodedBGRAFrame]
    let delayCentiseconds: [Int]
    let loopCount: Int?
}

/// ImageIO decoder and independent source-profile-to-sRGB golden conversion.
enum GoldenAnimatedGIFDecoder {
    private static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    )

    static func decode(from url: URL) throws -> GoldenAnimatedGIFDecodeResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ExportError.animatedGIFFinalizeFailed("golden decode could not open GIF")
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw ExportError.animatedGIFFinalizeFailed("golden decode found no GIF frames")
        }

        var frames: [ExportDecodedBGRAFrame] = []
        var delays: [Int] = []
        frames.reserveCapacity(frameCount)
        delays.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw ExportError.animatedGIFFrameWriteFailed(
                    frameIndex: Int64(index),
                    reason: "golden decode could not create image"
                )
            }
            frames.append(try drawIntoSRGB(image).flattenedOverOpaqueBlack())
            delays.append(try delayCentiseconds(source: source, index: index))
        }

        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loopCount = (gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue
        return GoldenAnimatedGIFDecodeResult(
            frames: frames,
            delayCentiseconds: delays,
            loopCount: loopCount
        )
    }

    /// Converts raw render-delivery BGRA into the sRGB space used before GIF palette generation.
    static func convertExpectedToSRGB(
        _ frames: [ExportDecodedBGRAFrame],
        sourceColorSpace: ExportColorSpace
    ) throws -> [ExportDecodedBGRAFrame] {
        try frames.map { frame in
            let image = try makeSourceImage(frame, colorSpace: sourceColorSpace)
            return try drawIntoSRGB(image).flattenedOverOpaqueBlack()
        }
    }

    private static func delayCentiseconds(
        source: CGImageSource,
        index: Int
    ) throws -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let seconds = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        guard let seconds, seconds.isFinite, seconds > 0 else {
            throw ExportError.animatedGIFFrameWriteFailed(
                frameIndex: Int64(index),
                reason: "golden decode found no positive frame delay"
            )
        }
        return Int((seconds * 100).rounded())
    }

    private static func makeSourceImage(
        _ frame: ExportDecodedBGRAFrame,
        colorSpace: ExportColorSpace
    ) throws -> CGImage {
        guard frame.bgra8.count == frame.expectedByteCount else {
            throw ExportError.animatedGIFFrameWriteFailed(
                frameIndex: 0,
                reason: "golden expected BGRA byte count is invalid"
            )
        }
        let name: CFString = colorSpace == .displayP3
            ? CGColorSpace.displayP3
            : CGColorSpace.itur_709
        guard let sourceSpace = CGColorSpace(name: name),
              let provider = CGDataProvider(data: frame.bgra8 as CFData),
              let image = CGImage(
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: frame.width * 4,
                space: sourceSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw ExportError.animatedGIFFrameWriteFailed(
                frameIndex: 0,
                reason: "golden expected BGRA image creation failed"
            )
        }
        return image
    }

    private static func drawIntoSRGB(_ image: CGImage) throws -> ExportDecodedBGRAFrame {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ExportError.animatedGIFFinalizeFailed("sRGB color space is unavailable")
        }
        let bytesPerRow = image.width * 4
        var bytes = Data(count: bytesPerRow * image.height)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: sRGB,
                    bitmapInfo: bitmapInfo.rawValue
                  )
            else {
                return false
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard drew else {
            throw ExportError.animatedGIFFinalizeFailed(
                "golden decode could not create the sRGB context"
            )
        }
        return ExportDecodedBGRAFrame(width: image.width, height: image.height, bgra8: bytes)
    }
}
