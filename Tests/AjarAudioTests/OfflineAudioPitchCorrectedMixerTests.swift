// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// FR-SPD-001 offline-mixer coverage for pitch-corrected constant-speed clips.
final class OfflineAudioPitchCorrectedMixerTests: XCTestCase {
    private let sampleRate = 2_000

    func testFRSPD001PitchCorrectedDoubleSpeedKeepsFundamentalWhereVarispeedDoublesIt() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000086001")
        let source = sineWave(frequency: 200, sampleRate: sampleRate, frameCount: sampleRate)

        let corrected = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: try RationalValue(numerator: 2, denominator: 1),
            retimeMode: .pitchCorrected
        )
        let varispeed = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: try RationalValue(numerator: 2, denominator: 1),
            retimeMode: .pitchShifted
        )

        let correctedMono = channelSamples(corrected, channel: 0)
        let varispeedMono = channelSamples(varispeed, channel: 0)
        // Pitch-corrected keeps 200 Hz dominant; varispeed doubles it to 400 Hz.
        XCTAssertGreaterThan(
            magnitude(samples: correctedMono, sampleRate: sampleRate, frequency: 200),
            10 * magnitude(samples: correctedMono, sampleRate: sampleRate, frequency: 400)
        )
        XCTAssertGreaterThan(
            magnitude(samples: varispeedMono, sampleRate: sampleRate, frequency: 400),
            10 * magnitude(samples: varispeedMono, sampleRate: sampleRate, frequency: 200)
        )
    }

    func testFRSPD001PitchCorrectedUnitSpeedIsBitIdenticalToVarispeed() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000086002")
        let source = makeTestSignal(frameCount: sampleRate, channelCount: 1)

        let corrected = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: .one,
            retimeMode: .pitchCorrected
        )
        let varispeed = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: .one,
            retimeMode: .pitchShifted
        )

        // Frame-aligned unit speed must be the exact identity in both modes.
        XCTAssertEqual(corrected.samples, varispeed.samples)
    }

    func testFRSPD001PitchCorrectedRenderIsBitExactlyRepeatable() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000086003")
        let source = sineWave(frequency: 200, sampleRate: sampleRate, frameCount: sampleRate)
        let speed = try RationalValue(numerator: 2, denominator: 1)

        let first = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: speed,
            retimeMode: .pitchCorrected
        )
        let second = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: speed,
            retimeMode: .pitchCorrected
        )

        XCTAssertEqual(first.samples, second.samples)
    }

    func testFRSPD001ReversePitchCorrectedUnitSpeedPlaysReversedSource() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000086004")
        let source: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]

        let corrected = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: .one,
            retimeMode: .pitchCorrected,
            reverse: true,
            sourceDurationFrames: 8,
            renderFrames: 8
        )
        let varispeed = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: .one,
            retimeMode: .pitchShifted,
            reverse: true,
            sourceDurationFrames: 8,
            renderFrames: 8
        )

        // WSOLA applies to the reversed source stream (FR-SPD-003 composes with FR-SPD-001).
        XCTAssertEqual(
            channelSamples(corrected, channel: 0),
            [8, 7, 6, 5, 4, 3, 2, 1]
        )
        XCTAssertEqual(corrected.samples, varispeed.samples)
    }

    func testFRSPD001ReversePitchCorrectedDoubleSpeedKeepsFundamental() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000086005")
        let source = sineWave(frequency: 200, sampleRate: sampleRate, frameCount: sampleRate)

        let corrected = try renderRetimed(
            mediaID: mediaID,
            sourceSamples: source,
            speed: try RationalValue(numerator: 2, denominator: 1),
            retimeMode: .pitchCorrected,
            reverse: true
        )

        let mono = channelSamples(corrected, channel: 0)
        XCTAssertGreaterThan(
            magnitude(samples: mono, sampleRate: sampleRate, frequency: 200),
            10 * magnitude(samples: mono, sampleRate: sampleRate, frequency: 400)
        )
    }

    func testFRSPD001PitchCorrectedFreezeFrameFailsWithTypedError() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000086006")
        let clipID = try uuid("00000000-0000-0000-0000-000000086007")
        let clip = try makeRetimedClip(
            id: clipID,
            mediaID: mediaID,
            speed: .one,
            retimeMode: .pitchCorrected,
            freezeFrame: true,
            sourceDurationFrames: sampleRate,
            sampleRate: sampleRate
        )

        XCTAssertThrowsError(
            try renderSequence(
                clips: [clip],
                sources: [mediaID: try monoSource(
                    sineWave(frequency: 200, sampleRate: sampleRate, frameCount: sampleRate),
                    sampleRate: sampleRate
                )],
                renderFrames: sampleRate
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .pitchCorrectedRetimeUnsupported(clipID: clipID)
            )
        }
    }

    func testFRSPD001PitchCorrectedCrossfadeTailIsExactInStretchedDomain() throws {
        // ADR-0015: the trailing crossfade tail of a pitch-corrected clip reads the same
        // stretched stream 1:1 past the out-point, so the tail is exact in the stretched
        // domain rather than rejected or silently varispeed.
        let tailRate = 1_000
        // 1.2 s of source: 1 s clip body plus the 2 x 0.1 s source image of the tail at 2x.
        let source = sineWave(frequency: 100, sampleRate: tailRate, frameCount: 1_200)
        let pair = try makeCrossfadePair(source: source, tailRate: tailRate)

        let rendered = try renderSequence(
            clips: pair.clips,
            sources: pair.sources,
            renderFrames: 1_000,
            sampleRate: tailRate
        )

        // Oracle: stretch the effective window (1.2 s) by 2x and apply the linear tail gain.
        let stretched = try WSOLATimeStretcher.stretch(
            samples: source,
            channelCount: 1,
            sampleRate: tailRate,
            speed: try RationalValue(numerator: 2, denominator: 1)
        )
        let mono = channelSamples(rendered, channel: 0)
        for frame in 0..<500 {
            XCTAssertEqual(mono[frame], stretched[frame], accuracy: 1e-6, "body frame \(frame)")
        }
        for tailFrame in 0..<100 {
            let gain = 1 - (Double(tailFrame) / 100)
            let expected = stretched[500 + tailFrame] * Float(gain)
            XCTAssertEqual(
                mono[500 + tailFrame],
                expected,
                accuracy: 1e-6,
                "tail frame \(tailFrame)"
            )
        }
        // The tail is audibly present, not silence.
        XCTAssertGreaterThan(
            mono[500..<540].map { abs($0) }.max() ?? 0,
            0.1
        )
    }

    func testFRSPD001NonDivisibleSpeedLastTimelineFrameIsNotSilent() throws {
        // 1000 source frames at 3x span 333.33 timeline frames; the mixer renders half-open
        // ranges with ceiling semantics (frames 0...333), so the stretched buffer must use
        // ceil(1000/3) = 334 frames — nearest rounding would leave frame 333 silent.
        let rate = 1_000
        let mediaID = try uuid("00000000-0000-0000-0000-000000086012")
        let source = [Float](repeating: 0.5, count: rate)
        let clip = try makeRetimedClip(
            id: try uuid("00000000-0000-0000-0000-000000086013"),
            mediaID: mediaID,
            speed: try RationalValue(numerator: 3, denominator: 1),
            retimeMode: .pitchCorrected,
            sourceDurationFrames: rate,
            sampleRate: rate
        )

        let rendered = try renderSequence(
            clips: [clip],
            sources: [mediaID: try monoSource(source, sampleRate: rate)],
            renderFrames: 334,
            sampleRate: rate
        )

        let mono = channelSamples(rendered, channel: 0)
        XCTAssertEqual(mono.count, 334)
        XCTAssertEqual(mono[1], 0.5, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(mono[333]), 0.4, "last timeline frame must not read silence")
        XCTAssertEqual(
            try WSOLATimeStretcher.stretchedFrameCount(
                frameCount: 1_000,
                speed: try RationalValue(numerator: 3, denominator: 1)
            ),
            334
        )
    }

    func testFRSPD001FractionalSourceStartUnitSpeedIsBitIdenticalToVarispeed() throws {
        // A source range starting on a fractional sample (100.5 frames): unit-speed
        // pitch-corrected playback must be bit-identical to varispeed, crossfade tail
        // included — extraction floors the window start and the read path re-applies the
        // exact varispeed source-time mapping shifted by the integer extraction start.
        let rate = 1_000
        let source = makeTestSignal(frameCount: 1_300, channelCount: 1)

        let correctedPair = try makeFractionalStartPair(
            retimeMode: .pitchCorrected,
            source: source,
            rate: rate
        )
        let varispeedPair = try makeFractionalStartPair(
            retimeMode: .pitchShifted,
            source: source,
            rate: rate
        )
        let corrected = try renderSequence(
            clips: correctedPair.clips,
            sources: correctedPair.sources,
            renderFrames: 1_100,
            sampleRate: rate
        )
        let varispeed = try renderSequence(
            clips: varispeedPair.clips,
            sources: varispeedPair.sources,
            renderFrames: 1_100,
            sampleRate: rate
        )

        XCTAssertEqual(corrected.samples, varispeed.samples)
    }

    func testFRSPD001DuplicateClipIDsGetIndependentStretches() throws {
        // Duplicate clip IDs are legal (compound decompose can emit the same inner clip IDs
        // twice), so the stretch cache must key on the actual stretch inputs: two same-ID
        // clips with different speeds in one render get independent, correct audio.
        let rate = 1_000
        let mediaID = try uuid("00000000-0000-0000-0000-000000086014")
        let sharedClipID = try uuid("00000000-0000-0000-0000-000000086015")
        let source = makeTestSignal(frameCount: rate, channelCount: 1)
        let unitClip = try makeRetimedClip(
            id: sharedClipID,
            mediaID: mediaID,
            speed: .one,
            retimeMode: .pitchCorrected,
            sourceDurationFrames: rate,
            sampleRate: rate
        )
        let doubleClip = try makeRetimedClip(
            id: sharedClipID,
            mediaID: mediaID,
            speed: try RationalValue(numerator: 2, denominator: 1),
            retimeMode: .pitchCorrected,
            timelineStartFrames: Int64(rate),
            sourceDurationFrames: rate,
            sampleRate: rate
        )

        let rendered = try renderSequence(
            clips: [unitClip, doubleClip],
            sources: [mediaID: try monoSource(source, sampleRate: rate)],
            renderFrames: 1_500,
            sampleRate: rate
        )

        let mono = channelSamples(rendered, channel: 0)
        let oracle = try WSOLATimeStretcher.stretch(
            samples: source,
            channelCount: 1,
            sampleRate: rate,
            speed: try RationalValue(numerator: 2, denominator: 1)
        )
        // Unit-speed region plays the source verbatim; the 2x region plays its own stretch,
        // never the cached unit-speed buffer of the same-ID clip.
        XCTAssertEqual(Array(mono[0..<1_000]), source)
        XCTAssertEqual(Array(mono[1_000..<1_500]), Array(oracle[0..<500]))
    }
}

