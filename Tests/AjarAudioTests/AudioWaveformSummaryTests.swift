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

    func testFRAUD002ChunkedWaveformMatchesMonolithicAcrossPartialBins() throws {
        let format = AudioRenderFormat(sampleRate: 44_100, channelCount: 2)
        let frameOffset = 10_000
        let frameCount = 13
        let samples = (0..<(frameCount * format.channelCount)).map { index in
            Float((index % 11) - 5) / 5
        }
        let source = try AudioSourceBuffer(
            format: format,
            frameCount: frameCount,
            samples: samples,
            frameOffset: frameOffset
        )
        let monolithic = try AudioWaveformAnalyzer.summarize(
            source: source,
            framesPerBin: 4
        )
        var chunked = try AudioWaveformAccumulator(format: format, framesPerBin: 4)

        try chunked.append(sourceChunk(source, localFrames: 0..<3))
        try chunked.append(sourceChunk(source, localFrames: 3..<8))
        try chunked.append(sourceChunk(source, localFrames: 8..<13))

        XCTAssertEqual(chunked.makeSummary(), monolithic)
    }

    func testNFRSTAB001ChunkedWaveformRejectsFormatChangesAndFrameGaps() throws {
        let format = AudioRenderFormat(sampleRate: 48_000, channelCount: 1)
        let first = try AudioSourceBuffer(
            format: format,
            frameCount: 2,
            samples: [0, 1],
            frameOffset: 20
        )
        var formatAccumulator = try AudioWaveformAccumulator(
            format: format,
            framesPerBin: 2
        )
        try formatAccumulator.append(first)
        let changedFormat = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 44_100, channelCount: 1),
            frameCount: 1,
            samples: [0],
            frameOffset: 22
        )
        XCTAssertThrowsError(try formatAccumulator.append(changedFormat)) { error in
            XCTAssertEqual(
                error as? AudioWaveformError,
                .inconsistentSourceFormat(
                    expectedSampleRate: 48_000,
                    expectedChannelCount: 1,
                    actualSampleRate: 44_100,
                    actualChannelCount: 1
                )
            )
        }

        var gapAccumulator = try AudioWaveformAccumulator(format: format, framesPerBin: 2)
        try gapAccumulator.append(first)
        let gapped = try AudioSourceBuffer(
            format: format,
            frameCount: 1,
            samples: [0],
            frameOffset: 23
        )
        XCTAssertThrowsError(try gapAccumulator.append(gapped)) { error in
            XCTAssertEqual(
                error as? AudioWaveformError,
                .nonContiguousSourceFrames(expectedFrameOffset: 22, actualFrameOffset: 23)
            )
        }
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

private func sourceChunk(
    _ source: AudioSourceBuffer,
    localFrames: Range<Int>
) throws -> AudioSourceBuffer {
    let channelCount = source.format.channelCount
    let sampleStart = localFrames.lowerBound * channelCount
    let sampleEnd = localFrames.upperBound * channelCount
    return try AudioSourceBuffer(
        format: source.format,
        frameCount: localFrames.count,
        samples: Array(source.samples[sampleStart..<sampleEnd]),
        frameOffset: source.frameOffset + localFrames.lowerBound
    )
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
