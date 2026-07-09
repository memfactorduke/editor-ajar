// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreVideo
import Foundation

/// Compact deterministic checkerboard fill for golden-frame synthetic media (NFR-QUAL-001).
///
/// Optional on `SyntheticMovieSpec` so large canvases stay small in JSON while still carrying
/// high-frequency content where spatial kernels (blur/sharpen) are discriminable.
public struct SyntheticCheckerboardPattern: Codable, Equatable, Sendable {
    /// Checker cell size in pixels (must be ≥ 1).
    public let cellSize: Int

    /// BGRA color of cells where `((x/cell) + (y/cell))` is even.
    public let colorABGRA: [UInt8]

    /// BGRA color of cells where `((x/cell) + (y/cell))` is odd.
    public let colorBBGRA: [UInt8]

    private enum CodingKeys: String, CodingKey {
        case cellSize
        case colorABGRA
        case colorBBGRA
    }

    /// Creates a checkerboard pattern.
    public init(cellSize: Int, colorABGRA: [UInt8], colorBBGRA: [UInt8]) {
        self.cellSize = cellSize
        self.colorABGRA = colorABGRA
        self.colorBBGRA = colorBBGRA
    }

    /// Whether the pattern has valid cell size and 4-byte BGRA colors.
    public var isValid: Bool {
        cellSize >= 1 && colorABGRA.count == 4 && colorBBGRA.count == 4
    }
}

struct SyntheticMovieSpec: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let frameCount: Int
    let frameRate: Int32
    let bgra: [UInt8]
    let pixelsBGRA: [UInt8]?
    /// Optional compact checkerboard; used when `pixelsBGRA` is absent (additive schema).
    let checkerboard: SyntheticCheckerboardPattern?

    init(
        width: Int,
        height: Int,
        frameCount: Int,
        frameRate: Int32,
        bgra: [UInt8],
        pixelsBGRA: [UInt8]? = nil,
        checkerboard: SyntheticCheckerboardPattern? = nil
    ) {
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.bgra = bgra
        self.pixelsBGRA = pixelsBGRA
        self.checkerboard = checkerboard
    }

    /// Resolves tight-packed BGRA pixels for one frame (pixelsBGRA → checkerboard → solid).
    ///
    /// Pure and Metal-free so unit tests can validate pattern generation without AVFoundation.
    func resolvedBGRAPixels(frameIndex: Int = 0) throws -> [UInt8] {
        guard width > 0, height > 0, frameCount > 0 else {
            throw SyntheticMovieWriterError.invalidSpec
        }
        if let pixelsBGRA {
            guard pixelsBGRA.count == width * height * 4 else {
                throw SyntheticMovieWriterError.invalidSpec
            }
            return pixelsBGRA
        }
        if let checkerboard {
            guard checkerboard.isValid else {
                throw SyntheticMovieWriterError.invalidSpec
            }
            return Self.checkerboardPixels(
                width: width,
                height: height,
                pattern: checkerboard
            )
        }
        guard bgra.count == 4 else {
            throw SyntheticMovieWriterError.invalidSpec
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let offset = index * 4
            pixels[offset] = bgra[0]
            pixels[offset + 1] = UInt8((Int(bgra[1]) + frameIndex) % 256)
            pixels[offset + 2] = bgra[2]
            pixels[offset + 3] = bgra[3]
        }
        return pixels
    }

    static func checkerboardPixels(
        width: Int,
        height: Int,
        pattern: SyntheticCheckerboardPattern
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let cell = pattern.cellSize
        for yPosition in 0..<height {
            for xPosition in 0..<width {
                let cellX = xPosition / cell
                let cellY = yPosition / cell
                let useA = (cellX + cellY).isMultiple(of: 2)
                let color = useA ? pattern.colorABGRA : pattern.colorBBGRA
                let offset = ((yPosition * width) + xPosition) * 4
                pixels[offset] = color[0]
                pixels[offset + 1] = color[1]
                pixels[offset + 2] = color[2]
                pixels[offset + 3] = color[3]
            }
        }
        return pixels
    }
}

