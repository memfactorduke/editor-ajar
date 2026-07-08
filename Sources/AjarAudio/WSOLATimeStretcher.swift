// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Typed failures from the deterministic WSOLA time stretcher.
public enum WSOLATimeStretchError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Channel count must be positive.
    case invalidChannelCount(Int)

    /// Sample rate must be positive.
    case invalidSampleRate(Int)

    /// The interleaved sample count is not a whole number of frames.
    case sampleCountNotFrameAligned(sampleCount: Int, channelCount: Int)

    /// The stretch factor (clip speed) must be greater than zero.
    case nonPositiveSpeed(RationalValue)

    /// Exact frame arithmetic overflowed.
    case frameCountOverflow(frameCount: Int, speed: RationalValue)

    /// A human-readable description of the failure.
    public var description: String {
        switch self {
        case .invalidChannelCount(let channelCount):
            "WSOLA channel count \(channelCount) must be positive"
        case .invalidSampleRate(let sampleRate):
            "WSOLA sample rate \(sampleRate) must be positive"
        case .sampleCountNotFrameAligned(let sampleCount, let channelCount):
            "WSOLA sample count \(sampleCount) is not a multiple of \(channelCount) channels"
        case .nonPositiveSpeed(let speed):
            "WSOLA speed \(speed.numerator)/\(speed.denominator) must be greater than zero"
        case .frameCountOverflow(let frameCount, let speed):
            "WSOLA output length overflowed for \(frameCount) frames at speed "
                + "\(speed.numerator)/\(speed.denominator)"
        }
    }
}

/// Deterministic waveform-similarity overlap-add (WSOLA) time stretcher for FR-SPD-001
/// pitch-corrected constant-speed audio.
///
/// The stretcher compresses or expands the time axis by the clip's constant speed while
/// preserving pitch: the output is read back 1:1, so the source's local waveform (and with
/// it the fundamental frequency) is unchanged. Every parameter is fixed and documented below;
/// the algorithm uses no randomness, no wall-clock input, and only stable forward iteration,
/// so two runs over the same input are bit-identical.
///
/// Fixed parameters:
/// - **Analysis window**: 20 ms of source audio — 960 frames at 48 kHz — scaled by the actual
///   sample rate and rounded down to an even frame count (minimum 4).
/// - **Synthesis hop**: 50% of the analysis window (`N/2`).
/// - **Window function**: periodic Hann, `w[n] = 0.5 · (1 − cos(2πn/N))`, which sums to unity
///   at 50% overlap; the head/tail taper is corrected by dividing by the accumulated window
///   sum (frames whose accumulated window sum is below `1e-9` output exact silence).
/// - **Similarity search**: normalized cross-correlation over the channel-averaged mono
///   downmix, lag range ±(hop/2) around the exact rational target position. Lags are scanned
///   in ascending order and a candidate must be **strictly** greater to win, so ties break
///   toward the lowest (most negative) lag. Segments with zero energy score exactly 0.
/// - **Boundary policy**: reads outside the input are exact zeros, so the final segments
///   decay into silence deterministically.
/// - **Identity**: a speed of exactly 1/1 returns the input verbatim (bit-identical), by
///   definition rather than by numerical reconstruction.
public enum WSOLATimeStretcher {
    /// Analysis window length in seconds (20 ms; 960 frames at 48 kHz).
    public static let analysisWindowSeconds = 0.020

    /// Minimum floating-point window-sum before a frame renders as exact silence.
    public static let minimumWindowSum = 1e-9

    /// Analysis window length in frames for a sample rate: `20 ms` scaled by the actual rate,
    /// rounded down to an even count with a floor of 4 frames.
    public static func analysisWindowFrameCount(sampleRate: Int) -> Int {
        let scaled = Int((analysisWindowSeconds * Double(sampleRate)).rounded())
        return max(4, scaled - (scaled % 2))
    }

    /// Synthesis hop in frames: 50% of the analysis window.
    public static func synthesisHopFrameCount(sampleRate: Int) -> Int {
        analysisWindowFrameCount(sampleRate: sampleRate) / 2
    }

    /// Exact stretched output length: `round(frameCount / speed)` computed with integer
    /// rational arithmetic (`(frameCount · den + num/2) / num`), so output timeline duration
    /// equals source duration divided by speed to within half a frame.
    public static func stretchedFrameCount(
        frameCount: Int,
        speed: RationalValue
    ) throws -> Int {
        try validate(speed: speed)
        let numerator = speed.numerator
        let scaled = Int64(frameCount).multipliedReportingOverflow(by: speed.denominator)
        let rounded = scaled.partialValue.addingReportingOverflow(numerator / 2)
        guard !scaled.overflow, !rounded.overflow else {
            throw WSOLATimeStretchError.frameCountOverflow(frameCount: frameCount, speed: speed)
        }
        return Int(rounded.partialValue / numerator)
    }

