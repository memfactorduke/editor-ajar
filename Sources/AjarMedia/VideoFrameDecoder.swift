// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarCore
import CoreVideo
import Foundation
import Metal
import VideoToolbox
// swiftlint:enable sorted_imports

/// Errors produced by native video frame decoding.
public enum MediaDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A default Metal device could not be created for zero-copy texture interop.
    case metalDeviceUnavailable

    /// A media reference has no usable source URL.
    case missingSourceURL(mediaID: UUID)

    /// The source file is missing or not readable.
    case missingSource(URL)

    /// The source does not expose a video track AVFoundation can read.
    case unsupportedSource(URL)

    /// Exact timeline time could not be represented as `CMTime`.
    case invalidTime(RationalTime)

    /// AVAssetReader could not be configured.
    case readerSetupFailed(String)

    /// AVAssetReader failed after decoding began.
    case readerFailed(String)

    /// No frame was available at the requested time.
    case frameUnavailable(RationalTime)

    /// The decoded sample did not contain a pixel buffer.
    case missingImageBuffer

    /// CVMetalTextureCache could not be created.
    case metalTextureCacheCreationFailed(Int32)

    /// CVMetalTextureCache could not wrap the decoded pixel buffer.
    case metalTextureCreationFailed(Int32)

    /// CMSampleBuffer carried an invalid presentation timestamp.
    case invalidPresentationTime

    /// A human-readable description of the decode failure.
    public var description: String {
        switch self {
        case .metalDeviceUnavailable:
            "Metal device unavailable for zero-copy decode interop"
        case .missingSourceURL(let mediaID):
            "media \(mediaID) does not have a source URL"
        case .missingSource(let url):
            "media source is missing or unreadable: \(url.path)"
        case .unsupportedSource(let url):
            "media source has no supported video track: \(url.path)"
        case .invalidTime(let time):
            "decode time cannot be represented as CMTime: \(time)"
        case .readerSetupFailed(let message):
            "AVAssetReader setup failed: \(message)"
        case .readerFailed(let message):
            "AVAssetReader failed: \(message)"
        case .frameUnavailable(let time):
            "no decoded frame was available at \(time)"
        case .missingImageBuffer:
            "decoded sample did not contain a pixel buffer"
        case .metalTextureCacheCreationFailed(let code):
            "CVMetalTextureCache creation failed with code \(code)"
        case .metalTextureCreationFailed(let code):
            "CVMetalTexture creation failed with code \(code)"
        case .invalidPresentationTime:
            "decoded sample had an invalid presentation timestamp"
        }
    }
}

/// One decoded native video frame and its zero-copy Metal texture wrapper.
public struct DecodedFrame {
    /// Decoded IOSurface-backed pixel buffer from AVFoundation.
    public let pixelBuffer: CVPixelBuffer

    /// Zero-copy texture wrapper for `pixelBuffer`.
    public let metalTexture: CVMetalTexture

    /// Presentation time in source media coordinates.
    public let presentationTime: RationalTime

    /// Creates a decoded frame value.
    public init(
        pixelBuffer: CVPixelBuffer,
        metalTexture: CVMetalTexture,
        presentationTime: RationalTime
    ) {
        self.pixelBuffer = pixelBuffer
        self.metalTexture = metalTexture
        self.presentationTime = presentationTime
    }

    /// Decoded frame dimensions.
    public var pixelDimensions: PixelDimensions {
        PixelDimensions(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }

    /// Core Video pixel format.
    public var pixelFormat: OSType {
        CVPixelBufferGetPixelFormatType(pixelBuffer)
    }

    /// Whether the Metal texture cache produced a texture object for this pixel buffer.
    public var hasMetalTexture: Bool {
        CVMetalTextureGetTexture(metalTexture) != nil
    }
}

/// Native AVFoundation/VideoToolbox frame decoder for one source frame.
public final class VideoFrameDecoder {
    private let device: MTLDevice
    private let pixelFormat: OSType
    private let metalPixelFormat: MTLPixelFormat
    private let textureCache: CVMetalTextureCache

