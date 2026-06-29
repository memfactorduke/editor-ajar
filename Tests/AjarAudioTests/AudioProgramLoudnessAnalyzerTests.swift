// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class AudioProgramLoudnessAnalyzerTests: XCTestCase {
    func testFRAUD003BS1770IntegratedLoudnessMatchesFullScaleMonoTone() throws {
        let buffer = try renderedSineBuffer(channelCount: 1)

        let report = try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)

        // ITU-R BS.1770-4 K-weighting plus the -0.691 LKFS offset puts a full-scale 1 kHz
        // mono sine near -3.0036 LUFS when the RLB numerator remains [1, -2, 1].
        XCTAssertEqual(try XCTUnwrap(report.integratedLUFS), -3.0036, accuracy: 0.01)
        XCTAssertEqual(report.blockCount, 7)
        XCTAssertEqual(report.gatedBlockCount, 7)
        XCTAssertFalse(report.isGatedToSilence)
        XCTAssertEqual(report.truePeakOversamplingFactor, 4)
    }

    func testFRAUD003BS1770StereoToneUsesLeftRightChannelWeights() throws {
        let buffer = try renderedSineBuffer(channelCount: 2)

        let report = try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)

        // Stereo L/R weights are both 1.0 in BS.1770, so dual-mono is +3.0103 LU over mono.
        XCTAssertEqual(try XCTUnwrap(report.integratedLUFS), 0.0067, accuracy: 0.01)
        XCTAssertEqual(report.channelCount, 2)
        XCTAssertEqual(report.gatedBlockCount, 7)
    }

    func testFRAUD003SilenceUsesExplicitGatedToSilenceSentinel() throws {
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: 2),
            frameCount: loudnessSampleRate,
            samples: [Float](repeating: 0, count: loudnessSampleRate * 2)
        )

        let report = try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)

        XCTAssertNil(report.integratedLUFS)
        XCTAssertTrue(report.isGatedToSilence)
        XCTAssertEqual(report.blockCount, 7)
        XCTAssertEqual(report.gatedBlockCount, 0)
        XCTAssertEqual(report.truePeak, 0)
        XCTAssertNil(report.truePeakDBTP)
    }

    func testFRAUD003TruePeakDetectsInterSamplePeakAboveSamplePeak() throws {
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: 1),
            frameCount: 4,
            samples: [1, 1, -1, -1]
        )

        let report = try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)

        // BS.1770 true peak is an oversampled inter-sample estimate; this synthetic transition
        // has a 0 dBFS sample peak but reconstructs above full scale between samples.
        XCTAssertGreaterThan(report.truePeak, 1)
        XCTAssertEqual(
            try XCTUnwrap(report.truePeakDBTP),
            try XCTUnwrap(AudioMeterChannelLevel.dbFS(for: report.truePeak)),
            accuracy: 0.000_001
        )
        XCTAssertNil(report.integratedLUFS)
    }

    func testFRAUD003TruePeakMatchesKnownMidSampleSinePeak() throws {
        let frameCount = 4_800
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: 1),
            frameCount: frameCount,
            samples: quarterSampleRateSineSamples(frameCount: frameCount, amplitude: knownTruePeak)
        )

        let report = try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)

        // A quarter-sample-rate sine shifted by pi/4 has samples [1, 1, -1, -1] while its
        // band-limited continuous peak is sqrt(2), or +3.0103 dBTP.
        XCTAssertEqual(report.truePeak, knownTruePeak, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(report.truePeakDBTP), 3.0103, accuracy: 0.1)
    }

    func testFRAUD003TruePeakUsesMaximumAcrossStereoChannels() throws {
        let frameCount = 4_800
        let left = quarterSampleRateSineSamples(frameCount: frameCount, amplitude: 0.75)
        let right = quarterSampleRateSineSamples(frameCount: frameCount, amplitude: knownTruePeak)
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: 2),
            frameCount: frameCount,
            samples: interleaveStereo(left: left, right: right)
        )

        let report = try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)

        XCTAssertEqual(report.truePeak, knownTruePeak, accuracy: 0.02)
        XCTAssertGreaterThan(report.truePeak, 1)
    }

    func testFRAUD003ProgramLoudnessRendersSequenceDeterministicallyAndCodable() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000111001")
        let sequence = try makeSequence(items: [
            .clip(try makeClip(mediaID: mediaID, duration: time(1, 1)))
        ])
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: 1),
            frameCount: loudnessSampleRate,
            samples: sineSamples(channelCount: 1)
        )
        let provider = InMemoryAudioSourceProvider(sources: [mediaID: source])
        let range = try TimeRange(start: .zero, duration: time(1, 1))

        let first = try AudioMixerMeterAnalyzer.measureProgramLoudness(
            sequence: sequence,
            range: range,
            format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: 2),
            sourceProvider: provider
        )
        let second = try AudioMixerMeterAnalyzer.measureProgramLoudness(
            sequence: sequence,
            range: range,
            format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: 2),
            sourceProvider: provider
        )
        let decoded = try JSONDecoder().decode(
            AudioProgramLoudnessReport.self,
            from: try JSONEncoder().encode(first)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(try XCTUnwrap(first.integratedLUFS), 0.0067, accuracy: 0.01)
    }

    func testFRAUD003ProgramLoudnessRejectsInvalidSampleRateWithTypedError() throws {
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
            frameCount: 4,
            samples: [0, 0, 0, 0]
        )

        XCTAssertThrowsError(
            try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)
        ) { error in
            XCTAssertEqual(error as? AudioProgramLoudnessError, .invalidSampleRate(4))
        }
    }

    func testFRAUD003ProgramLoudnessRejectsSurroundUntilLayoutWeightsExist() throws {
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: 6),
            frameCount: 2,
            samples: [Float](repeating: 0, count: 12)
        )

        XCTAssertThrowsError(
            try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)
        ) { error in
            XCTAssertEqual(error as? AudioProgramLoudnessError, .unsupportedChannelCount(6))
        }
    }
}

private let loudnessSampleRate = 48_000
private let loudnessToneFrequency = 1_000.0
private let knownTruePeak = sqrt(2.0)

private func renderedSineBuffer(channelCount: Int) throws -> RenderedAudioBuffer {
    try RenderedAudioBuffer(
        format: AudioRenderFormat(sampleRate: loudnessSampleRate, channelCount: channelCount),
        frameCount: loudnessSampleRate,
        samples: sineSamples(channelCount: channelCount)
    )
}

private func sineSamples(channelCount: Int) -> [Float] {
    let frameCount = loudnessSampleRate
    var samples: [Float] = []
    samples.reserveCapacity(frameCount * channelCount)
    for frame in 0..<frameCount {
        let phase = (2 * Double.pi * loudnessToneFrequency * Double(frame))
            / Double(loudnessSampleRate)
        let sample = Float(sin(phase))
        for _ in 0..<channelCount {
            samples.append(sample)
        }
    }
    return samples
}

private func quarterSampleRateSineSamples(frameCount: Int, amplitude: Double) -> [Float] {
    (0..<frameCount).map { frame in
        let phase = ((Double.pi / 2) * Double(frame)) + (Double.pi / 4)
        return Float(amplitude * sin(phase))
    }
}

private func interleaveStereo(left: [Float], right: [Float]) -> [Float] {
    var samples: [Float] = []
    samples.reserveCapacity(left.count * 2)
    for index in left.indices {
        samples.append(left[index])
        samples.append(right[index])
    }
    return samples
}
