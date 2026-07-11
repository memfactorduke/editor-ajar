// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreVideo
import Foundation
import Metal
import XCTest

@testable import AjarCore
@testable import AjarMedia

final class VideoFrameDecoderTests: XCTestCase {
    func testADR0003FRMED002DecodesSyntheticAssetIntoMetalBackedPixelBuffer() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let url = try temporaryMovieURL()
        try SyntheticMovieWriter.writeMovie(
            to: url,
            width: 16,
            height: 16,
            frameCount: 3,
            frameRate: 24
        )

        let decoder = try VideoFrameDecoder(device: device)
        let frame = try await decoder.decodeFrame(
            from: url,
            at: try RationalTime(value: 0, timescale: 24)
        )

        XCTAssertEqual(frame.pixelDimensions, PixelDimensions(width: 16, height: 16))
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(frame.presentationTime, try RationalTime(value: 0, timescale: 1))
        XCTAssertTrue(frame.hasMetalTexture)
    }

    func testNFRSTAB006MissingSourceReturnsTypedDecodeError() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let decoder = try VideoFrameDecoder(device: device)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        do {
            _ = try await decoder.decodeFrame(
                from: url,
                at: try RationalTime(value: 0, timescale: 24)
            )
            XCTFail("Expected missing source error")
        } catch {
            XCTAssertEqual(error as? MediaDecodeError, .missingSource(url))
        }
    }

    func testNFRSTAB006MalformedSourceReturnsTypedDecodeErrorWithoutCrashing() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try Data("not a movie".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let decoder = try VideoFrameDecoder(device: device)

        do {
            _ = try await decoder.decodeFrame(
                from: url,
                at: try RationalTime(value: 0, timescale: 24)
            )
            XCTFail("Expected malformed source error")
        } catch {
            XCTAssertEqual(error as? MediaDecodeError, .unsupportedSource(url))
        }
    }

    private func temporaryMovieURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-media-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("synthetic.mov")
    }
}

enum SyntheticMovieWriter {
    static func writeMovie(
        to url: URL,
        width: Int,
        height: Int,
        frameCount: Int,
        frameRate: Int32
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var outputSettings: [String: Any] = [:]
        outputSettings[AVVideoCodecKey] = AVVideoCodecType.h264
        outputSettings[AVVideoWidthKey] = width
        outputSettings[AVVideoHeightKey] = height

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        input.expectsMediaDataInRealTime = false

        var sourceAttributes: [String: Any] = [:]
        sourceAttributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        sourceAttributes[kCVPixelBufferWidthKey as String] = width
        sourceAttributes[kCVPixelBufferHeightKey as String] = height
        sourceAttributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else {
            throw SyntheticMovieWriterError.cannotAddVideoInput
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw SyntheticMovieWriterError.writerFailed(writer.errorDescription)
        }

        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frameCount {
            let pixelBuffer = try makePixelBuffer(
                width: width,
                height: height,
                frameIndex: frameIndex
            )
            let presentationTime = CMTime(value: Int64(frameIndex), timescale: frameRate)

            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw SyntheticMovieWriterError.writerFailed(writer.errorDescription)
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            throw SyntheticMovieWriterError.writerFailed(writer.errorDescription)
        }
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]

        let result = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw SyntheticMovieWriterError.pixelBufferCreationFailed(result)
        }

        try fill(pixelBuffer: pixelBuffer, frameIndex: frameIndex)
        return pixelBuffer
    }

    private static func fill(pixelBuffer: CVPixelBuffer, frameIndex: Int) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw SyntheticMovieWriterError.missingBaseAddress
        }

        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let bytes = baseAddress.bindMemory(to: UInt8.self, capacity: rowBytes * height)

        for yPosition in 0..<height {
            for xPosition in 0..<width {
                let offset = yPosition * rowBytes + xPosition * 4
                bytes[offset] = UInt8((xPosition + frameIndex) % 256)
                bytes[offset + 1] = UInt8((yPosition + frameIndex) % 256)
                bytes[offset + 2] = UInt8((xPosition + yPosition + frameIndex) % 256)
                bytes[offset + 3] = 255
            }
        }
    }
}

private enum SyntheticMovieWriterError: Error, CustomStringConvertible {
    case cannotAddVideoInput
    case writerFailed(String)
    case pixelBufferCreationFailed(Int32)
    case missingBaseAddress

    var description: String {
        switch self {
        case .cannotAddVideoInput:
            "AVAssetWriter cannot add synthetic video input"
        case .writerFailed(let message):
            "synthetic movie writer failed: \(message)"
        case .pixelBufferCreationFailed(let code):
            "synthetic pixel buffer creation failed with code \(code)"
        case .missingBaseAddress:
            "synthetic pixel buffer has no base address"
        }
    }
}

private extension AVAssetWriter {
    var errorDescription: String {
        error.map(String.init(describing:)) ?? "unknown writer error"
    }
}
