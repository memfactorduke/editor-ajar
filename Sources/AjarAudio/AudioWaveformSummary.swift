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
        guard framesPerBin > 0 else {
            throw AudioWaveformError.invalidFramesPerBin(framesPerBin)
        }

        let binCount = try checkedBinCount(
            frameCount: source.frameCount,
            framesPerBin: framesPerBin,
            channelCount: source.format.channelCount
        )
        let channels = channelSummaries(
            source: source,
            framesPerBin: framesPerBin,
            binCount: binCount
        )

        return AudioWaveformSummary(
            sampleRate: source.format.sampleRate,
            channelCount: source.format.channelCount,
            sourceFrameCount: source.frameCount,
            framesPerBin: framesPerBin,
            channels: channels
        )
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

private extension AudioWaveformAnalyzer {
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

    static func channelSummaries(
        source: AudioSourceBuffer,
        framesPerBin: Int,
        binCount: Int
    ) -> [AudioWaveformChannelSummary] {
        var channels: [AudioWaveformChannelSummary] = []
        channels.reserveCapacity(source.format.channelCount)

        for channelIndex in 0..<source.format.channelCount {
            let bins = waveformBins(
                source: source,
                channelIndex: channelIndex,
                framesPerBin: framesPerBin,
                binCount: binCount
            )
            channels.append(
                AudioWaveformChannelSummary(channelIndex: channelIndex, bins: bins)
            )
        }

        return channels
    }

    static func waveformBins(
        source: AudioSourceBuffer,
        channelIndex: Int,
        framesPerBin: Int,
        binCount: Int
    ) -> [AudioWaveformBin] {
        var bins: [AudioWaveformBin] = []
        bins.reserveCapacity(binCount)

        var binStartFrame = 0
        while binStartFrame < source.frameCount {
            let binEndFrame = min(binStartFrame + framesPerBin, source.frameCount)
            bins.append(
                waveformBin(
                    source: source,
                    channelIndex: channelIndex,
                    frameRange: binStartFrame..<binEndFrame
                )
            )
            binStartFrame = binEndFrame
        }

        return bins
    }

    static func waveformBin(
        source: AudioSourceBuffer,
        channelIndex: Int,
        frameRange: Range<Int>
    ) -> AudioWaveformBin {
        let firstSample = sample(
            source: source,
            frame: frameRange.lowerBound,
            channel: channelIndex
        )
        var minimum = firstSample
        var maximum = firstSample
        var sumOfSquares = Double(0)

        for frame in frameRange {
            let value = sample(source: source, frame: frame, channel: channelIndex)
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            let doubleValue = Double(value)
            sumOfSquares += doubleValue * doubleValue
        }

        let frameCount = frameRange.count
        let rms = Float((sumOfSquares / Double(frameCount)).squareRoot())
        return AudioWaveformBin(
            minimum: minimum,
            maximum: maximum,
            rms: rms,
            frameCount: frameCount
        )
    }

    static func sample(source: AudioSourceBuffer, frame: Int, channel: Int) -> Float {
        source.samples[(frame * source.format.channelCount) + channel]
    }
}