private extension OfflineAudioPitchCorrectedMixerTests {
    func renderRetimed(
        mediaID: UUID,
        sourceSamples: [Float],
        speed: RationalValue,
        retimeMode: ClipAudioRetimeMode,
        reverse: Bool = false,
        sourceDurationFrames: Int? = nil,
        renderFrames: Int? = nil
    ) throws -> RenderedAudioBuffer {
        let sourceFrames = sourceDurationFrames ?? sourceSamples.count
        let clip = try makeRetimedClip(
            id: try uuid("00000000-0000-0000-0000-000000086100"),
            mediaID: mediaID,
            speed: speed,
            retimeMode: retimeMode,
            reverse: reverse,
            sourceDurationFrames: sourceFrames,
            sampleRate: sampleRate
        )
        let outputFrames = renderFrames
            ?? Int((Int64(sourceFrames) * speed.denominator) / speed.numerator)
        return try renderSequence(
            clips: [clip],
            sources: [mediaID: try monoSource(sourceSamples, sampleRate: sampleRate)],
            renderFrames: outputFrames
        )
    }

    func renderSequence(
        clips: [Clip],
        sources: [UUID: AudioSourceBuffer],
        renderFrames: Int,
        sampleRate: Int? = nil
    ) throws -> RenderedAudioBuffer {
        let rate = sampleRate ?? self.sampleRate
        let sequence = Sequence(
            id: try uuid("00000000-0000-0000-0000-000000086200"),
            name: "Pitch Corrected Mix",
            videoTracks: [],
            audioTracks: [try makeTrack(items: clips.map { .clip($0) })],
            markers: [],
            timebase: try FrameRate(frames: Int64(rate))
        )
        return try OfflineAudioMixer.render(
            sequence: sequence,
            range: TimeRange(
                start: .zero,
                duration: try time(Int64(renderFrames), Int64(rate))
            ),
            format: AudioRenderFormat(sampleRate: rate, channelCount: 2),
            sourceProvider: InMemoryAudioSourceProvider(sources: sources)
        )
    }

    func channelSamples(_ buffer: RenderedAudioBuffer, channel: Int) -> [Float] {
        stride(
            from: channel,
            to: buffer.samples.count,
            by: buffer.format.channelCount
        ).map { buffer.samples[$0] }
    }
}
