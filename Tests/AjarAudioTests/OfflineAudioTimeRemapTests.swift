// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// FR-SPD-002 offline audio coverage: ramped clips resample per instantaneous curve rate and
/// zero-slope spans sustain their source sample.
final class OfflineAudioTimeRemapTests: XCTestCase {
    func testFRSPD002TimeRemapRampResamplesAudioPerInstantaneousRate() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085801")
        // 1x for the first half second, then 2x: distinct from any constant rate.
        let curve = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: .zero, sourceTime: .zero),
            TimeRemapKeyframe(time: try time(1, 2), sourceTime: try time(1, 2)),
            TimeRemapKeyframe(time: try time(1, 1), sourceTime: try time(3, 2))
        ])
        let clip = try makeClip(mediaID: mediaID, duration: time(3, 2), timeRemap: curve)
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [0, 1, 2, 3, 4, 5, 6, 7],
            sourceSampleRate: 4
        )

        // Output frames at t = 0, 1/4, 1/2, 3/4 map to source samples 0, 1, 2, 4.
        // The constant-rate chord of the same curve (1.5x) would read 0, 1.5, 3, 4.5 instead.
        assertSamples(buffer.samples, equal: [0, 0, 1, 1, 2, 2, 4, 4])
    }

    func testFRSPD002TimeRemapZeroSlopeSpanSustainsHeldAudioSample() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085802")
        // Ramp in, freeze on source sample 1 for half a second, then ramp out at 2x. The
        // constant-rate chord of this curve is exactly 1x, so every non-zero difference below
        // comes from honoring the keyframes.
        let curve = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: .zero, sourceTime: .zero),
            TimeRemapKeyframe(time: try time(1, 4), sourceTime: try time(1, 4)),
            TimeRemapKeyframe(time: try time(3, 4), sourceTime: try time(1, 4)),
            TimeRemapKeyframe(time: try time(1, 1), sourceTime: try time(3, 4))
        ])
        let clip = try makeClip(mediaID: mediaID, duration: time(1, 1), timeRemap: curve)
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [0, 1, 2, 3],
            sourceSampleRate: 4
        )

        assertSamples(buffer.samples, equal: [0, 0, 1, 1, 1, 1, 1, 1])
    }

    func testFRSPD002TimeRemapConflictingRetimeFailsAudioRenderWithTypedError() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085803")
        let curve = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: .zero, sourceTime: .zero),
            TimeRemapKeyframe(time: try time(1, 1), sourceTime: try time(1, 1))
        ])
        let clip = try makeClip(
            mediaID: mediaID,
            duration: time(1, 1),
            reverse: true,
            timeRemap: curve
        )

        XCTAssertThrowsError(
            try render(
                clip: clip,
                mediaID: mediaID,
                sourceSamples: [0, 1, 2, 3],
                sourceSampleRate: 4
            )
        ) { error in
            guard case .timeArithmetic(let message)? = error as? AudioRenderError else {
                return XCTFail("Expected typed AudioRenderError, got \(error)")
            }
            XCTAssertTrue(message.contains("cannot combine"), message)
        }
    }
}
