// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarAudio

final class AudioWaveformSummaryTests: XCTestCase {
    func testFRAUD002WaveformBinsStereoPeakRMSAndPartialFinalBin() throws {
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
            frameCount: 3,
            samples: [
                -1, 0,
                1, 2,
                0.5, -2
            ]
        )

        let summary = try AudioWaveformAnalyzer.summarize(source: source, framesPerBin: 2)

        XCTAssertEqual(summary.sampleRate, 4)
        XCTAssertEqual(summary.channelCount, 2)
        XCTAssertEqual(summary.sourceFrameCount, 3)
        XCTAssertEqual(summary.framesPerBin, 2)
        XCTAssertEqual(summary.binCount, 2)
        XCTAssertEqual(summary.channels.map(\.channelIndex), [0, 1])

        assertBin(
            try XCTUnwrap(summary.channels.first?.bins.first),
            minimum: -1,
            maximum: 1,
            rms: 1,
            frameCount: 2
        )
        assertBin(
            try XCTUnwrap(summary.channels.first?.bins.dropFirst().first),
            minimum: 0.5,
            maximum: 0.5,
            rms: 0.5,
            frameCount: 1
        )
        assertBin(
            try XCTUnwrap(summary.channels.dropFirst().first?.bins.first),
            minimum: 0,
            maximum: 2,
            rms: Float(2.0.squareRoot()),
            frameCount: 2
        )
        assertBin(
            try XCTUnwrap(summary.channels.dropFirst().first?.bins.dropFirst().first),
            minimum: -2,
            maximum: -2,
            rms: 2,
            frameCount: 1
        )
    }

    func testFRAUD002WaveformSilenceProducesZeroBins() throws {
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
            frameCount: 3,
            samples: [0, 0, 0]
        )

        let summary = try AudioWaveformAnalyzer.summarize(source: source, framesPerBin: 2)

        XCTAssertEqual(summary.binCount, 2)
        for bin in try XCTUnwrap(summary.channels.first).bins {
            assertBin(bin, minimum: 0, maximum: 0, rms: 0, frameCount: bin.frameCount)
        }
    }

    func testFRAUD002WaveformFullScaleTonePeaksAndRMS() throws {
        let rootHalf = Float(0.7071067811865476)
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 8, channelCount: 1),
            frameCount: 8,
            samples: [0, rootHalf, 1, rootHalf, 0, -rootHalf, -1, -rootHalf]
        )

        let summary = try AudioWaveformAnalyzer.summarize(source: source, framesPerBin: 8)
        let bin = try XCTUnwrap(summary.channels.first?.bins.first)

        assertBin(
            bin,
            minimum: -1,
            maximum: 1,
            rms: Float(0.5.squareRoot()),
            frameCount: 8
        )
    }

    func testFRAUD002WaveformBinsPerSecondUsesDeterministicFramesPerBin() throws {
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
            frameCount: 4,
            samples: [1, 2, 3, 4]
        )

        let summary = try AudioWaveformAnalyzer.summarize(source: source, binsPerSecond: 2)

        XCTAssertEqual(summary.framesPerBin, 2)
        XCTAssertEqual(summary.binCount, 2)
        assertBin(
            try XCTUnwrap(summary.channels.first?.bins.first),
            minimum: 1,
            maximum: 2,
            rms: Float(2.5.squareRoot()),
            frameCount: 2
        )
    }

    func testFRAUD002WaveformGenerationIsDeterministicAndCodable() throws {
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
            frameCount: 2,
            samples: [-1, 1]
        )

        let first = try AudioWaveformAnalyzer.summarize(source: source, framesPerBin: 2)
        let second = try AudioWaveformAnalyzer.summarize(source: source, framesPerBin: 2)
        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(AudioWaveformSummary.self, from: encoded)

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded, first)
    }

    func testFRAUD002WaveformRejectsInvalidResolutionWithTypedErrors() throws {
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
            frameCount: 1,
            samples: [1]
        )

        XCTAssertThrowsError(
            try AudioWaveformAnalyzer.summarize(source: source, framesPerBin: 0)
        ) { error in
            XCTAssertEqual(error as? AudioWaveformError, .invalidFramesPerBin(0))
        }

        XCTAssertThrowsError(
            try AudioWaveformAnalyzer.summarize(source: source, binsPerSecond: 0)
        ) { error in
            XCTAssertEqual(error as? AudioWaveformError, .invalidBinsPerSecond(0))
        }
    }
}

private func assertBin(
    _ bin: AudioWaveformBin,
    minimum: Float,
    maximum: Float,
    rms: Float,
    frameCount: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(bin.minimum, minimum, accuracy: 0.00001, file: file, line: line)
    XCTAssertEqual(bin.maximum, maximum, accuracy: 0.00001, file: file, line: line)
    XCTAssertEqual(bin.rms, rms, accuracy: 0.00001, file: file, line: line)
    XCTAssertEqual(bin.frameCount, frameCount, file: file, line: line)
}
