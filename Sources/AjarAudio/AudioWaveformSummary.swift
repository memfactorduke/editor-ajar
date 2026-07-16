// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed failures from deterministic waveform analysis.
public enum AudioWaveformError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A waveform bin cannot contain zero or negative frames.
    case invalidFramesPerBin(Int)

    /// A bins-per-second request must be positive.
    case invalidBinsPerSecond(Int)

    /// Waveform output metadata would overflow before allocation.
    case binCountOverflow(frameCount: Int, framesPerBin: Int, channelCount: Int)

    /// A streaming source format must have a positive integer rate and channel count.
    case invalidSourceFormat(sampleRate: Int, channelCount: Int)

    /// Every chunk in one streaming summary must keep the source's native format.
    case inconsistentSourceFormat(
        expectedSampleRate: Int,
        expectedChannelCount: Int,
        actualSampleRate: Int,
        actualChannelCount: Int
    )

    /// Streaming chunks must be contiguous in absolute native-frame coordinates.
    case nonContiguousSourceFrames(expectedFrameOffset: Int, actualFrameOffset: Int)

    /// Appending a source window would overflow the accumulated native-frame count.
    case sourceFrameCountOverflow(currentFrameCount: Int, appendedFrameCount: Int)

    /// A human-readable description.
    public var description: String {
        switch self {
        case .invalidFramesPerBin(let framesPerBin):
            "invalid waveform framesPerBin \(framesPerBin)"
        case .invalidBinsPerSecond(let binsPerSecond):
            "invalid waveform binsPerSecond \(binsPerSecond)"
        case .binCountOverflow(let frameCount, let framesPerBin, let channelCount):
            "waveform bin count overflows frameCount=\(frameCount) "
                + "framesPerBin=\(framesPerBin) channelCount=\(channelCount)"
        case .invalidSourceFormat(let sampleRate, let channelCount):
            "invalid waveform source format \(sampleRate) Hz, \(channelCount) channels"
        case .inconsistentSourceFormat(
            let expectedSampleRate,
            let expectedChannelCount,
            let actualSampleRate,
            let actualChannelCount
        ):
            "waveform source format changed from \(expectedSampleRate) Hz/"
                + "\(expectedChannelCount) channels to \(actualSampleRate) Hz/"
                + "\(actualChannelCount) channels"
        case .nonContiguousSourceFrames(let expectedFrameOffset, let actualFrameOffset):
            "waveform source chunks are not contiguous: expected native frame "
                + "\(expectedFrameOffset), received \(actualFrameOffset)"
        case .sourceFrameCountOverflow(let currentFrameCount, let appendedFrameCount):
            "waveform source frame count overflows while appending \(appendedFrameCount) "
                + "frames to \(currentFrameCount)"
        }
    }
}

/// Peak and RMS data for one channel within one waveform time bin.
public struct AudioWaveformBin: Codable, Equatable, Sendable {
    /// Minimum sample value in this bin.
    public let minimum: Float

    /// Maximum sample value in this bin.
    public let maximum: Float

    /// Root-mean-square amplitude in this bin.
    public let rms: Float

    /// Number of source frames represented by this bin.
    public let frameCount: Int

    /// Creates a waveform bin.
    public init(minimum: Float, maximum: Float, rms: Float, frameCount: Int) {
        self.minimum = minimum
        self.maximum = maximum
        self.rms = rms
        self.frameCount = frameCount
    }
}

/// Waveform bins for one interleaved PCM channel.
public struct AudioWaveformChannelSummary: Codable, Equatable, Sendable {
    /// Zero-based source channel index.
    public let channelIndex: Int

    /// Ordered bins for this channel.
    public let bins: [AudioWaveformBin]

    /// Creates a channel waveform summary.
    public init(channelIndex: Int, bins: [AudioWaveformBin]) {
        self.channelIndex = channelIndex
        self.bins = bins
    }
}

/// Deterministic, cache-friendly waveform data for an interleaved PCM source.
public struct AudioWaveformSummary: Codable, Equatable, Sendable {
    /// Source sample rate in hertz.
    public let sampleRate: Int

    /// Source channel count.
    public let channelCount: Int

    /// Source frame count.
    public let sourceFrameCount: Int

    /// Number of source frames represented by each full bin.
    public let framesPerBin: Int

    /// Per-channel waveform bins.
    public let channels: [AudioWaveformChannelSummary]

    /// Number of bins in each channel summary.
    public var binCount: Int {
        channels.first?.bins.count ?? 0
    }

