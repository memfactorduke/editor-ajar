// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreVideo
import Foundation

struct SyntheticMovieSpec: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let frameCount: Int
    let frameRate: Int32
    let bgra: [UInt8]
    let pixelsBGRA: [UInt8]?

    init(
        width: Int,
        height: Int,
        frameCount: Int,
        frameRate: Int32,
        bgra: [UInt8],
        pixelsBGRA: [UInt8]? = nil
    ) {
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.bgra = bgra
        self.pixelsBGRA = pixelsBGRA
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
        guard spec.width > 0, spec.height > 0, spec.frameCount > 0 else {
            throw SyntheticMovieWriterError.invalidSpec
        }
        if let pixelsBGRA = spec.pixelsBGRA {
            guard pixelsBGRA.count == spec.width * spec.height * 4 else {
                throw SyntheticMovieWriterError.invalidSpec
            }
        } else if spec.bgra.count != 4 {
            throw SyntheticMovieWriterError.invalidSpec
        }

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

        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.bindMemory(to: UInt8.self, capacity: rowBytes * spec.height)
        for yPosition in 0..<spec.height {
            for xPosition in 0..<spec.width {
                let offset = yPosition * rowBytes + xPosition * 4
                if let pixelsBGRA = spec.pixelsBGRA {
                    let source = offsetInTightBGRA(width: spec.width, x: xPosition, y: yPosition)
                    bytes[offset] = pixelsBGRA[source]
                    bytes[offset + 1] = pixelsBGRA[source + 1]
                    bytes[offset + 2] = pixelsBGRA[source + 2]
                    bytes[offset + 3] = pixelsBGRA[source + 3]
                } else {
                    bytes[offset] = spec.bgra[0]
                    bytes[offset + 1] = UInt8((Int(spec.bgra[1]) + frameIndex) % 256)
                    bytes[offset + 2] = spec.bgra[2]
                    bytes[offset + 3] = spec.bgra[3]
                }
            }
        }
    }

    private static func offsetInTightBGRA(width: Int, x: Int, y: Int) -> Int {
        ((y * width) + x) * 4
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
