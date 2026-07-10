// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Still-image container for single-frame export (FR-EXP-004).
public enum StillImageFormat: String, Codable, CaseIterable, Equatable, Sendable {
    /// Lossless PNG (bit-exact vs delivery conversion for 8-bit BGRA).
    case png

    /// Baseline JPEG.
    case jpeg
}

/// Immutable inputs for one still-frame export.
public struct StillFrameExportRequest: Sendable {
    /// Project snapshot used for the graph pull.
    public let project: Project

    /// Sequence to sample.
    public let sequenceID: UUID

    /// Exact timeline time of the still (half-open timeline; must lie in `[0, duration)`).
    public let time: RationalTime

    /// Destination file URL published only after a successful encode.
    public let destinationURL: URL

    /// Output raster (project canvas is scaled by the same vImage path as movie export).
    public let resolution: PixelDimensions

    /// Delivery color space; must match the project graph output.
    public let colorSpace: ExportColorSpace

    /// PNG or JPEG.
    public let format: StillImageFormat

    /// JPEG quality in `0...1`; ignored for PNG.
    public let jpegQuality: Double

    /// Creates and validates a still-frame request.
    public init(
        project: Project,
        sequenceID: UUID,
        time: RationalTime,
        destinationURL: URL,
        resolution: PixelDimensions? = nil,
        colorSpace: ExportColorSpace? = nil,
        format: StillImageFormat,
        jpegQuality: Double = 0.92
    ) throws {
        guard let sequence = project.sequences.first(where: { $0.id == sequenceID }) else {
            throw ExportError.sequenceNotFound(sequenceID)
        }
        let timelineDuration: RationalTime
        do {
            timelineDuration = try sequence.timelineDuration()
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
        guard time >= .zero, time < timelineDuration else {
            throw ExportError.stillFrameTimeOutOfRange(time)
        }

        let resolvedColorSpace = colorSpace ?? ExportColorSpace.from(project.settings.colorSpace)
        guard project.settings.colorSpace == resolvedColorSpace.mediaColorSpace else {
            throw ExportError.colorSpaceMismatch(
                project: project.settings.colorSpace,
                export: resolvedColorSpace
            )
        }
        guard destinationURL.isFileURL else {
            throw ExportError.destinationMustBeFileURL(destinationURL)
        }
        guard jpegQuality.isFinite, (0...1).contains(jpegQuality) else {
            throw ExportError.stillFrameWriteFailed(
                "JPEG quality \(jpegQuality) is outside 0...1"
            )
        }

        let resolvedResolution = resolution ?? project.settings.resolution
        do {
            // Reuse ExportVideoSettings validation for raster bounds / even dimensions.
            _ = try ExportVideoSettings(
                codec: .h264,
                resolution: resolvedResolution,
                frameRate: sequence.timebase,
                averageBitRate: 1_000_000,
                colorSpace: resolvedColorSpace
            )
        } catch let error as ExportSettingsValidationError {
            throw ExportError.invalidSettings(error)
        }

        self.project = project
        self.sequenceID = sequenceID
        self.time = time
        self.destinationURL = destinationURL
        self.resolution = resolvedResolution
        self.colorSpace = resolvedColorSpace
        self.format = format
        self.jpegQuality = jpegQuality
    }
}

/// Single-frame still export through the ADR-0019 delivery conversion path (FR-EXP-004).
public enum StillFrameExporter {
    /// Renders one presented frame, converts with vImage, and writes PNG or JPEG atomically.
    public static func export(
        request: StillFrameExportRequest,
        sourceProvider: any ExportRenderSourceProvider,
        device: MTLDevice? = nil
    ) async throws {
        guard let sequence = request.project.sequences.first(where: { $0.id == request.sequenceID })
        else {
            throw ExportError.sequenceNotFound(request.sequenceID)
        }

        let videoSettings: ExportVideoSettings
        do {
            videoSettings = try ExportVideoSettings(
                codec: .h264,
                resolution: request.resolution,
                frameRate: sequence.timebase,
                averageBitRate: 1_000_000,
                colorSpace: request.colorSpace
            )
        } catch let error as ExportSettingsValidationError {
            throw ExportError.invalidSettings(error)
        }

        let frameProvider: RenderGraphExportFrameProvider
        if let device {
            frameProvider = try RenderGraphExportFrameProvider(
                project: request.project,
                sequence: sequence,
                videoSettings: videoSettings,
                sourceProvider: sourceProvider,
                device: device
            )
        } else {
            frameProvider = try RenderGraphExportFrameProvider(
                project: request.project,
                sequence: sequence,
                videoSettings: videoSettings,
                sourceProvider: sourceProvider
            )
        }

        let pixelBuffer = try makeBGRAPixelBuffer(
            width: request.resolution.width,
            height: request.resolution.height
        )
        try await frameProvider.renderFrame(at: request.time, into: pixelBuffer)

        let transaction = try ExportOutputTransaction(destinationURL: request.destinationURL)
        do {
            try StillFrameImageWriter.write(
                pixelBuffer: pixelBuffer,
                format: request.format,
                jpegQuality: request.jpegQuality,
                colorSpace: request.colorSpace,
                to: transaction.temporaryURL
            )
            try transaction.commit()
        } catch {
            try? transaction.cleanUp()
            if let exportError = error as? ExportError {
                throw exportError
            }
            throw ExportError.stillFrameWriteFailed(String(describing: error))
        }
    }

