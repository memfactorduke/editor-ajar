// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarMedia
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension MediaPreviewCache {
    /// Nonzero + kind-specific structural validation; failed validation forces regenerate (L2).
    nonisolated static func isValidCachedData(_ data: Data, kind: MediaPreviewKind) -> Bool {
        guard !data.isEmpty else { return false }
        switch kind {
        case .thumbnail:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return false
            }
            return CGImageSourceGetCount(source) > 0
                && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        case .waveform:
            return (try? JSONDecoder().decode(AudioWaveformSummary.self, from: data)) != nil
        }
    }

    static func extract(media: MediaRef, kind: MediaPreviewKind) async throws -> Data {
        try Task.checkCancellation()
        switch kind {
        case .thumbnail:
            return try await extractThumbnailPNG(media: media, at: .zero)
        case .waveform:
            let summary = try await waveformSummary(for: media) { media, range in
                try await audioBuffer(for: media, range: range)
            }
            return try JSONEncoder().encode(summary)
        }
    }

    /// Generates one deterministic waveform while retaining only a bounded PCM window at a time.
    ///
    /// The accumulator preserves a partially filled bin between native-rate windows, so 44.1 kHz
    /// and other rates whose 24 Hz bin boundary does not align with four seconds produce exactly
    /// the same bins as a monolithic analysis.
    static func waveformSummary(
        for media: MediaRef,
        decodeChunk: AudioChunkDecoder
    ) async throws -> AudioWaveformSummary {
        let sourceDuration = media.metadata.duration
        let preferredChunkDuration = try RationalTime(
            value: waveformDecodeChunkSeconds,
            timescale: 1
        )
        let verifiedSource =
            try await MediaSourceIdentityVerifier.shared.verifyBeforeReading(media)
        var nextStart = RationalTime.zero
        var maximumChunkDuration = preferredChunkDuration
        var accumulator: AudioWaveformAccumulator?
        var decodedEmptySource = false

        while nextStart < sourceDuration || !decodedEmptySource && sourceDuration == .zero {
            try Task.checkCancellation()
            let remainingDuration = try sourceDuration.subtracting(nextStart)
            let initialChunkDuration = min(maximumChunkDuration, remainingDuration)
            let (source, decodedDuration) = try await boundedAudioChunk(
                media: media,
                start: nextStart,
                duration: initialChunkDuration,
                decodeChunk: decodeChunk
            )
            try Task.checkCancellation()

            if accumulator == nil {
                accumulator = try AudioWaveformAccumulator(
                    format: source.format,
                    binsPerSecond: 24
                )
            }
            try accumulator?.append(source) {
                try Task.checkCancellation()
            }

            decodedEmptySource = true
            nextStart = try nextStart.adding(decodedDuration)
            maximumChunkDuration = min(maximumChunkDuration, decodedDuration)
        }

        guard var accumulator else {
            throw MediaPreviewCacheError.unsupportedAudio
        }
        try Task.checkCancellation()
        let summary = accumulator.makeSummary()
        try await MediaSourceIdentityVerifier.shared.verifyAfterReading(verifiedSource)
        return summary
    }

    private static func boundedAudioChunk(
        media: MediaRef,
        start: RationalTime,
        duration initialDuration: RationalTime,
        decodeChunk: AudioChunkDecoder
    ) async throws -> (source: AudioSourceBuffer, duration: RationalTime) {
        var duration = initialDuration
        while true {
            try Task.checkCancellation()
            let range = try TimeRange(start: start, duration: duration)
            do {
                return (try await decodeChunk(media, range), duration)
            } catch let error as AudioPCMDecodeError {
                guard case .windowTooLarge(_, let frameCount, _, _) = error,
                    frameCount > 1
                else {
                    throw error
                }
                duration = try duration.divided(by: 2)
            }
        }
    }

    static func extractThumbnailPNG(
        media: MediaRef,
        at time: RationalTime
    ) async throws -> Data {
        try await extractVerifiedThumbnailPNG(media: media, at: time) { media, time in
            try await decodeThumbnailPNG(media: media, at: time)
        }
    }

    /// Identity-verifying production wrapper with the decoder exposed below the safety boundary.
    /// The injection point keeps replacement-during-decode behavior deterministic in tests.
    static func extractVerifiedThumbnailPNG(
        media: MediaRef,
        at time: RationalTime,
        decode: ThumbnailDecoder
    ) async throws -> Data {
        try Task.checkCancellation()
        let verifiedSource = try await MediaSourceIdentityVerifier.shared.verifyBeforeReading(media)
        let data = try await decode(media, time)
        try Task.checkCancellation()
        try await MediaSourceIdentityVerifier.shared.verifyAfterReading(verifiedSource)
        return data
    }

    private static func decodeThumbnailPNG(
        media: MediaRef,
        at time: RationalTime
    ) async throws -> Data {
        let decoder = try VideoFrameDecoder()
        let frame = try await decoder.decodeFrame(from: media, at: time)
        try Task.checkCancellation()
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw MediaPreviewCacheError.imageConversionFailed
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil
            )
        else {
            throw MediaPreviewCacheError.imageConversionFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaPreviewCacheError.imageConversionFailed
        }
        return data as Data
    }

    private static func audioBuffer(
        for media: MediaRef,
        range: TimeRange
    ) async throws -> AudioSourceBuffer {
        let decoded = try await AudioPCMDecoder().decodeWindow(
            from: media,
            sourceRange: range
        )
        try Task.checkCancellation()
        return try AudioSourceBuffer(
            format: AudioRenderFormat(
                sampleRate: decoded.sampleRate,
                channelCount: decoded.channelCount
            ),
            frameCount: decoded.frameCount,
            samples: decoded.samples,
            frameOffset: decoded.frameOffset
        )
    }
}
