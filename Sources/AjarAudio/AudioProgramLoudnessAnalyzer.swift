// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Typed failures from offline program loudness analysis.
public enum AudioProgramLoudnessError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The sample rate cannot support the BS.1770 K-weighting filters.
    case invalidSampleRate(Int)

    /// Program loudness currently supports mono/stereo until layout-aware surround weights exist.
    case unsupportedChannelCount(Int)

    /// A human-readable description.
    public var description: String {
        switch self {
        case .invalidSampleRate(let sampleRate):
            "invalid loudness analysis sample rate \(sampleRate)"
        case .unsupportedChannelCount(let channelCount):
            "unsupported loudness analysis channel count \(channelCount)"
        }
    }
}

/// Offline FR-AUD-003 program loudness and true-peak report.
public struct AudioProgramLoudnessReport: Codable, Equatable, Sendable {
    /// Render sample rate in hertz.
    public let sampleRate: Int

    /// Rendered channel count.
    public let channelCount: Int

    /// Number of complete frames in the analyzed window.
    public let frameCount: Int

    /// BS.1770/R128 integrated loudness in LUFS, or `nil` when all blocks are gated silence.
    public let integratedLUFS: Double?

    /// Estimated inter-sample true peak as linear amplitude. 0 dBTP is linear amplitude 1.0.
    public let truePeak: Double

    /// Estimated inter-sample true peak in dBTP, or `nil` for silence.
    public let truePeakDBTP: Double?

    /// Count of complete 400 ms loudness blocks before gating.
    public let blockCount: Int

    /// Count of loudness blocks retained after absolute and relative gating.
    public let gatedBlockCount: Int

    /// Deterministic true-peak oversampling factor.
    public let truePeakOversamplingFactor: Int

    /// Whether integrated loudness was gated to the silence sentinel.
    public var isGatedToSilence: Bool {
        integratedLUFS == nil
    }

    /// Creates a program loudness report.
    public init(
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int,
        integratedLUFS: Double?,
        truePeak: Double,
        blockCount: Int,
        gatedBlockCount: Int,
        truePeakOversamplingFactor: Int
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.integratedLUFS = integratedLUFS
        self.truePeak = truePeak
        truePeakDBTP = AudioMeterChannelLevel.dbFS(for: truePeak)
        self.blockCount = blockCount
        self.gatedBlockCount = gatedBlockCount
        self.truePeakOversamplingFactor = truePeakOversamplingFactor
    }
}

public extension AudioMixerMeterAnalyzer {
    /// Computes BS.1770/R128 integrated loudness and 4x true peak for a rendered buffer.
    ///
    /// This is deterministic offline analysis for FR-AUD-003, not the FR-AUD-007 real-time audio
    /// callback path. K-weighting follows the BS.1770 two-stage high-shelf plus RLB high-pass
    /// filter model; stereo uses L/R channel weights of 1.0 and surround layout weighting is out of
    /// scope until layout metadata is available.
    static func measureProgramLoudness(
        buffer: RenderedAudioBuffer
    ) throws -> AudioProgramLoudnessReport {
        try BS1770.validate(sampleRate: buffer.format.sampleRate)
        try BS1770.validate(channelCount: buffer.format.channelCount)
        let powers = BS1770.kWeightedPowers(buffer: buffer)
        let blockEnergies = BS1770.blockEnergies(
            powers: powers,
            sampleRate: buffer.format.sampleRate
        )
        let gated = BS1770.gatedLoudness(blockEnergies: blockEnergies)
        let truePeak = BS1770.truePeak(buffer: buffer)

        return AudioProgramLoudnessReport(
            sampleRate: buffer.format.sampleRate,
            channelCount: buffer.format.channelCount,
            frameCount: buffer.frameCount,
            integratedLUFS: gated.integratedLUFS,
            truePeak: truePeak,
            blockCount: blockEnergies.count,
            gatedBlockCount: gated.gatedBlockCount,
            truePeakOversamplingFactor: BS1770.truePeakOversamplingFactor
        )
    }

    /// Renders a project sequence window, then computes integrated loudness and true peak.
    static func measureProgramLoudness(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        sourceProvider: any AudioSourceProvider,
        channelCount: Int = 2
    ) throws -> AudioProgramLoudnessReport {
        try measureProgramLoudness(
            sequence: sequence,
            range: range,
            format: AudioRenderFormat(
                sampleRate: project.settings.audioSampleRate,
                channelCount: channelCount
            ),
            sourceProvider: sourceProvider
        )
    }

    /// Renders a sequence window, then computes integrated loudness and true peak.
    static func measureProgramLoudness(
        sequence: Sequence,
        range: TimeRange,
        format: AudioRenderFormat,
        sourceProvider: any AudioSourceProvider
    ) throws -> AudioProgramLoudnessReport {
        let buffer = try OfflineAudioMixer.render(
            sequence: sequence,
            range: range,
            format: format,
            sourceProvider: sourceProvider
        )
        return try measureProgramLoudness(buffer: buffer)
    }
}

