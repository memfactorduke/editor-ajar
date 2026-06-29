// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class OfflineAudioDuckingTests: XCTestCase {
    func testFRAUD004ThresholdDucksOnlyTargetTrack() throws {
        let triggerMediaID = try uuid("00000000-0000-0000-0000-000000085501")
        let targetMediaID = try uuid("00000000-0000-0000-0000-000000085502")
        let triggerTrackID = try uuid("00000000-0000-0000-0000-000000085503")
        let targetTrackID = try uuid("00000000-0000-0000-0000-000000085504")
        let sequence = try makeDuckingSequence(
            triggerMediaID: triggerMediaID,
            targetMediaID: targetMediaID,
            triggerTrackID: triggerTrackID,
            targetTrackID: targetTrackID,
            rule: try testDuckingRule(
                triggerTrackID: triggerTrackID,
                targetTrackID: targetTrackID,
                threshold: try RationalValue(numerator: 1, denominator: 2),
                reductionGain: try RationalValue(numerator: 1, denominator: 4)
            )
        )
        let buffer = try render(
            sequence: sequence,
            sources: [
                triggerMediaID: try audioSource(samples: [0, 1, 0, 1]),
                targetMediaID: try audioSource(samples: [2, 2, 2, 2])
            ]
        )

        assertSamples(
            buffer.samples,
            equal: [2, 2, 1.5, 1.5, 2, 2, 1.5, 1.5]
        )
    }

    func testFRAUD004AttackAndReleaseRampDuckingEnvelope() throws {
        let triggerMediaID = try uuid("00000000-0000-0000-0000-000000085511")
        let targetMediaID = try uuid("00000000-0000-0000-0000-000000085512")
        let triggerTrackID = try uuid("00000000-0000-0000-0000-000000085513")
        let targetTrackID = try uuid("00000000-0000-0000-0000-000000085514")
        let sequence = try makeDuckingSequence(
            triggerMediaID: triggerMediaID,
            targetMediaID: targetMediaID,
            triggerTrackID: triggerTrackID,
            targetTrackID: targetTrackID,
            rule: try testDuckingRule(
                triggerTrackID: triggerTrackID,
                targetTrackID: targetTrackID,
                threshold: try RationalValue(numerator: 1, denominator: 2),
                reductionGain: try RationalValue(numerator: 1, denominator: 2),
                attack: time(1, 2),
                release: time(1, 2)
            )
        )
        let buffer = try render(
            sequence: sequence,
            sources: [
                triggerMediaID: try audioSource(samples: [1, 1, 0, 0]),
                targetMediaID: try audioSource(samples: [2, 2, 2, 2])
            ]
        )

        assertSamples(
            buffer.samples,
            equal: [2.5, 2.5, 2, 2, 1.5, 1.5, 2, 2]
        )
    }

    func testFRAUD004HoldKeepsTargetDuckedAfterTriggerFallsBelowThreshold() throws {
        let triggerMediaID = try uuid("00000000-0000-0000-0000-000000085521")
        let targetMediaID = try uuid("00000000-0000-0000-0000-000000085522")
        let triggerTrackID = try uuid("00000000-0000-0000-0000-000000085523")
        let targetTrackID = try uuid("00000000-0000-0000-0000-000000085524")
        let sequence = try makeDuckingSequence(
            triggerMediaID: triggerMediaID,
            targetMediaID: targetMediaID,
            triggerTrackID: triggerTrackID,
            targetTrackID: targetTrackID,
            rule: try testDuckingRule(
                triggerTrackID: triggerTrackID,
                targetTrackID: targetTrackID,
                threshold: try RationalValue(numerator: 1, denominator: 2),
                reductionGain: try RationalValue(numerator: 1, denominator: 2),
                hold: time(1, 4)
            )
        )
        let buffer = try render(
            sequence: sequence,
            sources: [
                triggerMediaID: try audioSource(samples: [1, 0, 0, 0]),
                targetMediaID: try audioSource(samples: [2, 2, 2, 2])
            ]
        )

        assertSamples(
            buffer.samples,
            equal: [2, 2, 1, 1, 2, 2, 2, 2]
        )
    }

    func testFRAUD004MutedTriggerTrackDoesNotDuckSelectedTarget() throws {
        let triggerMediaID = try uuid("00000000-0000-0000-0000-000000085531")
        let targetMediaID = try uuid("00000000-0000-0000-0000-000000085532")
        let triggerTrackID = try uuid("00000000-0000-0000-0000-000000085533")
        let targetTrackID = try uuid("00000000-0000-0000-0000-000000085534")
        let triggerTrack = try makeTrack(
            id: triggerTrackID,
            items: [
                .clip(try makeClip(mediaID: triggerMediaID, duration: time(1, 1)))
            ],
            muted: true
        )
        let targetTrack = try makeTrack(
            id: targetTrackID,
            items: [
                .clip(try makeClip(mediaID: targetMediaID, duration: time(1, 1)))
            ]
        )
        let sequence = try makeSequence(
            tracks: [triggerTrack, targetTrack],
            audioDucking: [
                try testDuckingRule(
                    triggerTrackID: triggerTrackID,
                    targetTrackID: targetTrackID,
                    threshold: try RationalValue(numerator: 1, denominator: 2),
                    reductionGain: try RationalValue(numerator: 1, denominator: 4)
                )
            ]
        )
        let buffer = try render(
            sequence: sequence,
            sources: [
                triggerMediaID: try audioSource(samples: [1, 1, 1, 1]),
                targetMediaID: try audioSource(samples: [2, 2, 2, 2])
            ]
        )

        assertSamples(buffer.samples, equal: [2, 2, 2, 2, 2, 2, 2, 2])
    }
}

private func makeDuckingSequence(
    triggerMediaID: UUID,
    targetMediaID: UUID,
    triggerTrackID: UUID,
    targetTrackID: UUID,
    rule: AudioDuckingRule
) throws -> Sequence {
    let triggerTrack = try makeTrack(
        id: triggerTrackID,
        items: [
            .clip(try makeClip(mediaID: triggerMediaID, duration: time(1, 1)))
        ]
    )
    let targetTrack = try makeTrack(
        id: targetTrackID,
        items: [
            .clip(try makeClip(mediaID: targetMediaID, duration: time(1, 1)))
        ]
    )
    return try makeSequence(tracks: [triggerTrack, targetTrack], audioDucking: [rule])
}

private func testDuckingRule(
    triggerTrackID: UUID,
    targetTrackID: UUID,
    threshold: RationalValue,
    reductionGain: RationalValue,
    attack: RationalTime = .zero,
    release: RationalTime = .zero,
    hold: RationalTime = .zero
) throws -> AudioDuckingRule {
    AudioDuckingRule(
        triggerTrackID: triggerTrackID,
        targetTrackIDs: [targetTrackID],
        threshold: threshold,
        reductionGain: reductionGain,
        attack: attack,
        release: release,
        hold: hold
    )
}