    /// Decodes a still PNG/JPEG into tightly packed BGRA8 using the delivery color space.
    ///
    /// Used by FR-EXP-007 still golden: bit-exact compare against ``renderDeliveryBGRA``.
    ///
    /// **Bit-exact contract:** holds only for **fully-opaque** delivery buffers. Decode draws
    /// through a premultiplied-alpha CGContext (`premultipliedFirst` + little-endian → BGRA),
    /// while the export expectation is a raw packed copy of the delivery pixel buffer. Partial
    /// coverage / non-opaque alpha can diverge between those paths even when the PNG is lossless.
    public static func decodeStillBGRA8(
        from url: URL,
        colorSpace: ExportColorSpace
    ) throws -> ExportDecodedBGRAFrame {
        let decoded = try StillFrameImageWriter.decodeBGRA8(from: url, colorSpace: colorSpace)
        return ExportDecodedBGRAFrame(
            width: decoded.width,
            height: decoded.height,
            bgra8: decoded.bytes
        )
    }

    /// Renders one frame into a 32BGRA pixel buffer without writing a file (tests / diagnostics).
    public static func renderDeliveryBGRA(
        request: StillFrameExportRequest,
        sourceProvider: any ExportRenderSourceProvider,
        device: MTLDevice? = nil
    ) async throws -> CVPixelBuffer {
        guard let sequence = request.project.sequences.first(where: { $0.id == request.sequenceID })
        else {
            throw ExportError.sequenceNotFound(request.sequenceID)
        }
        let videoSettings = try ExportVideoSettings(
            codec: .h264,
            resolution: request.resolution,
            frameRate: sequence.timebase,
            averageBitRate: 1_000_000,
            colorSpace: request.colorSpace
        )
        let frameProvider: RenderGraphExportFrameProvider
        if let device {
            frameProvider = try RenderGraphExportFrameProvider(
                project: request.project,
                sequence: sequence,
                videoSettings: videoSettings,
                sourceProvider: sourceProvider,
                device: device
            )
        } else {
            frameProvider = try RenderGraphExportFrameProvider(
                project: request.project,
                sequence: sequence,
                videoSettings: videoSettings,
                sourceProvider: sourceProvider
            )
        }
        let pixelBuffer = try makeBGRAPixelBuffer(
            width: request.resolution.width,
            height: request.resolution.height
        )
        try await frameProvider.renderFrame(at: request.time, into: pixelBuffer)
        return pixelBuffer
    }