    /// Creates a waveform summary.
    public init(
        sampleRate: Int,
        channelCount: Int,
        sourceFrameCount: Int,
        framesPerBin: Int,
        channels: [AudioWaveformChannelSummary]
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sourceFrameCount = sourceFrameCount
        self.framesPerBin = framesPerBin
        self.channels = channels
    }
}

/// Incremental waveform analysis that retains compact bins, never the source PCM history.
///
/// Chunks may end in the middle of a bin. The accumulator carries that bin's per-channel
/// minimum, maximum, sum-of-squares, and frame count into the next chunk, so its result is
/// bit-for-bit equivalent to analyzing the same native frames in one `AudioSourceBuffer`.
public struct AudioWaveformAccumulator: Sendable {
    /// Native source format shared by every appended window.
    public let format: AudioRenderFormat

    /// Number of source frames represented by each complete output bin.
    public let framesPerBin: Int

    private var sourceFrameCount = 0
    private var expectedFrameOffset: Int?
    private var binsByChannel: [[AudioWaveformBin]]
    private var activeMinimum: [Float]
    private var activeMaximum: [Float]
    private var activeSumOfSquares: [Double]
    private var activeFrameCount = 0

    /// Creates an accumulator with exact native-frame bin boundaries.
    public init(format: AudioRenderFormat, framesPerBin: Int) throws {
        guard framesPerBin > 0 else {
            throw AudioWaveformError.invalidFramesPerBin(framesPerBin)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioWaveformError.invalidSourceFormat(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            )
        }
        self.format = format
        self.framesPerBin = framesPerBin
        binsByChannel = Array(repeating: [], count: format.channelCount)
        activeMinimum = Array(repeating: 0, count: format.channelCount)
        activeMaximum = Array(repeating: 0, count: format.channelCount)
        activeSumOfSquares = Array(repeating: 0, count: format.channelCount)
    }

    /// Creates an accumulator at a deterministic number of bins per source second.
    public init(format: AudioRenderFormat, binsPerSecond: Int) throws {
        guard binsPerSecond > 0 else {
            throw AudioWaveformError.invalidBinsPerSecond(binsPerSecond)
        }
        try self.init(
            format: format,
            framesPerBin: max(1, format.sampleRate / binsPerSecond)
        )
    }

    /// Adds one contiguous, native-rate PCM window.
    ///
    /// `cancellationCheck` is polled before allocation growth, every 1,024 frames, and after the
    /// chunk. It lets import/cache tasks stop long analysis without turning cancellation into a
    /// partial waveform.
    public mutating func append(
        _ source: AudioSourceBuffer,
        cancellationCheck: @escaping AudioRenderCancellationCheck = {}
    ) throws {
        try cancellationCheck()
        try validateFormat(source.format)
        try validateFrameOffset(source)

        let newFrameCount = sourceFrameCount.addingReportingOverflow(source.frameCount)
        let endFrameOffset = source.frameOffset.addingReportingOverflow(source.frameCount)
        guard !newFrameCount.overflow, !endFrameOffset.overflow else {
            throw AudioWaveformError.sourceFrameCountOverflow(
                currentFrameCount: sourceFrameCount,
                appendedFrameCount: source.frameCount
            )
        }
        let binCount = try AudioWaveformAnalyzer.checkedBinCount(
            frameCount: newFrameCount.partialValue,
            framesPerBin: framesPerBin,
            channelCount: format.channelCount
        )
        for channelIndex in binsByChannel.indices {
            binsByChannel[channelIndex].reserveCapacity(binCount)
        }

        for localFrame in 0..<source.frameCount {
            if localFrame & 1_023 == 0 {
                try cancellationCheck()
            }
            appendFrame(source, localFrame: localFrame)
        }

        sourceFrameCount = newFrameCount.partialValue
        expectedFrameOffset = endFrameOffset.partialValue
        try cancellationCheck()
    }

    /// Finishes the trailing partial bin and returns the deterministic compact summary.
    public mutating func makeSummary() -> AudioWaveformSummary {
        finishActiveBinIfNeeded()
        let channels = binsByChannel.enumerated().map { channelIndex, bins in
            AudioWaveformChannelSummary(channelIndex: channelIndex, bins: bins)
        }
        return AudioWaveformSummary(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            sourceFrameCount: sourceFrameCount,
            framesPerBin: framesPerBin,
            channels: channels
        )
    }
}

