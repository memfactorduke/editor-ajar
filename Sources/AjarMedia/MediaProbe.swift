// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
// swiftlint:enable sorted_imports

/// Result of probing one source at the native AjarMedia import boundary.
public struct MediaProbeResult: Equatable, Sendable {
    /// Durable metadata suitable for a project media reference.
    public let metadata: MediaMetadata

    /// Number of video samples observed during timing analysis, when the source has video.
    public let videoFrameCount: Int64?

    /// Exact video-track duration used with frame statistics, which may differ from asset duration.
    public let videoDuration: RationalTime?

    /// Creates a probe result.
    public init(
        metadata: MediaMetadata,
        videoFrameCount: Int64? = nil,
        videoDuration: RationalTime? = nil
    ) {
        self.metadata = metadata
        self.videoFrameCount = videoFrameCount
        self.videoDuration = videoDuration
    }
}

/// Injectable native-media probing boundary used by the importer.
public protocol MediaProbing {
    /// Probes one referenced-in-place source without mutating a project.
    func probe(_ sourceURL: URL) async throws -> MediaProbeResult
}

/// Typed failures from the native AVFoundation / ImageIO probe.
public enum MediaProbeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Import only accepts local file URLs.
    case sourceMustBeFileURL(URL)

    /// The source is missing or unreadable.
    case sourceUnavailable(URL)

    /// Neither ImageIO nor AVFoundation can open the source as supported media.
    case unsupportedFormat(URL)

    /// AVFoundation exposed media but could not provide required metadata.
    case metadataUnavailable(url: URL, reason: String)

    /// Native sample timing could not be read, so playback cannot safely use the source.
    case timingReadFailed(url: URL, reason: String)

    public var description: String {
        switch self {
        case .sourceMustBeFileURL(let url):
            "media import requires a local file URL: \(url)"
        case .sourceUnavailable(let url):
            "media source is missing or unreadable: \(url.path)"
        case .unsupportedFormat(let url):
            "unsupported media format: \(url.lastPathComponent)"
        case .metadataUnavailable(let url, let reason):
            "media metadata unavailable for \(url.lastPathComponent): \(reason)"
        case .timingReadFailed(let url, let reason):
            "media timing unavailable for \(url.lastPathComponent): \(reason)"
        }
    }
}

/// Native probe for AVFoundation video/audio and ImageIO still images (FR-MED-002).
///
/// The probe performs full sample-timing inspection for video so VFR is detected from actual
/// presentation intervals rather than guessed from a container's nominal frame-rate label.
public struct AVFoundationMediaProbe: MediaProbing, Sendable {
    /// Creates the production native probe.
    public init() {}

    public func probe(_ sourceURL: URL) async throws -> MediaProbeResult {
        guard sourceURL.isFileURL else {
            throw MediaProbeError.sourceMustBeFileURL(sourceURL)
        }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw MediaProbeError.sourceUnavailable(sourceURL)
        }