    /// Stretches interleaved PCM by a constant speed, preserving pitch.
    ///
    /// - Parameters:
    ///   - samples: Interleaved source samples (`frameCount × channelCount`).
    ///   - channelCount: Interleaved channel count. The similarity lag is computed once on
    ///     the channel-averaged mono downmix and applied to every channel, keeping the
    ///     inter-channel image phase-coherent.
    ///   - sampleRate: Source sample rate in hertz; scales the fixed 20 ms analysis window.
    ///   - speed: The clip's constant speed. `2/1` halves the duration, `1/2` doubles it.
    /// - Returns: Interleaved stretched samples of exactly
    ///   `stretchedFrameCount(frameCount:speed:)` frames.
    public static func stretch(
        samples: [Float],
        channelCount: Int,
        sampleRate: Int,
        speed: RationalValue
    ) throws -> [Float] {
        guard channelCount > 0 else {
            throw WSOLATimeStretchError.invalidChannelCount(channelCount)
        }
        guard sampleRate > 0 else {
            throw WSOLATimeStretchError.invalidSampleRate(sampleRate)
        }
        guard samples.count % channelCount == 0 else {
            throw WSOLATimeStretchError.sampleCountNotFrameAligned(
                sampleCount: samples.count,
                channelCount: channelCount
            )
        }
        try validate(speed: speed)
        // Unit speed is the exact identity: return the input verbatim, bit-identical.
        if speed == .one {
            return samples
        }

        let inputFrameCount = samples.count / channelCount
        let outputFrameCount = try stretchedFrameCount(frameCount: inputFrameCount, speed: speed)
        guard outputFrameCount > 0, inputFrameCount > 0 else {
            return Array(repeating: 0, count: outputFrameCount * channelCount)
        }

        return synthesize(
            input: StretchInput(
                samples: samples,
                channelCount: channelCount,
                frameCount: inputFrameCount,
                speed: speed
            ),
            windowFrameCount: analysisWindowFrameCount(sampleRate: sampleRate),
            outputFrameCount: outputFrameCount
        )
    }
}

/// Immutable per-run stretch input shared by the synthesis helpers.
struct StretchInput {
    let samples: [Float]
    let channelCount: Int
    let frameCount: Int
    let speed: RationalValue

    /// Channel-averaged mono downmix used for the similarity search.
    func monoDownmix() -> [Double] {
        var mono = [Double](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum = 0.0
            for channel in 0..<channelCount {
                sum += Double(samples[(frame * channelCount) + channel])
            }
            mono[frame] = sum / Double(channelCount)
        }
        return mono
    }

    /// Zero-padded interleaved sample read: frames outside the input are exact zeros.
    func sample(frame: Int, channel: Int) -> Double {
        guard frame >= 0, frame < frameCount else {
            return 0
        }
        return Double(samples[(frame * channelCount) + channel])
    }
}

private extension WSOLATimeStretcher {
    static func validate(speed: RationalValue) throws {
        guard speed.numerator > 0, speed.denominator > 0 else {
            throw WSOLATimeStretchError.nonPositiveSpeed(speed)
        }
    }

    /// Exact rational analysis target for a synthesis position:
    /// `round(synthesisFrame · speed)` in integer arithmetic.
    static func analysisTarget(synthesisFrame: Int, speed: RationalValue) -> Int {
        let scaled = Int64(synthesisFrame) * speed.numerator
        return Int((scaled + (speed.denominator / 2)) / speed.denominator)
    }

    static func synthesize(
        input: StretchInput,
        windowFrameCount: Int,
        outputFrameCount: Int
    ) -> [Float] {
        let hop = windowFrameCount / 2
        let searchRadius = hop / 2
        let mono = input.monoDownmix()
        var accumulator = OverlapAddAccumulator(
            window: hannWindow(frameCount: windowFrameCount),
            outputFrameCount: outputFrameCount,
            channelCount: input.channelCount
        )

        var previousAnalysisStart = 0
        var segmentIndex = 0
        while segmentIndex * hop < outputFrameCount {
            let synthesisStart = segmentIndex * hop
            let target = analysisTarget(synthesisFrame: synthesisStart, speed: input.speed)
            let analysisStart: Int
            if segmentIndex == 0 {
                analysisStart = target
            } else {
                analysisStart = target + bestLag(
                    mono: mono,
                    target: target,
                    reference: previousAnalysisStart + hop,
                    windowFrameCount: windowFrameCount,
                    searchRadius: searchRadius
                )
            }
            accumulator.add(
                input: input,
                analysisStart: analysisStart,
                synthesisStart: synthesisStart
            )
            previousAnalysisStart = analysisStart
            segmentIndex += 1
        }

        return accumulator.normalizedOutput()
    }

