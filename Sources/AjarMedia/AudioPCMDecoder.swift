// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
@preconcurrency import AVFoundation
import AjarCore
import Foundation

// swiftlint:enable sorted_imports

/// Errors produced by native, windowed audio decoding.
public enum AudioPCMDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A media reference has no usable source URL.
    case missingSourceURL(mediaID: UUID)

    /// Native audio decode only accepts local file URLs.
    case sourceMustBeFileURL(URL)

    /// The source file is missing or unreadable.
    case missingSource(URL)

    /// AVFoundation cannot open the source as media.
    case unsupportedSource(URL)

    /// The source is valid media but does not contain an audio track.
    case missingAudioTrack(URL)

    /// Source time cannot begin before zero.
    case invalidSourceRange(TimeRange)

    /// Leading and trailing native-frame guards must be non-negative.
    case invalidFramePadding(leading: Int, trailing: Int)

    /// The native audio format was missing or invalid.
    case invalidFormat(sampleRate: Double, channelCount: Int)

    /// Source-time conversion exceeded the representable native-frame range.
    case invalidTime(RationalTime)

    /// AVAssetReader could not be configured.
    case readerSetupFailed(String)

    /// AVAssetReader failed after decoding began.
    case readerFailed(String)

    /// A decoded sample carried an invalid presentation timestamp.
    case invalidPresentationTime

    /// A decoded sample's PCM layout did not match interleaved Float32 output.
    case invalidSampleData(String)

    /// The requested window contained no decodable audio samples.
    case windowUnavailable(URL, TimeRange)

    /// The decoder returned only part of a nonempty requested native-frame window.
    case windowUnderDelivered(
        URL,
        expectedFrameRange: Range<Int>,
        actualFrameRange: Range<Int>
    )

    /// The requested native PCM window would exceed the decoder's fixed allocation budget.
    case windowTooLarge(
        URL,
        frameCount: Int,
        channelCount: Int,
        maximumSampleBytes: Int
    )

    /// A human-readable description of the decode failure.
    public var description: String {
        switch self {
        case .missingSourceURL(let mediaID):
            "media \(mediaID) does not have a source URL for audio decode"
        case .sourceMustBeFileURL(let url):
            "audio decode requires a local file URL: \(url)"
        case .missingSource(let url):
            "audio source is missing or unreadable: \(url.path)"
        case .unsupportedSource(let url):
            "unsupported audio source: \(url.lastPathComponent)"
        case .missingAudioTrack(let url):
            "media source has no audio track: \(url.lastPathComponent)"
        case .invalidSourceRange(let range):
            "audio source range begins before zero: \(range.start)"
        case .invalidFramePadding(let leading, let trailing):
            "audio frame padding must be non-negative (leading \(leading), "
                + "trailing \(trailing))"
        case .invalidFormat(let sampleRate, let channelCount):
            "invalid native audio format (\(sampleRate) Hz, \(channelCount) channels)"
        case .invalidTime(let time):
            "audio source time cannot be represented as a native frame: \(time)"
        case .readerSetupFailed(let message):
            "audio AVAssetReader setup failed: \(message)"
        case .readerFailed(let message):
            "audio AVAssetReader failed: \(message)"
        case .invalidPresentationTime:
            "decoded audio sample had an invalid presentation timestamp"
        case .invalidSampleData(let message):
            "decoded audio sample data was invalid: \(message)"
        case .windowUnavailable(let url, let range):
            "no audio samples were available in \(url.lastPathComponent) at "
                + "\(range.start) for \(range.duration) seconds"
        case .windowUnderDelivered(let url, let expected, let actual):
            "audio decoder under-delivered \(url.lastPathComponent): expected native frames "
                + "\(expected), received \(actual)"
        case .windowTooLarge(let url, let frameCount, let channelCount, let maximumSampleBytes):
            "audio window for \(url.lastPathComponent) is too large to decode safely "
                + "(\(frameCount) frames, \(channelCount) channels; maximum "
                + "\(maximumSampleBytes) sample bytes)"
        }
    }
}

/// One owned, interleaved native-rate PCM window in absolute source-media coordinates.
public struct DecodedAudioWindow: Equatable, Sendable {
    /// The source file's native sample rate in hertz.
    public let sampleRate: Int

    /// The source file's native interleaved channel count.
    public let channelCount: Int

    /// Presentation timestamp represented by `samples[0]`.
    public let presentationTime: RationalTime

    /// Absolute source-frame index represented by `samples[0]`.
    public let frameOffset: Int

