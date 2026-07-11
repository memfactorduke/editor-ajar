// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal

/// ImageIO still decode + path-keyed cache for FR-MED-002 timeline media.
///
/// Stills are time-invariant: one pixel buffer is uploaded to a Metal-compatible surface and
/// reused for every presentation time. Owned by ``VideoFrameDecoder`` so the public decode API
/// stays a single entry point.
///
/// **Animated GIF / multi-image containers:** only index 0 (first frame) is decoded. Multi-frame
/// still sequences are not expanded into clip sequences.
final class StillImageFrameDecoder {
    private let pixelFormat: OSType
    private let metalPixelFormat: MTLPixelFormat
    private let textureCache: CVMetalTextureCache
    private let stillPixelBufferCache = NSCache<NSString, CVPixelBufferBox>()
    private let blockingQueue: DispatchQueue

    init(
        pixelFormat: OSType,
        metalPixelFormat: MTLPixelFormat,
        textureCache: CVMetalTextureCache,
        blockingQueue: DispatchQueue
    ) {
        self.pixelFormat = pixelFormat
        self.metalPixelFormat = metalPixelFormat
        self.textureCache = textureCache
        self.blockingQueue = blockingQueue
        stillPixelBufferCache.countLimit = 64
    }

    /// Decodes a still at `time` (presentation time is stamped; pixels ignore time).
    func decode(from sourceURL: URL, at time: RationalTime) async throws -> DecodedFrame {
        let startedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        try Self.requireAvailableSource(sourceURL)

        let cacheKey = sourceURL.standardizedFileURL.resolvingSymlinksInPath().path as NSString
        if let cached = stillPixelBufferCache.object(forKey: cacheKey) {
            return DecodedFrame(
                pixelBuffer: cached.pixelBuffer,
                metalTexture: try makeMetalTexture(for: cached.pixelBuffer),
                presentationTime: time
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                do {
                    let pixelBuffer = try self.loadStillPixelBuffer(from: sourceURL)
                    self.stillPixelBufferCache.setObject(
                        CVPixelBufferBox(pixelBuffer),
                        forKey: cacheKey
                    )
                    let frame = DecodedFrame(
                        pixelBuffer: pixelBuffer,
                        metalTexture: try self.makeMetalTexture(for: pixelBuffer),
                        presentationTime: time
                    )
                    continuation.resume(returning: frame)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stillImageSourceExists(at sourceURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    private func loadStillPixelBuffer(from sourceURL: URL) throws -> CVPixelBuffer {
        let image = try Self.loadOrientedStillImage(from: sourceURL)
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw MediaDecodeError.unsupportedSource(sourceURL)
        }
        let pixelBuffer = try makeMetalCompatiblePixelBuffer(width: width, height: height)
        try drawStill(image, into: pixelBuffer, width: width, height: height)
        return pixelBuffer
    }

    /// Loads index 0 with EXIF orientation applied (thumbnail-with-transform at full size).
    private static func loadOrientedStillImage(from sourceURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw MediaDecodeError.unsupportedSource(sourceURL)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawWidth = integerValue(properties?[kCGImagePropertyPixelWidth]) ?? 0
        let rawHeight = integerValue(properties?[kCGImagePropertyPixelHeight]) ?? 0
        let maxPixel = max(rawWidth, rawHeight, 1)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw MediaDecodeError.unsupportedSource(sourceURL)
        }
        return image
    }

    private func makeMetalCompatiblePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = Int(pixelFormat)
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            throw MediaDecodeError.readerSetupFailed(
                "could not create still pixel buffer (\(createStatus))"
            )
        }
        return pixelBuffer
    }

    private func drawStill(
        _ image: CGImage,
        into pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw MediaDecodeError.readerSetupFailed(
                "could not lock still pixel buffer (\(lockStatus))"
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw MediaDecodeError.missingImageBuffer
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // Classified P3/sRGB/709/2020: pass through. Unclassified (Adobe RGB, CMYK, …) → sRGB.
        let drawColorSpace = Self.drawColorSpace(for: image)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: drawColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw MediaDecodeError.readerSetupFailed("could not create still draw context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Chooses the CG context color space for still decode (L4 / L6).
    ///
    /// - Classified working spaces: keep the image's native RGB space (pass-through).
    /// - Everything else (unknown ICC, CMYK, untagged): convert into sRGB by drawing.
    static func drawColorSpace(for image: CGImage) -> CGColorSpace {
        guard let sourceSpace = image.colorSpace else {
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        if Self.isClassifiedWorkingRGBColorSpace(sourceSpace) {
            return sourceSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Whether `space` is a classified P3 / sRGB / Rec.709 / Rec.2020 working RGB space.
    static func isClassifiedWorkingRGBColorSpace(_ space: CGColorSpace) -> Bool {
        guard let name = space.name as String? else {
            return false
        }
        let normalized = name.lowercased()
        if normalized.contains("displayp3") || normalized.contains("display p3") {
            return true
        }
        if normalized.contains("2020") || normalized.contains("2100") {
            return true
        }
        if normalized.contains("709") {
            return true
        }
        if normalized.contains("srgb") {
            return true
        }
        return false
    }

    /// Whether still decode should convert into sRGB (unit-testable classification decision).
    static func shouldConvertStillToSRGB(for image: CGImage) -> Bool {
        guard let sourceSpace = image.colorSpace else {
            return true
        }
        return !isClassifiedWorkingRGBColorSpace(sourceSpace)
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private func makeMetalTexture(for pixelBuffer: CVPixelBuffer) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            metalPixelFormat,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &texture
        )
        guard result == kCVReturnSuccess, let texture else {
            throw MediaDecodeError.metalTextureCreationFailed(result)
        }
        return texture
    }

    private static func requireAvailableSource(_ sourceURL: URL) throws {
        if sourceURL.isFileURL && !FileManager.default.isReadableFile(atPath: sourceURL.path) {
            throw MediaDecodeError.missingSource(sourceURL)
        }
    }
}

/// `NSCache` value box for `CVPixelBuffer` (class requirement).
final class CVPixelBufferBox: NSObject {
    let pixelBuffer: CVPixelBuffer

    init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}