    private static func makeBGRAPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ExportError.pixelBufferCreationFailed(status)
        }
        return buffer
    }
}

enum StillFrameImageWriter {
    static func write(
        pixelBuffer: CVPixelBuffer,
        format: StillImageFormat,
        jpegQuality: Double,
        colorSpace: ExportColorSpace,
        to url: URL
    ) throws {
        let cgImage = try makeCGImage(from: pixelBuffer, colorSpace: colorSpace)
        let type = utType(for: format)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type as CFString,
            1,
            nil
        ) else {
            throw ExportError.stillFrameWriteFailed("could not create image destination")
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.stillFrameWriteFailed("image destination finalize failed")
        }
    }

    /// Decoded tightly packed BGRA8 still for bit-exact comparisons.
    struct DecodedBGRA8: Equatable, Sendable {
        let width: Int
        let height: Int
        let bytes: Data
    }

    /// Decodes a still file back into tightly packed BGRA8 for bit-exact comparisons.
    ///
    /// `colorSpace` must match the delivery space used when the still was written (ADR-0019
    /// color-tag rule) so Core Graphics does not convert through DeviceRGB / sRGB.
    ///
    /// **Bit-exact contract:** holds only for fully-opaque delivery buffers. This path draws
    /// through a premultiplied-alpha CGContext; the export expectation is a raw packed copy of
    /// the delivery buffer. Non-opaque coverage can diverge even when the PNG container is lossless.
    static func decodeBGRA8(
        from url: URL,
        colorSpace: ExportColorSpace
    ) throws -> DecodedBGRA8 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ExportError.stillFrameWriteFailed("could not decode still image")
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let cgColorSpace = try ExportColorTagging.cgColorSpace(for: colorSpace)
        var data = Data(count: bytesPerRow * height)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw ExportError.stillFrameWriteFailed("decode buffer was empty")
            }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cgColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                throw ExportError.stillFrameWriteFailed("could not create decode context")
            }
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
        }
        return DecodedBGRA8(width: width, height: height, bytes: data)
    }

    /// Copies tightly packed BGRA8 from a 32BGRA pixel buffer (row-by-row; ignores padding).
    static func packedBGRA8(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw ExportError.stillFrameWriteFailed("could not lock still pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ExportError.stillFrameWriteFailed("still pixel buffer has no base address")
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstRowBytes = width * 4
        var data = Data(count: dstRowBytes * height)
        data.withUnsafeMutableBytes { raw in
            guard let dstBase = raw.baseAddress else {
                return
            }
            for row in 0..<height {
                let src = base.advanced(by: row * srcRowBytes)
                let dst = dstBase.advanced(by: row * dstRowBytes)
                memcpy(dst, src, dstRowBytes)
            }
        }
        return data
    }

    /// Creates a CGImage tagged with the export delivery color space (ADR-0019).
    private static func makeCGImage(
        from pixelBuffer: CVPixelBuffer,
        colorSpace: ExportColorSpace
    ) throws -> CGImage {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw ExportError.stillFrameWriteFailed("could not lock still pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ExportError.stillFrameWriteFailed("still pixel buffer has no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // ADR-0019: tag stills with the delivery space, not a hardcoded sRGB label.
        let cgColorSpace = try ExportColorTagging.cgColorSpace(for: colorSpace)
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cgColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ), let image = context.makeImage() else {
            throw ExportError.stillFrameWriteFailed("could not create CGImage from BGRA buffer")
        }
        return image
    }

    private static func utType(for format: StillImageFormat) -> String {
        switch format {
        case .png:
            UTType.png.identifier
        case .jpeg:
            UTType.jpeg.identifier
        }
    }
}

extension ExportColorSpace {
    /// Best-effort map from project delivery space onto export tags.
    static func from(_ media: MediaColorSpace) -> ExportColorSpace {
        switch media {
        case .displayP3:
            .displayP3
        case .rec709, .sRGB, .rec2020, .unspecified, .unknown:
            .rec709
        }
    }
}
