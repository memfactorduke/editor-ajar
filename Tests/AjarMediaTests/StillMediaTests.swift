// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import XCTest

@testable import AjarMedia

final class StillMediaTests: XCTestCase {
    func testFRMED002ProbeStillUsesUnboundedSourceExtent() async throws {
        let fixtureURL = repoStillFixtureURL()
        let result = try await AVFoundationMediaProbe().probe(fixtureURL)
        XCTAssertEqual(result.metadata.codecID, "png")
        XCTAssertEqual(result.metadata.duration, try StillMediaDefaults.sourceExtentDuration())
        XCTAssertNil(result.metadata.frameRate)
        XCTAssertNil(result.metadata.audioChannelLayout)
        XCTAssertGreaterThan(result.metadata.pixelDimensions?.width ?? 0, 0)
        XCTAssertGreaterThan(result.metadata.pixelDimensions?.height ?? 0, 0)
    }

    func testFRMED002ImportStillAcceptsNativeImageIOPath() async throws {
        let fixtureURL = repoStillFixtureURL()
        let pipeline = MediaImportPipeline(
            probe: AVFoundationMediaProbe(),
            hasher: SHA256MediaFileHasher(),
            bookmarkStore: StillTestBookmarkStore()
        )
        let batch = await pipeline.prepareImport(from: [fixtureURL], existingMedia: [])
        let item = try XCTUnwrap(batch.summary.imported.first)
        XCTAssertEqual(item.mediaReference.metadata.codecID, "png")
        XCTAssertEqual(
            item.mediaReference.metadata.duration,
            try StillMediaDefaults.sourceExtentDuration()
        )
        XCTAssertTrue(batch.summary.failed.isEmpty)
        XCTAssertTrue(batch.summary.transcoded.isEmpty)
    }

