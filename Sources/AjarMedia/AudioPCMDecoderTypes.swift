// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
@preconcurrency import AVFoundation
import AjarCore
import Foundation

// swiftlint:enable sorted_imports

struct AudioPCMNativeFormat: Sendable {
    let sampleRate: Int
    let channelCount: Int
}

struct AudioPCMSourceTimeline: Sendable {
    let assetFrameRange: Range<Int>
    let audioFrameRange: Range<Int>
}

/// AVFoundation objects are immutable after their async property loads and are transferred once
/// to the dedicated blocking queue. Apple has not annotated these reference types as Sendable.
struct AudioPCMDecodeContext: @unchecked Sendable {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let sourceURL: URL
    let sourceRange: TimeRange
    let frameRange: Range<Int>
    let decodeFrameRange: Range<Int>
    let format: AudioPCMNativeFormat
    let cancellation: AudioPCMDecodeCancellation
}

extension AudioPCMDecoder {
    // swiftlint:disable:next function_parameter_count
    static func decodeContext(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sourceURL: URL,
        sourceRange: TimeRange,
        format: AudioPCMNativeFormat,
        timeline: AudioPCMSourceTimeline,
        leadingFrameCount: Int,
        trailingFrameCount: Int
    ) throws -> AudioPCMDecodeContext {
        let requiredFrameRange = try nativeFrameRange(
            for: sourceRange,
            sampleRate: format.sampleRate,
            leadingFrameCount: 0,
            trailingFrameCount: 0
        )
        let paddedFrameRange = try nativeFrameRange(
            for: sourceRange,
            sampleRate: format.sampleRate,
            leadingFrameCount: leadingFrameCount,
            trailingFrameCount: trailingFrameCount
        )
        // Enforce the caller's requested allocation before timeline clamping. A wildly oversized
        // request must remain a memory-budget failure even when the source itself is much shorter.
        try validateWindowAllocation(
            sourceURL: sourceURL,
            frameRange: paddedFrameRange,
            channelCount: format.channelCount
        )
        guard timeline.assetFrameRange.lowerBound <= requiredFrameRange.lowerBound,
            timeline.assetFrameRange.upperBound >= requiredFrameRange.upperBound
        else {
            throw AudioPCMDecodeError.windowUnderDelivered(
                sourceURL,
                expectedFrameRange: requiredFrameRange,
                actualFrameRange: clampedIntersection(
                    requiredFrameRange,
                    to: timeline.assetFrameRange
                )
            )
        }
        let frameRange = clampedIntersection(
            paddedFrameRange,
            to: timeline.assetFrameRange
        )
        let decodeFrameRange = clampedIntersection(
            frameRange,
            to: timeline.audioFrameRange
        )
        return AudioPCMDecodeContext(
            asset: asset,
            track: track,
            sourceURL: sourceURL,
            sourceRange: sourceRange,
            frameRange: frameRange,
            decodeFrameRange: decodeFrameRange,
            format: format,
            cancellation: AudioPCMDecodeCancellation()
        )
    }
}

/// Cooperative cancellation state shared with a queued or active blocking decode.
///
/// The reader itself remains owned by one blocking worker from start through teardown. Calling
/// `cancelReading()` from a second thread while `copyNextSampleBuffer()` is active can violate that
/// lifecycle boundary, so cancellation prevents queued work and is polled between bounded reads.
final class AudioPCMDecodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.withLock {
            isCancelled = true
        }
    }

    func check() throws {
        if lock.withLock({ isCancelled }) {
            throw CancellationError()
        }
    }
}

struct AudioPCMReaderComponents {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
}

struct AudioPCMSampleDescriptor {
    let presentationTime: RationalTime
    let startFrame: Int
    let endFrame: Int
    let sampleRate: Int
    let channelCount: Int
    let samples: [Float]
}

struct AudioPCMFrameSlice {
    let presentationTime: RationalTime
    let startFrame: Int
    let endFrame: Int
    let samples: [Float]
}

struct AudioPCMWindowAccumulator {
    let context: AudioPCMDecodeContext
    var samples: [Float] = []
    var firstFrameOffset: Int?
    var nextFrameOffset: Int?

