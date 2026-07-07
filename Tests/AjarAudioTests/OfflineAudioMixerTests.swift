// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class OfflineAudioMixerTests: XCTestCase {
    func testFRAUD003MixesGainPanFadeAndClampsOvershootingAutomation() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085001")
        let clip = try makeClip(
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                gain: overshootingGain(),
                pan: .constant(RationalValue(2)),
                fadeIn: ClipAudioFade(duration: time(1, 2))
            )
        )
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [1, 1, 1, 1],
            sourceSampleRate: 4
        )

        assertSamples(buffer.samples, equal: [0, 0, 0, 2, 0, 4, 0, 4])
    }

    func testFRAUD009ResamplesAndMapsMonoSourceToStereoOutput() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085002")
        let clip = try makeClip(mediaID: mediaID, duration: time(1, 1))
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [0, 1],
            sourceSampleRate: 2
        )

        assertSamples(buffer.samples, equal: [0, 0, 0.5, 0.5, 1, 1, 1, 1])
    }

    func testFRSPD001ClipSpeedRetimesAudioSourceSamples() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085003")
        let fastClip = try makeClip(mediaID: mediaID, duration: time(1, 1), speed: RationalValue(2))
        let fastBuffer = try render(
            clip: fastClip,
            mediaID: mediaID,
            sourceSamples: [0, 1, 2, 3],
            sourceSampleRate: 4
        )

        assertSamples(fastBuffer.samples, equal: [0, 0, 2, 2, 0, 0, 0, 0])

        let slowClip = try makeClip(
            mediaID: mediaID,
            duration: time(1, 1),
            speed: try RationalValue(numerator: 1, denominator: 2)
        )
        let slowBuffer = try render(
            clip: slowClip,
            mediaID: mediaID,
            sourceSamples: [0, 1, 2, 3],
            sourceSampleRate: 4
        )

        assertSamples(slowBuffer.samples, equal: [0, 0, 0.5, 0.5, 1, 1, 1.5, 1.5])
    }

    func testFRSPD003ReverseClipRetimesAudioSourceSamplesBackward() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085004")
        let clip = try makeClip(
            mediaID: mediaID,
            duration: time(1, 1),
            reverse: true
        )
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [0, 1, 2, 3],
            sourceSampleRate: 4
        )

        assertSamples(buffer.samples, equal: [3, 3, 2, 2, 1, 1, 0, 0])
    }

    func testFRSPD003ReverseClipComposesWithSpeedForAudio() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085005")
        let clip = try makeClip(
            mediaID: mediaID,
            duration: time(1, 1),
            speed: RationalValue(2),
            reverse: true
        )
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [0, 1, 2, 3],
            sourceSampleRate: 4
        )

        assertSamples(buffer.samples, equal: [3, 3, 1, 1, 0, 0, 0, 0])
    }

    func testFRSPD003FreezeFrameAudioSustainsSourceStartSample() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085006")
        let clip = try makeClip(
            mediaID: mediaID,
            sourceStart: time(1, 4),
            duration: time(1, 2),
            freezeFrame: true
        )
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [0, 1, 2, 3],
            sourceSampleRate: 4
        )

        assertSamples(buffer.samples, equal: [1, 1, 1, 1, 0, 0, 0, 0])
    }

    func testCrossfadePartnerMustBeRealAdjacentClip() throws {
        let firstClipID = try uuid("00000000-0000-0000-0000-000000085101")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000085102")
        let mediaID = try uuid("00000000-0000-0000-0000-000000085103")
        let firstClip = try makeClip(id: firstClipID, mediaID: mediaID, duration: time(1, 1))
        let secondClip = try makeClip(
            id: secondClipID,
            mediaID: mediaID,
            timelineStart: time(2, 1),
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: firstClipID,
                    duration: time(1, 2)
                )
            )
        )
        let sequence = try makeSequence(items: [.clip(firstClip), .clip(secondClip)])

        XCTAssertThrowsError(
            try OfflineAudioMixer.render(
                sequence: sequence,
                range: TimeRange(start: .zero, duration: time(3, 1)),
                format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
                sourceProvider: InMemoryAudioSourceProvider(sources: [:])
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .crossfadePartnerNotAdjacent(
                    edge: .leadingCrossfade,
                    clipID: secondClipID,
                    partnerClipID: firstClipID
                )
            )
        }
    }

    func testCrossfadePartnerMustExistOnOwningTrack() throws {
        let clipID = try uuid("00000000-0000-0000-0000-000000085201")
        let mediaID = try uuid("00000000-0000-0000-0000-000000085202")
        let missingPartnerID = try uuid("00000000-0000-0000-0000-000000085203")
        let clip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: missingPartnerID,
                    duration: time(1, 2)
                )
            )
        )
        let sequence = try makeSequence(items: [.clip(clip)])

        XCTAssertThrowsError(
            try OfflineAudioMixer.render(
                sequence: sequence,
                range: TimeRange(start: .zero, duration: time(1, 1)),
                format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
                sourceProvider: InMemoryAudioSourceProvider(sources: [:])
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .crossfadePartnerMissing(
                    edge: .leadingCrossfade,
                    clipID: clipID,
                    partnerClipID: missingPartnerID
                )
            )
        }
    }

}

private func overshootingGain() throws -> Animatable<RationalValue> {
    let curve = CubicBezierTimingCurve(
        controlPoint1: CubicBezierTimingControlPoint(
            x: .zero,
            y: RationalValue(4)
        ),
        controlPoint2: CubicBezierTimingControlPoint(
            x: .one,
            y: RationalValue(4)
        )
    )
    return try Animatable(
        base: .one,
        keyframes: [
            Keyframe(time: .zero, value: .zero, interpolation: .bezier(curve)),
            Keyframe(time: time(1, 2), value: RationalValue(4), interpolation: .linear)
        ]
    )
}