    func testFRMED002DecodeStillToMetalTextureAndCache() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
        let fixtureURL = repoStillFixtureURL()
        let decoder = try VideoFrameDecoder(device: device)
        let t0 = try RationalTime(value: 0, timescale: 24)
        let t1 = try RationalTime(value: 48, timescale: 24)
        let first = try await decoder.decodeFrame(from: fixtureURL, at: t0)
        let second = try await decoder.decodeFrame(from: fixtureURL, at: t1)
        XCTAssertTrue(first.hasMetalTexture)
        XCTAssertTrue(second.hasMetalTexture)
        XCTAssertEqual(first.pixelFormat, kCVPixelFormatType_32BGRA)
        // Same underlying still buffer is reused (time-invariant cache).
        XCTAssertTrue(first.pixelBuffer === second.pixelBuffer)
        XCTAssertEqual(first.presentationTime, t0)
        XCTAssertEqual(second.presentationTime, t1)
    }

    func testFRMED002DecodeStillViaMediaRefCodec() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }
        let fixtureURL = repoStillFixtureURL()
        let media = MediaRef(
            id: UUID(),
            sourceURL: fixtureURL,
            contentHash: try SHA256MediaFileHasher().contentHash(of: fixtureURL),
            metadata: MediaMetadata(
                codecID: "png",
                pixelDimensions: PixelDimensions(width: 16, height: 16),
                frameRate: nil,
                duration: try StillMediaDefaults.sourceExtentDuration(),
                colorSpace: .sRGB,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let decoder = try VideoFrameDecoder(device: device)
        let frame = try await decoder.decodeFrame(
            from: media,
            at: try RationalTime(value: 1, timescale: 1)
        )
        XCTAssertTrue(frame.hasMetalTexture)
        XCTAssertEqual(frame.pixelDimensions.width, 16)
        XCTAssertEqual(frame.pixelDimensions.height, 16)
    }

    func testFRMED002ProbeExifOrientationSwapsDimensions() async throws {
        let root = try temporaryDirectory(named: "exif-probe")
        defer { try? FileManager.default.removeItem(at: root) }
        // Stored pixels 4×2; orientation 6 (90° CW) → display 2×4.
        let url = root.appendingPathComponent("portrait.jpg")
        try writeJPEG(
            to: url,
            width: 4,
            height: 2,
            orientation: 6
        )
        let result = try await AVFoundationMediaProbe().probe(url)
        XCTAssertEqual(result.metadata.codecID, "jpeg")
        XCTAssertEqual(result.metadata.pixelDimensions?.width, 2)
        XCTAssertEqual(result.metadata.pixelDimensions?.height, 4)
    }

    func testFRMED002DecodeExifOrientationAppliesTransform() async throws {
        let root = try temporaryDirectory(named: "exif-decode")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("portrait.jpg")
        try writeJPEG(to: url, width: 4, height: 2, orientation: 6)

        // ImageIO path used by StillImageFrameDecoder (no Metal required for the transform check).
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4
        ]
        let image = try XCTUnwrap(
            CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        )
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 4)

        guard let device = MTLCreateSystemDefaultDevice() else {
            return // transform path verified above when Metal is unavailable
        }
        let decoder = try VideoFrameDecoder(device: device)
        let frame = try await decoder.decodeFrame(
            from: url,
            at: try RationalTime(value: 0, timescale: 1)
        )
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 2)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), 4)
    }

    func testFRMED002UnclassifiedColorSpaceConvertsToSRGBDecision() throws {
        // Untagged DeviceRGB is not a classified working space → convert path.
        let untagged = try solidPixelImage(colorSpace: CGColorSpaceCreateDeviceRGB())
        XCTAssertTrue(StillImageFrameDecoder.shouldConvertStillToSRGB(for: untagged))

        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let taggedSRGB = try solidPixelImage(colorSpace: sRGB)
        XCTAssertFalse(StillImageFrameDecoder.shouldConvertStillToSRGB(for: taggedSRGB))

        if let p3 = CGColorSpace(name: CGColorSpace.displayP3) {
            let taggedP3 = try solidPixelImage(colorSpace: p3)
            XCTAssertFalse(StillImageFrameDecoder.shouldConvertStillToSRGB(for: taggedP3))
        }
    }

    func testFRMED002CMYKStillDecodesViaSRGBConversion() async throws {
        let root = try temporaryDirectory(named: "cmyk-decode")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cmyk.tif")
        try writeCMYKTIFF(to: url, width: 2, height: 2)

        // Probe accepts CMYK TIFF; classification forces sRGB conversion (not pass-through).
        let probe = try await AVFoundationMediaProbe().probe(url)
        XCTAssertEqual(probe.metadata.codecID, "tiff")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue(StillImageFrameDecoder.shouldConvertStillToSRGB(for: image))
        // Drawing CMYK into an sRGB context must succeed (L4/L6 normalize path).
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: 2 * 2 * 4)
        let context = try XCTUnwrap(
            pixels.withUnsafeMutableBytes { raw -> CGContext? in
                CGContext(
                    data: raw.baseAddress,
                    width: 2,
                    height: 2,
                    bitsPerComponent: 8,
                    bytesPerRow: 8,
                    space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
            }
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertTrue(pixels.contains(where: { $0 != 0 }), "CMYK→sRGB draw produced empty buffer")

        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }
        let decoder = try VideoFrameDecoder(device: device)
        let frame = try await decoder.decodeFrame(
            from: url,
            at: try RationalTime(value: 0, timescale: 1)
        )
        XCTAssertTrue(frame.hasMetalTexture)
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 2)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), 2)
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_32BGRA)
    }

    private func repoStillFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden/single-clip-blue/reference.png")
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-still-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func solidPixelImage(colorSpace: CGColorSpace) throws -> CGImage {
        let pixelData = Data([0, 0, 0, 255]) as CFData
        guard let provider = CGDataProvider(data: pixelData),
              let image = CGImage(
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            throw NSError(domain: "StillMediaTests", code: 10)
        }
        return image
    }

    /// Writes a tiny JPEG with an EXIF orientation tag via ImageIO.
    private func writeJPEG(to url: URL, width: Int, height: Int, orientation: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                pixels[offset] = UInt8(column * 40)
                pixels[offset + 1] = UInt8(row * 80)
                pixels[offset + 2] = 200
                pixels[offset + 3] = 255
            }
        }
        let pixelData = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: pixelData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  "public.jpeg" as CFString,
                  1,
                  nil
              )
        else {
            throw NSError(domain: "StillMediaTests", code: 1)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "StillMediaTests", code: 2)
        }
    }

    /// Writes a small CMYK TIFF so decode must convert out of CMYK into RGB/sRGB.
    private func writeCMYKTIFF(to url: URL, width: Int, height: Int) throws {
        guard let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK) else {
            throw NSError(domain: "StillMediaTests", code: 3)
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 0 // C
            pixels[offset + 1] = 255 // M
            pixels[offset + 2] = 255 // Y
            pixels[offset + 3] = 0 // K → vivid red-ish in CMYK
        }
        let pixelData = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: pixelData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: cmyk,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  "public.tiff" as CFString,
                  1,
                  nil
              )
        else {
            throw NSError(domain: "StillMediaTests", code: 4)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "StillMediaTests", code: 5)
        }
    }
}

private struct StillTestBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid still test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}