/// Deterministic waveform analysis for import/cache-time work.
public enum AudioWaveformAnalyzer {
    /// Summarizes an audio source using a fixed number of source frames per waveform bin.
    ///
    /// Binning is half-open and source-order preserving: frames `0..<framesPerBin` form the first
    /// bin, `framesPerBin..<(2 * framesPerBin)` form the second, and the final partial bin keeps
    /// its smaller `frameCount`. Generation may allocate output storage because it is not used on
    /// the real-time audio render path.
    public static func summarize(
        source: AudioSourceBuffer,
        framesPerBin: Int
    ) throws -> AudioWaveformSummary {
        var accumulator = try AudioWaveformAccumulator(
            format: source.format,
            framesPerBin: framesPerBin
        )
        try accumulator.append(source)
        return accumulator.makeSummary()
    }

    /// Summarizes an audio source using a target number of waveform bins per second.
    ///
    /// The target is converted to integer source frames per bin with floor division, clamped to at
    /// least one frame per bin. This keeps bin boundaries deterministic for a given sample rate.
    public static func summarize(
        source: AudioSourceBuffer,
        binsPerSecond: Int
    ) throws -> AudioWaveformSummary {
        guard binsPerSecond > 0 else {
            throw AudioWaveformError.invalidBinsPerSecond(binsPerSecond)
        }

        let framesPerBin = max(1, source.format.sampleRate / binsPerSecond)
        return try summarize(source: source, framesPerBin: framesPerBin)
    }
}

extension AudioWaveformAnalyzer {
    static func checkedBinCount(
        frameCount: Int,
        framesPerBin: Int,
        channelCount: Int
    ) throws -> Int {
        let fullBinCount = frameCount / framesPerBin
        let partialBinCount = frameCount % framesPerBin == 0 ? 0 : 1
        guard fullBinCount <= Int.max - partialBinCount else {
            throw AudioWaveformError.binCountOverflow(
                frameCount: frameCount,
                framesPerBin: framesPerBin,
                channelCount: channelCount
            )
        }

        let binCount = fullBinCount + partialBinCount
        guard channelCount == 0 || binCount <= Int.max / channelCount else {
            throw AudioWaveformError.binCountOverflow(
                frameCount: frameCount,
                framesPerBin: framesPerBin,
                channelCount: channelCount
            )
        }
        return binCount
    }

}

private extension AudioWaveformAccumulator {
    mutating func validateFormat(_ actual: AudioRenderFormat) throws {
        guard actual == format else {
            throw AudioWaveformError.inconsistentSourceFormat(
                expectedSampleRate: format.sampleRate,
                expectedChannelCount: format.channelCount,
                actualSampleRate: actual.sampleRate,
                actualChannelCount: actual.channelCount
            )
        }
    }

    mutating func validateFrameOffset(_ source: AudioSourceBuffer) throws {
        guard let expectedFrameOffset else {
            return
        }
        guard source.frameOffset == expectedFrameOffset else {
            throw AudioWaveformError.nonContiguousSourceFrames(
                expectedFrameOffset: expectedFrameOffset,
                actualFrameOffset: source.frameOffset
            )
        }
    }

    mutating func appendFrame(_ source: AudioSourceBuffer, localFrame: Int) {
        let frameSampleOffset = localFrame * format.channelCount
        for channelIndex in 0..<format.channelCount {
            let value = source.samples[frameSampleOffset + channelIndex]
            if activeFrameCount == 0 {
                activeMinimum[channelIndex] = value
                activeMaximum[channelIndex] = value
            } else {
                activeMinimum[channelIndex] = min(activeMinimum[channelIndex], value)
                activeMaximum[channelIndex] = max(activeMaximum[channelIndex], value)
            }
            let doubleValue = Double(value)
            activeSumOfSquares[channelIndex] += doubleValue * doubleValue
        }
        activeFrameCount += 1
        if activeFrameCount == framesPerBin {
            finishActiveBinIfNeeded()
        }
    }

    mutating func finishActiveBinIfNeeded() {
        guard activeFrameCount > 0 else {
            return
        }
        for channelIndex in 0..<format.channelCount {
            binsByChannel[channelIndex].append(
                AudioWaveformBin(
                    minimum: activeMinimum[channelIndex],
                    maximum: activeMaximum[channelIndex],
                    rms: Float(
                        (activeSumOfSquares[channelIndex] / Double(activeFrameCount)).squareRoot()
                    ),
                    frameCount: activeFrameCount
                )
            )
            activeSumOfSquares[channelIndex] = 0
        }
        activeFrameCount = 0
    }
}
