// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class AudioProgramLoudnessAnalyzerTests: XCTestCase {
    func testFRAUD003BS1770IntegratedLoudnessMatchesFullScaleMonoTone() throws {
        let buffer = try renderedSineBuffer(channelCount: 1)

        let report = try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)

        // ITU-R BS.1770 K-weighting plus the -0.691 LKFS offset puts a full-scale 1 kHz
        // mono sine near -3.05 LUFS with the documented 48 kHz coefficient set.
        XCTAssertEqual(try XCTUnwrap(report.integratedLUFS), -3.04688, accuracy: 0.01)
        XCTAssertEqual(report.blockCount, 7)
        XCTAssertEqual(report.gatedBlockCount, 7)
        XCTAssertFalse(report.isGatedToSilence)
        XCTAssertEqual(report.truePeakOversamplingFactor, 4)
    }

    func testFRAUD003BS1770StereoToneUsesLeftRightChannelWeights() throws {
        let buffer = try renderedSineBuffer(channelCount: 2)

        let report = try AudioMixerMeterAnalyzer.measureProgramLoudness(buffer: buffer)

        // Stereo L/R weights are both 1.0 in BS.1770, so dual-mono is +3.0103 LU over mono.
        XCTAssertEqual(try XCTUnwrap(report.integratedLUFS), -0.03658, accuracy: 0.01)
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
        XCTAssertEqual(report.truePeak, 1.35811, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(report.truePeakDBTP), 2.65873, accuracy: 0.0001)
        XCTAssertNil(report.integratedLUFS)
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
        XCTAssertEqual(try XCTUnwrap(first.integratedLUFS), -0.03658, accuracy: 0.01)
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
}

private let loudnessSampleRate = 48_000
private let loudnessToneFrequency = 1_000.0

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