enum SyntheticMovieWriter {
    static func writeMovie(to url: URL, spec: SyntheticMovieSpec) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var outputSettings: [String: Any] = [:]
        outputSettings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        outputSettings[AVVideoWidthKey] = spec.width
        outputSettings[AVVideoHeightKey] = spec.height

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        var sourceAttributes: [String: Any] = [:]
        sourceAttributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        sourceAttributes[kCVPixelBufferWidthKey as String] = spec.width
        sourceAttributes[kCVPixelBufferHeightKey as String] = spec.height
        sourceAttributes[kCVPixelBufferMetalCompatibilityKey as String] = true
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
        try appendFrames(spec: spec, adaptor: adaptor, input: input, writer: writer)

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            throw SyntheticMovieWriterError.writerFailed(writer.errorDescription)
        }
    }

    private static func appendFrames(
        spec: SyntheticMovieSpec,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws {
        let writingQueue = DispatchQueue(label: "dev.editor-ajar.synthetic-movie-writer")
        let inputFinished = DispatchSemaphore(value: 0)
        var writeError: Error?
        var frameIndex = 0

        input.requestMediaDataWhenReady(on: writingQueue) {
            while input.isReadyForMoreMediaData, frameIndex < spec.frameCount {
                do {
                    let pixelBuffer = try makePixelBuffer(spec: spec, frameIndex: frameIndex)
                    let presentationTime = CMTime(
                        value: Int64(frameIndex),
                        timescale: spec.frameRate
                    )
                    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                        writeError = SyntheticMovieWriterError.writerFailed(writer.errorDescription)
                        input.markAsFinished()
                        inputFinished.signal()
                        return
                    }
                    frameIndex += 1
                } catch {
                    writeError = error
                    input.markAsFinished()
                    inputFinished.signal()
                    return
                }
            }

            if frameIndex == spec.frameCount {
                input.markAsFinished()
                inputFinished.signal()
            }
        }

        inputFinished.wait()
        if let writeError {
            writer.cancelWriting()
            throw writeError
        }
    }

    private static func makePixelBuffer(
        spec: SyntheticMovieSpec,
        frameIndex: Int
    ) throws -> CVPixelBuffer {
        // Validate fill sources before allocating the buffer.
        _ = try spec.resolvedBGRAPixels(frameIndex: frameIndex)

        var pixelBuffer: CVPixelBuffer?
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]

        let result = CVPixelBufferCreate(
            nil,
            spec.width,
            spec.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw SyntheticMovieWriterError.pixelBufferCreationFailed(result)
        }

        try fill(pixelBuffer: pixelBuffer, spec: spec, frameIndex: frameIndex)
        return pixelBuffer
    }

    private static func fill(
        pixelBuffer: CVPixelBuffer,
        spec: SyntheticMovieSpec,
        frameIndex: Int
    ) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw SyntheticMovieWriterError.missingBaseAddress
        }

        let tight = try spec.resolvedBGRAPixels(frameIndex: frameIndex)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.bindMemory(to: UInt8.self, capacity: rowBytes * spec.height)
        for yPosition in 0..<spec.height {
            for xPosition in 0..<spec.width {
                let dest = yPosition * rowBytes + xPosition * 4
                let source = ((yPosition * spec.width) + xPosition) * 4
                bytes[dest] = tight[source]
                bytes[dest + 1] = tight[source + 1]
                bytes[dest + 2] = tight[source + 2]
                bytes[dest + 3] = tight[source + 3]
            }
        }
    }
}

private enum SyntheticMovieWriterError: Error, CustomStringConvertible {
    case invalidSpec
    case cannotAddVideoInput
    case writerFailed(String)
    case pixelBufferCreationFailed(Int32)
    case missingBaseAddress

    var description: String {
        switch self {
        case .invalidSpec:
            "synthetic movie spec is invalid"
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
