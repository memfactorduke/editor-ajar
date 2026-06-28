// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class AudioMixModelTests: XCTestCase {
    func testFRAUD001AudioMixValueAtIsDeterministicAndTotal() throws {
        let mix = ClipAudioMix(
            gain: try Animatable(
                base: .one,
                keyframes: [
                    Keyframe(
                        time: try audioMixTime(0),
                        value: .one,
                        interpolation: .linear
                    ),
                    Keyframe(
                        time: try audioMixTime(10),
                        value: RationalValue(2),
                        interpolation: .hold
                    )
                ]
            ),
            pan: try Animatable(
                base: .zero,
                keyframes: [
                    Keyframe(
                        time: try audioMixTime(0),
                        value: RationalValue(-1),
                        interpolation: .linear
                    ),
                    Keyframe(
                        time: try audioMixTime(10),
                        value: .one,
                        interpolation: .hold
                    )
                ]
            )
        )

        XCTAssertEqual(ClipAudioMix.identity.value(at: try audioMixTime(-24)).gain, .one)
        XCTAssertEqual(ClipAudioMix.identity.value(at: try audioMixTime(24)).pan, .zero)

        let midpoint = mix.value(at: try audioMixTime(5))
        XCTAssertEqual(midpoint.gain, try RationalValue(numerator: 3, denominator: 2))
        XCTAssertEqual(midpoint.pan, .zero)

        for frame in -4...14 {
            let time = try audioMixTime(Int64(frame))
            XCTAssertEqual(mix.value(at: time), mix.value(at: time))
        }
    }

    func testFRAUD002FadeEnvelopeEvaluatesClipBoundaries() throws {
        let mix = ClipAudioMix(
            fadeIn: ClipAudioFade(duration: try audioMixTime(4)),
            fadeOut: ClipAudioFade(duration: try audioMixTime(6))
        )
        let clipDuration = try audioMixTime(20)

        XCTAssertEqual(mix.fadeEnvelope(at: .zero, clipDuration: clipDuration), .zero)
        XCTAssertEqual(mix.fadeEnvelope(at: try audioMixTime(4), clipDuration: clipDuration), .one)
        XCTAssertEqual(
            mix.fadeEnvelope(at: try audioMixTime(17), clipDuration: clipDuration),
            try RationalValue(numerator: 1, denominator: 2)
        )
        XCTAssertEqual(mix.fadeEnvelope(at: clipDuration, clipDuration: clipDuration), .zero)
    }
}

private func audioMixTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}
