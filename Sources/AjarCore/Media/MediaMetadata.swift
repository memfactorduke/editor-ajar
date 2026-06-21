// SPDX-License-Identifier: GPL-3.0-or-later

/// Pixel dimensions for visual media.
public struct PixelDimensions: Codable, Hashable, Sendable {
    /// Width in pixels.
    public let width: Int

    /// Height in pixels.
    public let height: Int

    /// Creates pixel dimensions.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Color space tags carried by probed media metadata.
public enum MediaColorSpace: String, Codable, Hashable, Sendable {
    /// Rec.709 video.
    case rec709

    /// Standard RGB still or screen media.
    case sRGB

    /// Display P3 media.
    case displayP3

    /// Rec.2020 wide-gamut media.
    case rec2020

    /// The source did not specify a color space.
    case unspecified

    /// The source color space is not yet modelled by AjarCore.
    case unknown
}

/// Audio channel information carried by probed media metadata.
public struct AudioChannelLayout: Codable, Hashable, Sendable {
    /// Number of audio channels.
    public let channelCount: Int

    /// Optional stable layout tag from the probing layer.
    public let layoutTag: String?

    /// Creates an audio channel layout.
    public init(channelCount: Int, layoutTag: String? = nil) {
        self.channelCount = channelCount
        self.layoutTag = layoutTag
    }
}

/// Probed media facts stored in the project manifest.
public struct MediaMetadata: Codable, Hashable, Sendable {
    /// Stable codec identifier from the probing layer, such as `h264` or `pcm_s16le`.
    public let codecID: String

    /// Pixel dimensions for visual media, or `nil` for audio-only media.
    public let pixelDimensions: PixelDimensions?

    /// Native frame rate when known.
    public let frameRate: FrameRate?

    /// Source duration in exact timeline time.
    public let duration: RationalTime

    /// Probed or inferred color space.
    public let colorSpace: MediaColorSpace

    /// Audio channel layout when the source has audio.
    public let audioChannelLayout: AudioChannelLayout?

    /// Whether the source has variable frame timing.
    public let isVariableFrameRate: Bool

    /// Stable timebase selected during import for variable-frame-rate media.
    public let conformedFrameRate: FrameRate?

    /// Creates media metadata for storage in `media.json`.
    public init(
        codecID: String,
        pixelDimensions: PixelDimensions?,
        frameRate: FrameRate?,
        duration: RationalTime,
        colorSpace: MediaColorSpace,
        audioChannelLayout: AudioChannelLayout?,
        isVariableFrameRate: Bool,
        conformedFrameRate: FrameRate?
    ) {
        self.codecID = codecID
        self.pixelDimensions = pixelDimensions
        self.frameRate = frameRate
        self.duration = duration
        self.colorSpace = colorSpace
        self.audioChannelLayout = audioChannelLayout
        self.isVariableFrameRate = isVariableFrameRate
        self.conformedFrameRate = conformedFrameRate
    }
}