    /// Number of complete interleaved frames in `samples`.
    public let frameCount: Int

    /// Decoder-owned interleaved Float32 samples.
    public let samples: [Float]
}

/// Native AVFoundation audio decoder that reads only a requested source-time window.
///
/// Output remains at the file's native rate and channel count. Callers can request exact leading
/// and trailing native-frame guards for fractional interpolation without asking the decoder to
/// know project-rate or mixer policy. Blocking `AVAssetReader` work runs on a dedicated queue so
/// concurrent audio preparation cannot occupy Swift's cooperative executor (NFR-STAB-001).
public struct AudioPCMDecoder: Sendable {
    /// Hard ceiling for one owned decoder window, enforced before `Array.reserveCapacity`.
    /// Callers stream longer media as bounded windows; unusually large single-window requests
    /// fail with a typed error instead of risking process termination from memory pressure.
    static let maximumWindowSampleBytes = 64 * 1_024 * 1_024

    /// Prevents a burst of cancelled playback, meter, waveform, and export requests from creating
    /// an unbounded number of blocking AVAssetReader workers.
    static let maximumConcurrentAudioDecodes = 4

    static let blockingDecodeExecutor = BoundedAudioDecodeExecutor(
        label: "org.editorajar.audio-pcm-decode",
        maximumConcurrentOperationCount: maximumConcurrentAudioDecodes
    )

    let securityScope: any AudioPCMDecoderSecurityScopeAccessing

    /// Creates the production native PCM decoder.
    public init() {
        securityScope = URLAudioPCMDecoderSecurityScopeAccess()
    }

    /// Test seam for proving balanced security-scoped access on every exit path.
    init(securityScope: any AudioPCMDecoderSecurityScopeAccessing) {
        self.securityScope = securityScope
    }

    /// Decodes a media reference's audio in `sourceRange`.
    public func decodeWindow(
        from media: MediaRef,
        sourceRange: TimeRange,
        leadingFrameCount: Int = 0,
        trailingFrameCount: Int = 0
    ) async throws -> DecodedAudioWindow {
        guard let sourceURL = media.sourceURL else {
            throw AudioPCMDecodeError.missingSourceURL(mediaID: media.id)
        }
        return try await decodeWindow(
            from: sourceURL,
            sourceRange: sourceRange,
            leadingFrameCount: leadingFrameCount,
            trailingFrameCount: trailingFrameCount
        )
    }

    /// Decodes an owned, interleaved Float32 window from a local source file.
    ///
    /// The unpadded request is aligned with `floor(start * nativeRate)` through
    /// `ceil(end * nativeRate)`. `leadingFrameCount` and `trailingFrameCount` then expand that
    /// native-frame interval exactly; only the lower edge is clamped to source frame zero.
    public func decodeWindow(
        from sourceURL: URL,
        sourceRange: TimeRange,
        leadingFrameCount: Int = 0,
        trailingFrameCount: Int = 0
    ) async throws -> DecodedAudioWindow {
        try Self.validate(
            sourceURL: sourceURL,
            sourceRange: sourceRange,
            leadingFrameCount: leadingFrameCount,
            trailingFrameCount: trailingFrameCount
        )

        let startedSecurityScope = securityScope.startAccessing(sourceURL)
        defer {
            if startedSecurityScope {
                securityScope.stopAccessing(sourceURL)
            }
        }

        try Self.requireAvailableSource(sourceURL)
        try Task.checkCancellation()

        let asset = AVURLAsset(url: sourceURL)
        let track = try await Self.loadAudioTrack(asset: asset, sourceURL: sourceURL)
        let format = try await Self.loadNativeFormat(track: track, sourceURL: sourceURL)
        let timeline = try await Self.loadSourceTimeline(
            asset: asset,
            track: track,
            format: format,
            sourceURL: sourceURL
        )
        let context = try Self.decodeContext(
            asset: asset,
            track: track,
            sourceURL: sourceURL,
            sourceRange: sourceRange,
            format: format,
            timeline: timeline,
            leadingFrameCount: leadingFrameCount,
            trailingFrameCount: trailingFrameCount
        )
        try Task.checkCancellation()

        if context.frameRange.isEmpty {
            return try Self.emptyWindow(frameRange: context.frameRange, format: format)
        }

        let window = try await Self.blockingDecodeExecutor.run(
            cancellation: context.cancellation
        ) {
            try Self.readWindow(context)
        }
        try Task.checkCancellation()
        return window
    }
}