private enum BS1770 {
    static let loudnessOffset = -0.691
    static let absoluteGateLUFS = -70.0
    static let relativeGateLU = -10.0
    static let blockDurationMilliseconds = 400
    static let blockHopMilliseconds = 100
    static let truePeakOversamplingFactor = 4
    static let truePeakSincRadius = 32
    static let truePeakKernels = TruePeakKernel.kernels(
        oversamplingFactor: truePeakOversamplingFactor,
        radius: truePeakSincRadius
    )

    // ITU-R BS.1770 K-weighting constants. At 48 kHz, these produce the published high-shelf
    // coefficients b=[1.5351248596, -2.6916961894, 1.1983928109],
    // a=[1, -1.6906592932, 0.7324807742] before the RLB high-pass stage.
    static let highShelfGainDB = 3.999843853973347
    static let highShelfFrequency = 1_681.974450955533
    static let highShelfQ = 0.7071752369554196
    static let highShelfVbExponent = 0.499666774155
    static let highPassFrequency = 38.13547087602444
    static let highPassQ = 0.5003270373253953

    struct GatedLoudness {
        let integratedLUFS: Double?
        let gatedBlockCount: Int
    }

    static func validate(sampleRate: Int) throws {
        guard Double(sampleRate) > highShelfFrequency * 2 else {
            throw AudioProgramLoudnessError.invalidSampleRate(sampleRate)
        }
    }

    static func validate(channelCount: Int) throws {
        guard channelCount == 1 || channelCount == 2 else {
            throw AudioProgramLoudnessError.unsupportedChannelCount(channelCount)
        }
    }

    static func kWeightedPowers(buffer: RenderedAudioBuffer) -> [Double] {
        let channelCount = buffer.format.channelCount
        var preFilters = filters(
            coefficients: .kWeightingHighShelf(sampleRate: buffer.format.sampleRate),
            count: channelCount
        )
        var highPassFilters = filters(
            coefficients: .kWeightingHighPass(sampleRate: buffer.format.sampleRate),
            count: channelCount
        )
        var powers = Array(repeating: Double(0), count: buffer.frameCount)

        for frame in 0..<buffer.frameCount {
            var framePower = Double(0)
            for channel in 0..<channelCount {
                let sampleIndex = (frame * channelCount) + channel
                let prefiltered = preFilters[channel].process(Double(buffer.samples[sampleIndex]))
                let filtered = highPassFilters[channel].process(prefiltered)
                framePower += channelWeight(channel: channel) * filtered * filtered
            }
            powers[frame] = framePower
        }

        return powers
    }

    static func blockEnergies(powers: [Double], sampleRate: Int) -> [Double] {
        let blockSize = (sampleRate * blockDurationMilliseconds) / 1_000
        let hopSize = (sampleRate * blockHopMilliseconds) / 1_000
        guard blockSize > 0, hopSize > 0, powers.count >= blockSize else {
            return []
        }

        var energies: [Double] = []
        var start = 0
        while start + blockSize <= powers.count {
            var sum = Double(0)
            for frame in start..<(start + blockSize) {
                sum += powers[frame]
            }
            energies.append(sum / Double(blockSize))
            start += hopSize
        }
        return energies
    }

    static func gatedLoudness(blockEnergies: [Double]) -> GatedLoudness {
        let absoluteGated = blockEnergies.filter { energy in
            (loudness(energy: energy) ?? -.infinity) >= absoluteGateLUFS
        }
        guard !absoluteGated.isEmpty else {
            return GatedLoudness(integratedLUFS: nil, gatedBlockCount: 0)
        }

        let preliminaryLoudness = loudness(energy: average(absoluteGated)) ?? -.infinity
        let threshold = max(absoluteGateLUFS, preliminaryLoudness + relativeGateLU)
        let relativeGated = absoluteGated.filter { energy in
            (loudness(energy: energy) ?? -.infinity) >= threshold
        }
        guard !relativeGated.isEmpty else {
            return GatedLoudness(integratedLUFS: nil, gatedBlockCount: 0)
        }

        return GatedLoudness(
            integratedLUFS: loudness(energy: average(relativeGated)),
            gatedBlockCount: relativeGated.count
        )
    }

    static func truePeak(buffer: RenderedAudioBuffer) -> Double {
        var peak = Double(0)
        for channel in 0..<buffer.format.channelCount {
            peak = max(peak, truePeak(buffer: buffer, channel: channel))
        }
        return peak
    }

    static func truePeak(buffer: RenderedAudioBuffer, channel: Int) -> Double {
        var peak = samplePeak(buffer: buffer, channel: channel)
        guard buffer.frameCount > 1 else {
            return peak
        }

        for frame in 0..<(buffer.frameCount - 1) {
            for kernel in truePeakKernels {
                let value = sincInterpolatedSample(
                    buffer: buffer,
                    channel: channel,
                    frame: frame,
                    kernel: kernel
                )
                peak = max(peak, abs(value))
            }
        }
        return peak
    }