    init(context: AudioPCMDecodeContext) {
        self.context = context
        let capacity = context.frameRange.count.multipliedReportingOverflow(
            by: context.format.channelCount
        )
        samples.reserveCapacity(capacity.overflow ? 0 : capacity.partialValue)
    }

    mutating func append(_ slice: AudioPCMFrameSlice) throws {
        if let expectedFrame = nextFrameOffset, expectedFrame != slice.startFrame {
            throw AudioPCMDecodeError.invalidSampleData(
                "non-contiguous timestamps (expected frame \(expectedFrame), "
                    + "received \(slice.startFrame))"
            )
        }
        if firstFrameOffset == nil {
            firstFrameOffset = slice.startFrame
        }
        samples.append(contentsOf: slice.samples)
        nextFrameOffset = slice.endFrame
    }

    mutating func makeWindow() throws -> DecodedAudioWindow {
        let actualFrameRange: Range<Int>
        if let frameOffset = firstFrameOffset, let endFrameOffset = nextFrameOffset {
            actualFrameRange = frameOffset..<endFrameOffset
        } else {
            actualFrameRange =
                context.decodeFrameRange.lowerBound..<context.decodeFrameRange.lowerBound
        }
        guard actualFrameRange == context.decodeFrameRange else {
            throw AudioPCMDecodeError.windowUnderDelivered(
                context.sourceURL,
                expectedFrameRange: context.decodeFrameRange,
                actualFrameRange: actualFrameRange
            )
        }
        return try makePaddedWindow(
            decodedFrameRange: actualFrameRange.isEmpty ? nil : actualFrameRange
        )
    }

    private mutating func makePaddedWindow(
        decodedFrameRange: Range<Int>?
    ) throws -> DecodedAudioWindow {
        let channelCount = context.format.channelCount
        let sampleCount = context.frameRange.count * channelCount
        if let decodedFrameRange {
            let expectedDecodedSampleCount = decodedFrameRange.count * channelCount
            guard decodedFrameRange.lowerBound >= context.frameRange.lowerBound,
                decodedFrameRange.upperBound <= context.frameRange.upperBound,
                samples.count == expectedDecodedSampleCount
            else {
                throw AudioPCMDecodeError.invalidSampleData(
                    "decoded PCM samples do not match their timestamp range"
                )
            }
            let leadingSampleCount =
                (decodedFrameRange.lowerBound - context.frameRange.lowerBound)
                * channelCount
            samples.insert(
                contentsOf: repeatElement(Float.zero, count: leadingSampleCount),
                at: 0
            )
        }
        let trailingSampleCount = sampleCount - samples.count
        guard trailingSampleCount >= 0 else {
            throw AudioPCMDecodeError.invalidSampleData(
                "decoded PCM samples exceed their requested window"
            )
        }
        samples.append(contentsOf: repeatElement(Float.zero, count: trailingSampleCount))
        guard let presentationFrame = Int64(exactly: context.frameRange.lowerBound) else {
            throw AudioPCMDecodeError.invalidTime(context.sourceRange.start)
        }
        return DecodedAudioWindow(
            sampleRate: context.format.sampleRate,
            channelCount: channelCount,
            presentationTime: try RationalTime(
                value: presentationFrame,
                timescale: Int64(context.format.sampleRate)
            ),
            frameOffset: context.frameRange.lowerBound,
            frameCount: context.frameRange.count,
            samples: samples
        )
    }
}

protocol AudioPCMDecoderSecurityScopeAccessing: Sendable {
    func startAccessing(_ sourceURL: URL) -> Bool
    func stopAccessing(_ sourceURL: URL)
}

struct URLAudioPCMDecoderSecurityScopeAccess: AudioPCMDecoderSecurityScopeAccessing {
    func startAccessing(_ sourceURL: URL) -> Bool {
        sourceURL.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ sourceURL: URL) {
        sourceURL.stopAccessingSecurityScopedResource()
    }
}

extension AVAssetReader {
    var audioErrorDescription: String {
        error.map(String.init(describing:)) ?? "unknown reader error"
    }
}
