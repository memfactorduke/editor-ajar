// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// Render-path enforcement of the ADR-0015 crossfade pair taxonomy (FR-AUD-002).
final class AudioCrossfadeValidatorTests: XCTestCase {
    func testFRAUD002RenderRejectsCrossfadeMirrorMissing() throws {
        let firstClipID = try uuid("00000000-0000-0000-0000-000000086101")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000086102")
        let mediaID = try uuid("00000000-0000-0000-0000-000000086103")
        let firstClip = try makeClip(
            id: firstClipID,
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                trailingCrossfade: ClipAudioCrossfade(
                    partnerClipID: secondClipID,
                    duration: time(1, 2)
                )
            )
        )
        let secondClip = try makeClip(
            id: secondClipID,
            mediaID: mediaID,
            timelineStart: time(1, 1),
            duration: time(1, 1)
        )

        try assertRenderRejects(
            items: [.clip(firstClip), .clip(secondClip)],
            with: .crossfadeMirrorMissing(
                edge: .trailingCrossfade,
                clipID: firstClipID,
                partnerClipID: secondClipID
            )
        )
    }

    func testFRAUD002RenderRejectsCrossfadeSeparatedByGap() throws {
        let firstClipID = try uuid("00000000-0000-0000-0000-000000086104")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000086105")
        let mediaID = try uuid("00000000-0000-0000-0000-000000086106")
        let firstClip = try makeClip(
            id: firstClipID,
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                trailingCrossfade: ClipAudioCrossfade(
                    partnerClipID: secondClipID,
                    duration: time(1, 2)
                )
            )
        )
        let secondClip = try makeClip(
            id: secondClipID,
            mediaID: mediaID,
            timelineStart: time(3, 2),
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: firstClipID,
                    duration: time(1, 2)
                )
            )
        )
        let gap = try TimeRange(start: time(1, 1), duration: time(1, 2))

        try assertRenderRejects(
            items: [.clip(firstClip), .gap(gap), .clip(secondClip)],
            with: .crossfadeSeparatedByGap(
                edge: .trailingCrossfade,
                clipID: firstClipID,
                partnerClipID: secondClipID
            )
        )
    }

    func testFRAUD002RenderRejectsCrossfadeConflictsWithFade() throws {
        let firstClipID = try uuid("00000000-0000-0000-0000-000000086107")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000086108")
        let mediaID = try uuid("00000000-0000-0000-0000-000000086109")
        let firstClip = try makeClip(
            id: firstClipID,
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                fadeOut: ClipAudioFade(duration: time(1, 4)),
                trailingCrossfade: ClipAudioCrossfade(
                    partnerClipID: secondClipID,
                    duration: time(1, 2)
                )
            )
        )
        let secondClip = try makeClip(
            id: secondClipID,
            mediaID: mediaID,
            timelineStart: time(1, 1),
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: firstClipID,
                    duration: time(1, 2)
                )
            )
        )

        try assertRenderRejects(
            items: [.clip(firstClip), .clip(secondClip)],
            with: .crossfadeConflictsWithFade(edge: .trailingCrossfade, clipID: firstClipID)
        )
    }

    func testFRAUD002RenderRejectsUnsupportedCrossfadeCurve() throws {
        let firstClipID = try uuid("00000000-0000-0000-0000-000000086110")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000086111")
        let mediaID = try uuid("00000000-0000-0000-0000-000000086112")
        let firstClip = try makeClip(
            id: firstClipID,
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                trailingCrossfade: ClipAudioCrossfade(
                    partnerClipID: secondClipID,
                    duration: time(1, 2),
                    curve: .easeIn
                )
            )
        )
        let secondClip = try makeClip(
            id: secondClipID,
            mediaID: mediaID,
            timelineStart: time(1, 1),
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: firstClipID,
                    duration: time(1, 2),
                    curve: .easeIn
                )
            )
        )

        try assertRenderRejects(
            items: [.clip(firstClip), .clip(secondClip)],
            with: .crossfadeCurveUnsupported(
                edge: .trailingCrossfade,
                clipID: firstClipID,
                curve: .easeIn
            )
        )
    }

    func testFRAUD002RenderAcceptsValidEqualPowerPairWithoutRenderingChange() throws {
        let firstID = try uuid("00000000-0000-0000-0000-000000086113")
        let secondID = try uuid("00000000-0000-0000-0000-000000086114")
        let firstClipID = try uuid("00000000-0000-0000-0000-000000086115")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000086116")
        let firstClip = try makeClip(
            id: firstClipID,
            mediaID: firstID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                trailingCrossfade: ClipAudioCrossfade(
                    partnerClipID: secondClipID,
                    duration: time(1, 2),
                    curve: .equalPower
                )
            )
        )
        let secondClip = try makeClip(
            id: secondClipID,
            mediaID: secondID,
            timelineStart: time(1, 1),
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: firstClipID,
                    duration: time(1, 2),
                    curve: .equalPower
                )
            )
        )
        let buffer = try render(
            sequence: makeSequence(items: [.clip(firstClip), .clip(secondClip)]),
            sources: [
                firstID: try audioSource(samples: [1, 1, 1, 1]),
                secondID: try audioSource(samples: [1, 1, 1, 1])
            ],
            duration: time(2, 1)
        )

        assertSamples(
            buffer.samples,
            equal: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        )
    }
}

private func assertRenderRejects(
    items: [TimelineItem],
    with expectedError: AudioRenderError,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let sequence = try makeSequence(items: items)

    XCTAssertThrowsError(
        try OfflineAudioMixer.render(
            sequence: sequence,
            range: TimeRange(start: .zero, duration: time(3, 1)),
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
            sourceProvider: InMemoryAudioSourceProvider(sources: [:])
        ),
        file: file,
        line: line
    ) { error in
        XCTAssertEqual(error as? AudioRenderError, expectedError, file: file, line: line)
    }
}
