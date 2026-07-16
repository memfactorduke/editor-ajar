// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// FR-SPD-001 unit coverage for the deterministic WSOLA time stretcher.
final class WSOLATimeStretcherTests: XCTestCase {
    func testFRSPD001UnitSpeedIsBitIdenticalToInput() throws {
        let input = makeTestSignal(frameCount: 8_000, channelCount: 2)

        let output = try WSOLATimeStretcher.stretch(
            samples: input,
            channelCount: 2,
            sampleRate: 8_000,
            speed: .one
        )

        // Bit-identical, not merely close: identity is exact by definition.
        XCTAssertEqual(output, input)
    }

    func testFRSPD001OutputLengthMatchesSourceOverSpeedWithinOneHop() throws {
        let sampleRate = 8_000
        let hop = WSOLATimeStretcher.synthesisHopFrameCount(sampleRate: sampleRate)
        let input = makeTestSignal(frameCount: 8_000, channelCount: 1)
        let speeds: [(Int64, Int64)] = [(2, 1), (1, 2), (3, 2), (5, 4)]

        for (numerator, denominator) in speeds {
            let speed = try RationalValue(numerator: numerator, denominator: denominator)
            let output = try WSOLATimeStretcher.stretch(
                samples: input,
                channelCount: 1,
                sampleRate: sampleRate,
                speed: speed
            )
            let expected = Double(input.count) * Double(denominator) / Double(numerator)

            XCTAssertEqual(
                output.count,
                try WSOLATimeStretcher.stretchedFrameCount(
                    frameCount: input.count,
                    speed: speed
                )
            )
            XCTAssertLessThanOrEqual(
                abs(Double(output.count) - expected),
                Double(hop),
                "speed \(numerator)/\(denominator)"
            )
        }
    }

    func testFRSPD001StretchIsBitExactlyRepeatableAcrossRuns() throws {
        let input = makeTestSignal(frameCount: 8_000, channelCount: 2)
        let speed = try RationalValue(numerator: 2, denominator: 1)

        let first = try WSOLATimeStretcher.stretch(
            samples: input,
            channelCount: 2,
            sampleRate: 8_000,
            speed: speed
        )
        let second = try WSOLATimeStretcher.stretch(
            samples: input,
            channelCount: 2,
            sampleRate: 8_000,
            speed: speed
        )

        XCTAssertEqual(first, second)
    }

    func testFRSPD001DoubleSpeedPreservesFundamentalWithinOneBin() throws {
        let sampleRate = 8_000
        let input = sineWave(frequency: 440, sampleRate: sampleRate, frameCount: 8_000)

        let output = try WSOLATimeStretcher.stretch(
            samples: input,
            channelCount: 1,
            sampleRate: sampleRate,
            speed: try RationalValue(numerator: 2, denominator: 1)
        )

        // 4_000 output frames at 8 kHz: 2 Hz bins. Varispeed would land the peak at 880 Hz.
        let peak = peakFrequency(
            samples: output,
            sampleRate: sampleRate,
            range: stride(from: 200.0, through: 1_600.0, by: 2.0)
        )
        XCTAssertEqual(peak, 440, accuracy: 2)
        XCTAssertGreaterThan(
            magnitude(samples: output, sampleRate: sampleRate, frequency: 440),
            10 * magnitude(samples: output, sampleRate: sampleRate, frequency: 880)
        )
    }

    func testFRSPD001HalfSpeedPreservesFundamentalWithinOneBin() throws {
        let sampleRate = 8_000
        let input = sineWave(frequency: 440, sampleRate: sampleRate, frameCount: 8_000)

        let output = try WSOLATimeStretcher.stretch(
            samples: input,
            channelCount: 1,
            sampleRate: sampleRate,
            speed: try RationalValue(numerator: 1, denominator: 2)
        )

        // 16_000 output frames at 8 kHz: 0.5 Hz bins. Varispeed would land the peak at 220 Hz.
        let peak = peakFrequency(
            samples: output,
            sampleRate: sampleRate,
            range: stride(from: 100.0, through: 1_600.0, by: 2.0)
        )
        XCTAssertEqual(peak, 440, accuracy: 2)
        XCTAssertGreaterThan(
            magnitude(samples: output, sampleRate: sampleRate, frequency: 440),
            10 * magnitude(samples: output, sampleRate: sampleRate, frequency: 220)
        )
    }

    func testFRSPD001SilenceStretchesToExactSilence() throws {
        let output = try WSOLATimeStretcher.stretch(
            samples: [Float](repeating: 0, count: 4_000),
            channelCount: 1,
            sampleRate: 8_000,
            speed: try RationalValue(numerator: 2, denominator: 1)
        )

        XCTAssertEqual(output, [Float](repeating: 0, count: 2_000))
    }