        let startedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        if let still = try probeStillImage(sourceURL) {
            return still
        }
        return try await probeAVAsset(sourceURL)
    }

    private func probeStillImage(_ sourceURL: URL) throws -> MediaProbeResult? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }
        guard CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = integerValue(properties[kCGImagePropertyPixelWidth]),
              let height = integerValue(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0
        else {
            throw MediaProbeError.metadataUnavailable(
                url: sourceURL,
                reason: "ImageIO did not provide positive pixel dimensions"
            )
        }

        let metadata = MediaMetadata(
            codecID: stillCodecID(for: sourceURL, source: source),
            pixelDimensions: PixelDimensions(width: width, height: height),
            frameRate: nil,
            // Still duration is an editable placement concern. Store a positive one-second
            // source extent until a clip chooses its timeline duration.
            duration: try RationalTime(value: 1, timescale: 1),
            colorSpace: stillColorSpace(for: image),
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
        return MediaProbeResult(metadata: metadata)
    }

    private func probeAVAsset(_ sourceURL: URL) async throws -> MediaProbeResult {
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }

        let rationalDuration = try makeRationalTime(duration, sourceURL: sourceURL)
        let video = try await probeVideo(
            videoTracks.first,
            asset: asset,
            sourceURL: sourceURL
        )
        let audio = try await probeAudio(
            audioTracks.first,
            asset: asset,
            sourceURL: sourceURL
        )
        let metadata = MediaMetadata(
            codecID: video?.codecID ?? audio?.codecID ?? "unknown",
            pixelDimensions: video?.dimensions,
            frameRate: video?.frameRate,
            duration: rationalDuration,
            colorSpace: video?.colorSpace ?? .unspecified,
            audioChannelLayout: audio?.layout,
            isVariableFrameRate: video?.timing.isVariableFrameRate ?? false,
            // The importer owns the conform decision. The native probe supplies frame statistics.
            conformedFrameRate: nil
        )
        return MediaProbeResult(
            metadata: metadata,
            videoFrameCount: video?.timing.frameCount,
            videoDuration: video?.duration
        )
    }

    private func probeVideo(
        _ track: AVAssetTrack?,
        asset: AVAsset,
        sourceURL: URL
    ) async throws -> VideoFacts? {
        guard let track else {
            return nil
        }

        let descriptions: [CMFormatDescription]
        let naturalSize: CGSize
        let nominalFrameRate: Float
        let timeRange: CMTimeRange
        do {
            descriptions = try await track.load(.formatDescriptions)
            naturalSize = try await track.load(.naturalSize)
            nominalFrameRate = try await track.load(.nominalFrameRate)
            timeRange = try await track.load(.timeRange)
        } catch {
            throw MediaProbeError.metadataUnavailable(
                url: sourceURL,
                reason: String(describing: error)
            )
        }
        guard let description = descriptions.first else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        let formatDimensions = CMVideoFormatDescriptionGetDimensions(description)
        let width = formatDimensions.width > 0
            ? Int(formatDimensions.width)
            : Int(abs(naturalSize.width.rounded()))
        let height = formatDimensions.height > 0
            ? Int(formatDimensions.height)
            : Int(abs(naturalSize.height.rounded()))
        guard width > 0, height > 0 else {
            throw MediaProbeError.metadataUnavailable(
                url: sourceURL,
                reason: "video track did not provide positive pixel dimensions"
            )
        }

        try validateNativeVideoDecode(asset: asset, track: track, sourceURL: sourceURL)
        let timing = try inspectTiming(asset: asset, track: track, sourceURL: sourceURL)
        let frameRate = frameRate(near: Double(nominalFrameRate))
            ?? timing.averageFrameRate
        return VideoFacts(
            codecID: codecID(for: CMFormatDescriptionGetMediaSubType(description)),
            dimensions: PixelDimensions(width: width, height: height),
            frameRate: frameRate,
            timing: timing,
            duration: try? makeRationalTime(timeRange.duration, sourceURL: sourceURL),
            colorSpace: videoColorSpace(for: description)
        )
    }

    private func probeAudio(
        _ track: AVAssetTrack?,
        asset: AVAsset,
        sourceURL: URL
    ) async throws -> AudioFacts? {
        guard let track else {
            return nil
        }
        let descriptions: [CMFormatDescription]
        do {
            descriptions = try await track.load(.formatDescriptions)
        } catch {
            throw MediaProbeError.metadataUnavailable(
                url: sourceURL,
                reason: String(describing: error)
            )
        }
        guard let description = descriptions.first else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        try validateNativeAudioDecode(asset: asset, track: track, sourceURL: sourceURL)
        let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        let channels = streamDescription.map { Int($0.pointee.mChannelsPerFrame) } ?? 0
        return AudioFacts(
            codecID: codecID(for: CMFormatDescriptionGetMediaSubType(description)),
            layout: channels > 0 ? AjarCore.AudioChannelLayout(channelCount: channels) : nil
        )
    }

}
