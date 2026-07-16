// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Internal streaming writer seam used to inject a deterministic GIF writer in session tests.
protocol AnimatedGIFWriting: AnyObject {
    func append(
        pixelBuffer: CVPixelBuffer,
        sourceColorSpace: ExportColorSpace,
        colorConversionPolicy: AnimatedGIFColorConversionPolicy,
        delayCentiseconds: Int
    ) throws
    func finalize() throws
}

/// Creates a streaming GIF writer at `url` for exactly `expectedFrameCount` frames.
typealias AnimatedGIFWriterFactory = (
    _ url: URL,
    _ expectedFrameCount: Int,
    _ loopPolicy: AnimatedGIFLoopPolicy
) throws -> any AnimatedGIFWriting

/// Typed low-level ImageIO GIF writer failures. The export session maps these to its public error.
enum AnimatedGIFWriterError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidExpectedFrameCount(Int)
    case destinationCreationFailed(URL)
    case invalidDelayCentiseconds(Int)
    case frameCountExceeded(expected: Int, attempted: Int)
    case pixelConversionFailed(String)
    case frameCountMismatch(expected: Int, appended: Int)
    case finalizationFailed
    case alreadyFinalized

    var description: String {
        switch self {
        case .invalidExpectedFrameCount(let count):
            "animated GIF frame count must be positive (got \(count))"
        case .destinationCreationFailed(let url):
            "could not create animated GIF destination at \(url.path)"
        case .invalidDelayCentiseconds(let delay):
            "animated GIF delay must be in 1...65535 centiseconds (got \(delay))"
        case .frameCountExceeded(let expected, let attempted):
            "animated GIF expected \(expected) frames but frame \(attempted) was appended"
        case .pixelConversionFailed(let reason):
            "animated GIF sRGB pixel conversion failed: \(reason)"
        case .frameCountMismatch(let expected, let appended):
            "animated GIF expected \(expected) frames but received \(appended)"
        case .finalizationFailed:
            "animated GIF destination finalization failed"
        case .alreadyFinalized:
            "animated GIF writer was already finalized"
        }
    }
}

/// ImageIO-backed animated GIF writer with exact frame-count and timing validation.
final class ImageIOAnimatedGIFWriter: AnimatedGIFWriting {
    private let destination: CGImageDestination
    private let expectedFrameCount: Int
    private var appendedFrameCount = 0
    private var isFinalized = false

    init(
        url: URL,
        expectedFrameCount: Int,
        loopPolicy: AnimatedGIFLoopPolicy
    ) throws {
        guard expectedFrameCount > 0 else {
            throw AnimatedGIFWriterError.invalidExpectedFrameCount(expectedFrameCount)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            expectedFrameCount,
            nil
        ) else {
            throw AnimatedGIFWriterError.destinationCreationFailed(url)
        }
        self.destination = destination
        self.expectedFrameCount = expectedFrameCount

        if loopPolicy == .forever {
            CGImageDestinationSetProperties(
                destination,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFLoopCount: 0
                    ]
                ] as CFDictionary
            )
        }
    }

    func append(
        pixelBuffer: CVPixelBuffer,
        sourceColorSpace: ExportColorSpace,
        colorConversionPolicy: AnimatedGIFColorConversionPolicy,
        delayCentiseconds: Int
    ) throws {
        guard !isFinalized else {
            throw AnimatedGIFWriterError.alreadyFinalized
        }
        guard (1...65_535).contains(delayCentiseconds) else {
            throw AnimatedGIFWriterError.invalidDelayCentiseconds(delayCentiseconds)
        }
        let attemptedFrameCount = appendedFrameCount + 1
        guard attemptedFrameCount <= expectedFrameCount else {
            throw AnimatedGIFWriterError.frameCountExceeded(
                expected: expectedFrameCount,
                attempted: attemptedFrameCount
            )
        }

        let image: CGImage
        do {
            image = try BGRAImageBridge.makeOwnedSRGBCGImage(
                from: pixelBuffer,
                sourceColorSpace: sourceColorSpace,
                colorConversionPolicy: colorConversionPolicy
            )
        } catch {
            throw AnimatedGIFWriterError.pixelConversionFailed(String(describing: error))
        }
        let delaySeconds = Double(delayCentiseconds) / 100
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delaySeconds,
                    kCGImagePropertyGIFUnclampedDelayTime: delaySeconds
                ]
            ] as CFDictionary
        )
        appendedFrameCount = attemptedFrameCount
    }

    func finalize() throws {
        guard !isFinalized else {
            throw AnimatedGIFWriterError.alreadyFinalized
        }
        guard appendedFrameCount == expectedFrameCount else {
            throw AnimatedGIFWriterError.frameCountMismatch(
                expected: expectedFrameCount,
                appended: appendedFrameCount
            )
        }
        guard CGImageDestinationFinalize(destination) else {
            throw AnimatedGIFWriterError.finalizationFailed
        }
        isFinalized = true
    }
}