    /// Creates a decoder with the default Metal device.
    public convenience init(
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        metalPixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MediaDecodeError.metalDeviceUnavailable
        }

        try self.init(
            device: device,
            pixelFormat: pixelFormat,
            metalPixelFormat: metalPixelFormat
        )
    }

    /// Creates a decoder with an explicit Metal device.
    public init(
        device: MTLDevice,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        metalPixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        self.metalPixelFormat = metalPixelFormat

        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let cache else {
            throw MediaDecodeError.metalTextureCacheCreationFailed(result)
        }

        textureCache = cache
    }

    /// Decodes a frame from a media reference's source URL.
    public func decodeFrame(
        from media: MediaRef,
        at time: RationalTime
    ) async throws -> DecodedFrame {
        guard let sourceURL = media.sourceURL else {
            throw MediaDecodeError.missingSourceURL(mediaID: media.id)
        }

        return try await decodeFrame(from: sourceURL, at: time)
    }

    /// Decodes a frame from `sourceURL` at `time`.
    ///
    /// The AVAssetReader output requests Metal-compatible IOSurface-backed pixel buffers and sets
    /// `alwaysCopiesSampleData = false`. The decode path does not call
    /// base-address pixel buffer accessors; frame bytes stay in the pixel buffer for the Metal
    /// texture cache to wrap without CPU readback.
    public func decodeFrame(
        from sourceURL: URL,
        at time: RationalTime
    ) async throws -> DecodedFrame {
        if sourceURL.isFileURL && !FileManager.default.isReadableFile(atPath: sourceURL.path) {
            throw MediaDecodeError.missingSource(sourceURL)
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw MediaDecodeError.unsupportedSource(sourceURL)
        }

        guard let track = tracks.first else {
            throw MediaDecodeError.unsupportedSource(sourceURL)
        }

        let reader = try makeReader(asset: asset)
        let output = makeOutput(for: track)
        guard reader.canAdd(output) else {
            throw MediaDecodeError.readerSetupFailed("asset reader cannot add video output")
        }

        reader.add(output)
        reader.timeRange = CMTimeRange(start: try cmTime(from: time), duration: .positiveInfinity)

        guard reader.startReading() else {
            throw MediaDecodeError.readerSetupFailed(reader.errorDescription)
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw MediaDecodeError.readerFailed(reader.errorDescription)
            }
            throw MediaDecodeError.frameUnavailable(time)
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw MediaDecodeError.missingImageBuffer
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = DecodedFrame(
            pixelBuffer: pixelBuffer,
            metalTexture: try makeMetalTexture(for: pixelBuffer),
            presentationTime: try rationalTime(from: presentationTime)
        )

        return frame
    }

    private func makeReader(asset: AVAsset) throws -> AVAssetReader {
        do {
            return try AVAssetReader(asset: asset)
        } catch {
            throw MediaDecodeError.readerSetupFailed(String(describing: error))
        }
    }

    private func makeOutput(for track: AVAssetTrack) -> AVAssetReaderTrackOutput {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        return output
    }

    private var outputSettings: [String: Any] {
        var settings: [String: Any] = [:]
        settings[kCVPixelBufferPixelFormatTypeKey as String] = Int(pixelFormat)
        settings[kCVPixelBufferMetalCompatibilityKey as String] = true
        settings[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        return settings
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

    private func cmTime(from time: RationalTime) throws -> CMTime {
        guard time.timescale <= Int64(Int32.max) else {
            throw MediaDecodeError.invalidTime(time)
        }

        return CMTime(value: time.value, timescale: Int32(time.timescale))
    }

    private func rationalTime(from time: CMTime) throws -> RationalTime {
        guard time.isValid, time.timescale > 0 else {
            throw MediaDecodeError.invalidPresentationTime
        }

        do {
            return try RationalTime(value: time.value, timescale: Int64(time.timescale))
        } catch {
            throw MediaDecodeError.invalidPresentationTime
        }
    }
}

private extension AVAssetReader {
    var errorDescription: String {
        error.map(String.init(describing:)) ?? "unknown reader error"
    }
}