    /// Periodic Hann window: `w[n] = 0.5 · (1 − cos(2πn/N))`, exact unity sum at 50% overlap.
    static func hannWindow(frameCount: Int) -> [Double] {
        (0..<frameCount).map { index in
            0.5 * (1 - cos(2 * Double.pi * Double(index) / Double(frameCount)))
        }
    }

    /// The lag in `[-searchRadius, +searchRadius]` whose candidate segment best matches the
    /// natural continuation of the previous segment, by normalized cross-correlation on the
    /// mono downmix. Lags scan in ascending order and only a strictly greater score replaces
    /// the incumbent, so ties break toward the lowest lag.
    static func bestLag(
        mono: [Double],
        target: Int,
        reference: Int,
        windowFrameCount: Int,
        searchRadius: Int
    ) -> Int {
        var best = -searchRadius
        var bestScore = -Double.infinity
        var lag = -searchRadius
        while lag <= searchRadius {
            let score = normalizedCrossCorrelation(
                mono: mono,
                candidate: target + lag,
                reference: reference,
                frameCount: windowFrameCount
            )
            if score > bestScore {
                bestScore = score
                best = lag
            }
            lag += 1
        }
        return best
    }

    /// Normalized cross-correlation of two zero-padded segments; either segment having zero
    /// energy scores exactly 0.
    static func normalizedCrossCorrelation(
        mono: [Double],
        candidate: Int,
        reference: Int,
        frameCount: Int
    ) -> Double {
        var dot = 0.0
        var candidateEnergy = 0.0
        var referenceEnergy = 0.0
        for index in 0..<frameCount {
            let candidateValue = paddedMono(mono, frame: candidate + index)
            let referenceValue = paddedMono(mono, frame: reference + index)
            dot += candidateValue * referenceValue
            candidateEnergy += candidateValue * candidateValue
            referenceEnergy += referenceValue * referenceValue
        }
        guard candidateEnergy > 0, referenceEnergy > 0 else {
            return 0
        }
        return dot / (candidateEnergy * referenceEnergy).squareRoot()
    }

    static func paddedMono(_ mono: [Double], frame: Int) -> Double {
        guard frame >= 0, frame < mono.count else {
            return 0
        }
        return mono[frame]
    }

}

/// Windowed overlap-add accumulation state for one synthesis run.
struct OverlapAddAccumulator {
    let window: [Double]
    let outputFrameCount: Int
    let channelCount: Int
    private var accumulated: [Double]
    private var windowSum: [Double]

    init(window: [Double], outputFrameCount: Int, channelCount: Int) {
        self.window = window
        self.outputFrameCount = outputFrameCount
        self.channelCount = channelCount
        let paddedFrameCount = outputFrameCount + window.count
        accumulated = [Double](repeating: 0, count: paddedFrameCount * channelCount)
        windowSum = [Double](repeating: 0, count: paddedFrameCount)
    }

    /// Overlap-adds one Hann-windowed analysis segment at a synthesis position.
    mutating func add(input: StretchInput, analysisStart: Int, synthesisStart: Int) {
        for offset in 0..<window.count {
            let weight = window[offset]
            let outputFrame = synthesisStart + offset
            windowSum[outputFrame] += weight
            for channel in 0..<channelCount {
                accumulated[(outputFrame * channelCount) + channel] +=
                    weight * input.sample(frame: analysisStart + offset, channel: channel)
            }
        }
    }

    /// Divides the overlap-add accumulation by the accumulated window sum, correcting the
    /// head/tail taper; frames with a window sum below
    /// `WSOLATimeStretcher.minimumWindowSum` are exact silence.
    func normalizedOutput() -> [Float] {
        var output = [Float](repeating: 0, count: outputFrameCount * channelCount)
        for frame in 0..<outputFrameCount {
            let sum = windowSum[frame]
            guard sum > WSOLATimeStretcher.minimumWindowSum else {
                continue
            }
            for channel in 0..<channelCount {
                let index = (frame * channelCount) + channel
                output[index] = Float(accumulated[index] / sum)
            }
        }
        return output
    }
}
