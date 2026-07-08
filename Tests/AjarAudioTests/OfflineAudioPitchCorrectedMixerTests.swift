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

private struct CrossfadePairFixture {
    let clips: [Clip]
    let sources: [UUID: AudioSourceBuffer]
}

/// One pitch-corrected 2x clip with a 0.1 s linear trailing crossfade into an abutting
/// silent clip carrying the mirroring leading record (ADR-0015 pair taxonomy).
private func makeCrossfadePair(
    source: [Float],
    tailRate: Int
) throws -> CrossfadePairFixture {
    let mediaID = try uuid("00000000-0000-0000-0000-000000086008")
    let silentID = try uuid("00000000-0000-0000-0000-000000086009")
    let clipAID = try uuid("00000000-0000-0000-0000-000000086010")
    let clipBID = try uuid("00000000-0000-0000-0000-000000086011")
    let crossfadeDuration = try time(1, 10)
    let crossfade = ClipAudioCrossfade(
        partnerClipID: clipBID,
        duration: crossfadeDuration,
        curve: .linear
    )
    let mirror = ClipAudioCrossfade(
        partnerClipID: clipAID,
        duration: crossfadeDuration,
        curve: .linear
    )
    let clipA = try makeRetimedClip(
        id: clipAID,
        mediaID: mediaID,
        speed: try RationalValue(numerator: 2, denominator: 1),
        retimeMode: .pitchCorrected,
        sourceDurationFrames: tailRate,
        sampleRate: tailRate,
        audioMix: ClipAudioMix(trailingCrossfade: crossfade, retimeMode: .pitchCorrected)
    )
    let clipB = try makeRetimedClip(
        id: clipBID,
        mediaID: silentID,
        speed: .one,
        retimeMode: .pitchShifted,
        timelineStartFrames: 500,
        sourceDurationFrames: 400,
        sampleRate: tailRate,
        audioMix: ClipAudioMix(leadingCrossfade: mirror)
    )
    return CrossfadePairFixture(
        clips: [clipA, clipB],
        sources: [
            mediaID: try monoSource(source, sampleRate: tailRate),
            silentID: try monoSource([Float](repeating: 0, count: 400), sampleRate: tailRate)
        ]
    )
}

private func makeRetimedClip(
    id: UUID,
    mediaID: UUID,
    speed: RationalValue,
    retimeMode: ClipAudioRetimeMode,
    reverse: Bool = false,
    freezeFrame: Bool = false,
    timelineStartFrames: Int64 = 0,
    sourceDurationFrames: Int,
    sampleRate: Int = 2_000,
    audioMix: ClipAudioMix? = nil
) throws -> Clip {
    let rate = Int64(sampleRate)
    let sourceDuration = try time(Int64(sourceDurationFrames), rate)
    let timelineDuration = freezeFrame
        ? sourceDuration
        : try Clip.timelineDuration(forSourceDuration: sourceDuration, speed: speed)
    return Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: sourceDuration),
        timelineRange: try TimeRange(
            start: try time(timelineStartFrames, rate),
            duration: timelineDuration
        ),
        kind: .audio,
        name: "Retimed Audio",
        audioMix: audioMix ?? ClipAudioMix(retimeMode: retimeMode),
        speed: speed,
        reverse: reverse,
        freezeFrame: freezeFrame
    )
}

private func monoSource(_ samples: [Float], sampleRate: Int) throws -> AudioSourceBuffer {
    try AudioSourceBuffer(
        format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
        frameCount: samples.count,
        samples: samples
    )
}