    func testFRSPD001TypedErrorsForInvalidInputs() {
        XCTAssertThrowsError(
            try WSOLATimeStretcher.stretch(
                samples: [0, 0, 0],
                channelCount: 2,
                sampleRate: 8_000,
                speed: .one
            )
        ) { error in
            XCTAssertEqual(
                error as? WSOLATimeStretchError,
                .sampleCountNotFrameAligned(sampleCount: 3, channelCount: 2)
            )
        }
        XCTAssertThrowsError(
            try WSOLATimeStretcher.stretch(
                samples: [0, 0],
                channelCount: 0,
                sampleRate: 8_000,
                speed: .one
            )
        ) { error in
            XCTAssertEqual(error as? WSOLATimeStretchError, .invalidChannelCount(0))
        }
        XCTAssertThrowsError(
            try WSOLATimeStretcher.stretch(
                samples: [0, 0],
                channelCount: 1,
                sampleRate: 0,
                speed: .one
            )
        ) { error in
            XCTAssertEqual(error as? WSOLATimeStretchError, .invalidSampleRate(0))
        }
        XCTAssertThrowsError(
            try WSOLATimeStretcher.stretch(
                samples: [0, 0],
                channelCount: 1,
                sampleRate: 8_000,
                speed: .zero
            )
        ) { error in
            XCTAssertEqual(error as? WSOLATimeStretchError, .nonPositiveSpeed(.zero))
        }
    }

    func testFRSPD001WorkingSetEstimateAccountsForEverySimultaneouslyLiveArray() throws {
        // 1,000 stereo input frames at 2x produce 500 output frames. At 2 kHz the
        // analysis window is 40 frames, so overlap-add retains 540 padded frames.
        // input Float: 8,000; mono Double: 8,000; Hann Double: 320;
        // OLA Double: 8,640; window sums Double: 4,320; output Float: 4,000.
        XCTAssertEqual(
            try WSOLATimeStretcher.estimatedWorkingSetByteCount(
                inputFrameCount: 1_000,
                channelCount: 2,
                sampleRate: 2_000,
                speed: try RationalValue(numerator: 2, denominator: 1)
            ),
            33_280
        )
    }

    func testFRSPD001WorkingSetLimitRefusesWithoutAllocatingTheClaimedInput() throws {
        let inputFrameCount = (WSOLATimeStretcher.maximumWorkingSetByteCount / 4) + 1

        XCTAssertThrowsError(
            try WSOLATimeStretcher.validateWorkingSet(
                inputFrameCount: inputFrameCount,
                channelCount: 1,
                sampleRate: 48_000,
                speed: .one
            )
        ) { error in
            XCTAssertEqual(
                error as? WSOLATimeStretchError,
                .workingSetLimitExceeded(
                    estimatedByteCount: WSOLATimeStretcher.maximumWorkingSetByteCount + 4,
                    maximumByteCount: WSOLATimeStretcher.maximumWorkingSetByteCount
                )
            )
        }
    }

    func testFRSPD001WorkingSetEstimateOverflowIsTyped() {
        XCTAssertThrowsError(
            try WSOLATimeStretcher.estimatedWorkingSetByteCount(
                inputFrameCount: Int.max,
                channelCount: 2,
                sampleRate: 48_000,
                speed: .one
            )
        ) { error in
            XCTAssertEqual(
                error as? WSOLATimeStretchError,
                .workingSetByteCountOverflow(
                    inputFrameCount: Int.max,
                    channelCount: 2,
                    speed: .one
                )
            )
        }
    }

    func testFRSPD001AnalysisWindowIs960FramesAt48kHz() {
        XCTAssertEqual(WSOLATimeStretcher.analysisWindowFrameCount(sampleRate: 48_000), 960)
        XCTAssertEqual(WSOLATimeStretcher.synthesisHopFrameCount(sampleRate: 48_000), 480)
    }
}

/// Deterministic multi-component test signal: two sines plus a slow ramp.
func makeTestSignal(frameCount: Int, channelCount: Int) -> [Float] {
    var samples = [Float](repeating: 0, count: frameCount * channelCount)
    for frame in 0..<frameCount {
        let phase = Double(frame) / 100
        let value = 0.4 * sin(2 * Double.pi * phase)
            + 0.2 * sin(2 * Double.pi * phase * 3.7)
            + 0.05 * Double(frame) / Double(frameCount)
        for channel in 0..<channelCount {
            let channelScale = 1 - (0.25 * Double(channel))
            samples[(frame * channelCount) + channel] = Float(value * channelScale)
        }
    }
    return samples
}

/// Mono sine wave at 0.5 amplitude.
func sineWave(frequency: Double, sampleRate: Int, frameCount: Int) -> [Float] {
    (0..<frameCount).map { frame in
        Float(0.5 * sin(2 * Double.pi * frequency * Double(frame) / Double(sampleRate)))
    }
}

/// Single-bin DFT magnitude (Goertzel-style direct evaluation), normalized by length.
func magnitude(samples: [Float], sampleRate: Int, frequency: Double) -> Double {
    var real = 0.0
    var imaginary = 0.0
    for (index, sample) in samples.enumerated() {
        let phase = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
        real += Double(sample) * cos(phase)
        imaginary -= Double(sample) * sin(phase)
    }
    return ((real * real) + (imaginary * imaginary)).squareRoot() / Double(samples.count)
}

/// The frequency in `range` with the largest DFT magnitude.
func peakFrequency(
    samples: [Float],
    sampleRate: Int,
    range: StrideThrough<Double>
) -> Double {
    var best = 0.0
    var bestMagnitude = -Double.infinity
    for frequency in range {
        let value = magnitude(samples: samples, sampleRate: sampleRate, frequency: frequency)
        if value > bestMagnitude {
            bestMagnitude = value
            best = frequency
        }
    }
    return best
}
