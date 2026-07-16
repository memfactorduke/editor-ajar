// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarCore
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
// swiftlint:enable sorted_imports

/// Errors from sequential original-media decode used for proxy generation (FR-MED-004).
public enum MediaTranscodeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Media has no usable source URL.
    case missingSourceURL(mediaID: UUID)

    /// Source file is missing or unreadable.
    case missingSource(URL)

    /// Source has no video track.
    case unsupportedSource(URL)

    /// Requested frame index is outside the configured range.
    case frameIndexOutOfRange(Int64)

    /// AVAssetReader setup failed.
    case readerSetupFailed(String)

    /// Decode failed mid-stream.
    case readerFailed(String)

    /// No sample was available for the requested time.
    case frameUnavailable(RationalTime)

    /// Pixel-buffer creation or scale failed.
    case pixelBufferFailed(String)

    public var description: String {
        switch self {
        case .missingSourceURL(let mediaID):
            "media \(mediaID) has no source URL for proxy transcode"
        case .missingSource(let url):
            "proxy transcode source missing: \(url.path)"
        case .unsupportedSource(let url):
            "proxy transcode source has no video track: \(url.path)"
        case .frameIndexOutOfRange(let index):
            "proxy transcode frame index out of range: \(index)"
        case .readerSetupFailed(let message):
            "proxy transcode reader setup failed: \(message)"
        case .readerFailed(let message):
            "proxy transcode reader failed: \(message)"
        case .frameUnavailable(let time):
            "proxy transcode frame unavailable at \(time)"
        case .pixelBufferFailed(let message):
            "proxy transcode pixel buffer failed: \(message)"
        }
    }
}

/// Sequential original-media frame provider for proxy / optimized-media generation.
///
/// Sources frames from the **media decode path** (AVAssetReader on the original file), not the
/// render graph — proxies are per-media transcodes (FR-MED-004 / ADR-0019).
public final class MediaTranscodeFrameProvider: @unchecked Sendable {
    private let mediaID: UUID
    private let sourceURL: URL
    private let frameRate: FrameRate
    private let frameCount: Int64
    private let outputResolution: PixelDimensions

    /// Creates a provider that decodes `media` from its original source URL.
    public init(media: MediaRef, frameCount: Int64, outputResolution: PixelDimensions) throws {
        guard let sourceURL = media.sourceURL else {
            throw MediaTranscodeError.missingSourceURL(mediaID: media.id)
        }
        guard let frameRate = media.metadata.conformedFrameRate ?? media.metadata.frameRate else {
            throw MediaTranscodeError.readerSetupFailed(
                "media \(media.id) has no frame rate for proxy transcode"
            )
        }
        guard frameCount > 0 else {
            throw MediaTranscodeError.frameIndexOutOfRange(0)
        }
        mediaID = media.id
        self.sourceURL = sourceURL
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.outputResolution = outputResolution
    }

    /// Creates a provider for an explicit original URL (tests / CLI helpers).
    public init(
        mediaID: UUID,
        sourceURL: URL,
        frameRate: FrameRate,
        frameCount: Int64,
        outputResolution: PixelDimensions
    ) {
        self.mediaID = mediaID
        self.sourceURL = sourceURL
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.outputResolution = outputResolution
    }

    /// Decodes original frame `index` and scales it into `pixelBuffer`.
    ///
    /// Source decode uses 32BGRA via `AVAssetReader`. The writer-owned destination for ProRes 422
    /// Proxy is typically big-endian 64ARGB; `VTPixelTransferSession` converts formats and scales.
    public func provideFrame(index: Int64, into pixelBuffer: CVPixelBuffer) async throws {
        guard index >= 0, index < frameCount else {
            throw MediaTranscodeError.frameIndexOutOfRange(index)
        }
        let time = try RationalTime.atFrame(index, frameRate: frameRate)
        let sourceBuffer = try await decodePixelBuffer(at: time)
        try scale(sourceBuffer, into: pixelBuffer)
    }

    private func decodePixelBuffer(at time: RationalTime) async throws -> CVPixelBuffer {
        let started = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if started {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        try requireReadableSource()
        // AVAssetReaderTrackOutput requires its track to belong to the exact asset instance used
        // by the reader. Reconstructing the same URL as a second AVURLAsset is not equivalent and
        // makes reader.canAdd(output) fail before the first proxy frame can decode.
        let asset = AVURLAsset(url: sourceURL)
        let track = try await loadVideoTrack(from: asset)
        let reader = try makeReader(for: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw MediaTranscodeError.readerSetupFailed("cannot add video output")
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: try cmTime(from: time),
            duration: .positiveInfinity
        )
        guard reader.startReading() else {
            throw MediaTranscodeError.readerSetupFailed(
                reader.error.map(String.init(describing:)) ?? "startReading failed"
            )
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }
        return try nextImageBuffer(from: output, reader: reader, time: time)
    }

    private func requireReadableSource() throws {
        if sourceURL.isFileURL,
           !FileManager.default.isReadableFile(atPath: sourceURL.path) {
            throw MediaTranscodeError.missingSource(sourceURL)
        }
    }

    private func loadVideoTrack(from asset: AVURLAsset) async throws -> AVAssetTrack {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw MediaTranscodeError.unsupportedSource(sourceURL)
        }
        guard let track = tracks.first else {
            throw MediaTranscodeError.unsupportedSource(sourceURL)
        }
        return track
    }

    private func makeReader(for asset: AVURLAsset) throws -> AVAssetReader {
        do {
            return try AVAssetReader(asset: asset)
        } catch {
            throw MediaTranscodeError.readerSetupFailed(String(describing: error))
        }
    }

    private func nextImageBuffer(
        from output: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        time: RationalTime
    ) throws -> CVPixelBuffer {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw MediaTranscodeError.readerFailed(
                    reader.error.map(String.init(describing:)) ?? "reader failed"
                )
            }
            throw MediaTranscodeError.frameUnavailable(time)
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw MediaTranscodeError.pixelBufferFailed("sample missing image buffer")
        }
        return imageBuffer
    }

    private func scale(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let destWidth = CVPixelBufferGetWidth(destination)
        let destHeight = CVPixelBufferGetHeight(destination)
        guard destWidth == outputResolution.width, destHeight == outputResolution.height else {
            throw MediaTranscodeError.pixelBufferFailed(
                "destination \(destWidth)x\(destHeight) != output "
                    + "\(outputResolution.width)x\(outputResolution.height)"
            )
        }
        var session: VTPixelTransferSession?
        let createStatus = VTPixelTransferSessionCreate(
            allocator: nil,
            pixelTransferSessionOut: &session
        )
        guard createStatus == noErr, let session else {
            throw MediaTranscodeError.pixelBufferFailed(
                "VTPixelTransferSessionCreate failed: \(createStatus)"
            )
        }
        defer { VTPixelTransferSessionInvalidate(session) }
        VTSessionSetProperty(
            session,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Trim
        )
        let transferStatus = VTPixelTransferSessionTransferImage(
            session,
            from: source,
            to: destination
        )
        guard transferStatus == noErr else {
            throw MediaTranscodeError.pixelBufferFailed(
                "VTPixelTransferSessionTransferImage failed: \(transferStatus)"
            )
        }
    }

    private func cmTime(from time: RationalTime) throws -> CMTime {
        CMTime(
            value: time.value,
            timescale: CMTimeScale(time.timescale),
            flags: .valid,
            epoch: 0
        )
    }
}