    static func samplePeak(buffer: RenderedAudioBuffer, channel: Int) -> Double {
        var peak = Double(0)
        for frame in 0..<buffer.frameCount {
            let sampleIndex = (frame * buffer.format.channelCount) + channel
            peak = max(peak, abs(Double(buffer.samples[sampleIndex])))
        }
        return peak
    }
}

private extension BS1770 {
    static func filters(coefficients: BiquadCoefficients, count: Int) -> [BiquadFilter] {
        Array(repeating: BiquadFilter(coefficients: coefficients), count: count)
    }

    static func channelWeight(channel: Int) -> Double {
        // FR-AUD-003 currently validates channel count before analysis, so this remains the
        // BS.1770 mono/stereo L/R weight until layout-aware surround metadata exists.
        channel >= 0 ? 1 : 0
    }

    static func loudness(energy: Double) -> Double? {
        guard energy > 0, energy.isFinite else {
            return nil
        }
        return loudnessOffset + (10 * log10(energy))
    }

    static func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    static func sincInterpolatedSample(
        buffer: RenderedAudioBuffer,
        channel: Int,
        frame: Int,
        kernel: TruePeakKernel
    ) -> Double {
        var sum = Double(0)
        for index in kernel.offsets.indices {
            let sampleFrame = frame + kernel.offsets[index]
            guard sampleFrame >= 0, sampleFrame < buffer.frameCount else {
                continue
            }
            let sampleIndex = (sampleFrame * buffer.format.channelCount) + channel
            let sample = Double(buffer.samples[sampleIndex])
            sum += sample * kernel.weights[index]
        }
        return sum
    }

    static func sinc(_ value: Double) -> Double {
        guard abs(value) > 0.000_000_000_001 else {
            return 1
        }
        let scaled = Double.pi * value
        return sin(scaled) / scaled
    }

    static func hannWindow(distance: Double) -> Double {
        let radius = Double(truePeakSincRadius)
        guard abs(distance) <= radius else {
            return 0
        }
        return 0.5 * (1 + cos((Double.pi * distance) / radius))
    }
}

private struct BiquadCoefficients {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    static func kWeightingHighShelf(sampleRate: Int) -> BiquadCoefficients {
        let kValue = tan(Double.pi * BS1770.highShelfFrequency / Double(sampleRate))
        let vh = pow(10, BS1770.highShelfGainDB / 20)
        let vb = pow(vh, BS1770.highShelfVbExponent)
        let a0 = 1 + (kValue / BS1770.highShelfQ) + (kValue * kValue)
        return BiquadCoefficients(
            b0: (vh + ((vb * kValue) / BS1770.highShelfQ) + (kValue * kValue)) / a0,
            b1: (2 * ((kValue * kValue) - vh)) / a0,
            b2: (vh - ((vb * kValue) / BS1770.highShelfQ) + (kValue * kValue)) / a0,
            a1: (2 * ((kValue * kValue) - 1)) / a0,
            a2: (1 - (kValue / BS1770.highShelfQ) + (kValue * kValue)) / a0
        )
    }

    static func kWeightingHighPass(sampleRate: Int) -> BiquadCoefficients {
        let kValue = tan(Double.pi * BS1770.highPassFrequency / Double(sampleRate))
        let a0 = 1 + (kValue / BS1770.highPassQ) + (kValue * kValue)
        return BiquadCoefficients(
            // ITU-R BS.1770-4 Table 1 keeps the RLB high-pass numerator at [1, -2, 1]
            // and normalizes only the denominator terms by a0.
            b0: 1,
            b1: -2,
            b2: 1,
            a1: (2 * ((kValue * kValue) - 1)) / a0,
            a2: (1 - (kValue / BS1770.highPassQ) + (kValue * kValue)) / a0
        )
    }
}

private struct TruePeakKernel {
    let offsets: [Int]
    let weights: [Double]

    static func kernels(oversamplingFactor: Int, radius: Int) -> [TruePeakKernel] {
        (1..<oversamplingFactor).map { phase in
            kernel(phase: Double(phase) / Double(oversamplingFactor), radius: radius)
        }
    }

    static func kernel(phase: Double, radius: Int) -> TruePeakKernel {
        let offsets = Array((-radius + 1)...radius)
        let weights = offsets.map { offset in
            let distance = phase - Double(offset)
            return BS1770.sinc(distance) * BS1770.hannWindow(distance: distance)
        }
        return TruePeakKernel(offsets: offsets, weights: weights)
    }
}

private struct BiquadFilter {
    let coefficients: BiquadCoefficients
    var x1 = Double(0)
    var x2 = Double(0)
    var y1 = Double(0)
    var y2 = Double(0)

    mutating func process(_ x0: Double) -> Double {
        let y0 = (coefficients.b0 * x0)
            + (coefficients.b1 * x1)
            + (coefficients.b2 * x2)
            - (coefficients.a1 * y1)
            - (coefficients.a2 * y2)
        x2 = x1
        x1 = x0
        y2 = y1
        y1 = y0
        return y0
    }
}
