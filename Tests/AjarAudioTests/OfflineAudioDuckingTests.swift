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

    func testFRAUD004HoldKeepsReachedAttackAmountWithoutGainStep() throws {
        let multipliers = try OfflineAudioMixer.duckingEnvelopeMultipliers(
            levels: [1, 0, 0, 0, 0],
            rule: AudioDuckingRule(
                triggerTrackID: try uuid("00000000-0000-0000-0000-000000085541"),
                targetTrackIDs: [try uuid("00000000-0000-0000-0000-000000085542")],
                threshold: try RationalValue(numerator: 1, denominator: 2),
                reductionGain: .zero,
                attack: time(1, 1),
                release: time(1, 1),
                hold: time(1, 2)
            ),
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2)
        )

        assertMultipliers(multipliers, equal: [0.75, 0.75, 0.75, 1, 1])
    }

    func testFRAUD004MultiRuleTargetsComposeWithoutTriggerFeedback() throws {
        let triggerMediaID = try uuid("00000000-0000-0000-0000-000000085551")
        let middleMediaID = try uuid("00000000-0000-0000-0000-000000085552")
        let targetMediaID = try uuid("00000000-0000-0000-0000-000000085553")
        let triggerTrackID = try uuid("00000000-0000-0000-0000-000000085554")
        let middleTrackID = try uuid("00000000-0000-0000-0000-000000085555")
        let targetTrackID = try uuid("00000000-0000-0000-0000-000000085556")
        let tracks = [
            try makeTrack(
                id: triggerTrackID,
                items: [.clip(try makeClip(mediaID: triggerMediaID, duration: time(1, 1)))]
            ),
            try makeTrack(
                id: middleTrackID,
                items: [.clip(try makeClip(mediaID: middleMediaID, duration: time(1, 1)))]
            ),
            try makeTrack(
                id: targetTrackID,
                items: [.clip(try makeClip(mediaID: targetMediaID, duration: time(1, 1)))]
            )
        ]
        let firstRule = try testDuckingRule(
            triggerTrackID: triggerTrackID,
            targetTrackIDs: [middleTrackID, targetTrackID],
            threshold: try RationalValue(numerator: 1, denominator: 2),
            reductionGain: try RationalValue(numerator: 1, denominator: 2)
        )
        let secondRule = try testDuckingRule(
            triggerTrackID: middleTrackID,
            targetTrackID: targetTrackID,
            threshold: try RationalValue(numerator: 1, denominator: 2),
            reductionGain: try RationalValue(numerator: 1, denominator: 4)
        )

        let forward = try duckingMultipliers(
            rules: [firstRule, secondRule],
            tracks: tracks,
            sources: [
                triggerMediaID: try audioSource(samples: [1, 0, 0, 0]),
                middleMediaID: try audioSource(samples: [1, 1, 0, 0]),
                targetMediaID: try audioSource(samples: [4, 4, 4, 4])
            ]
        )
        let reversed = try duckingMultipliers(
            rules: [secondRule, firstRule],
            tracks: tracks,
            sources: [
                triggerMediaID: try audioSource(samples: [1, 0, 0, 0]),
                middleMediaID: try audioSource(samples: [1, 1, 0, 0]),
                targetMediaID: try audioSource(samples: [4, 4, 4, 4])
            ]
        )

        XCTAssertEqual(forward, reversed)
        assertMultipliers(try XCTUnwrap(forward[middleTrackID]), equal: [0.5, 1, 1, 1])
        assertMultipliers(try XCTUnwrap(forward[targetTrackID]), equal: [0.125, 0.25, 1, 1])
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

private func testDuckingRule(
    triggerTrackID: UUID,
    targetTrackIDs: [UUID],
    threshold: RationalValue,
    reductionGain: RationalValue,
    attack: RationalTime = .zero,
    release: RationalTime = .zero,
    hold: RationalTime = .zero
) throws -> AudioDuckingRule {
    AudioDuckingRule(
        triggerTrackID: triggerTrackID,
        targetTrackIDs: targetTrackIDs,
        threshold: threshold,
        reductionGain: reductionGain,
        attack: attack,
        release: release,
        hold: hold
    )
}

private func duckingMultipliers(
    rules: [AudioDuckingRule],
    tracks: [Track],
    sources: [UUID: AudioSourceBuffer]
) throws -> [UUID: [Double]] {
    var environment = OfflineAudioRenderEnvironment(
        project: nil,
        sourceProvider: InMemoryAudioSourceProvider(sources: sources)
    )
    return try OfflineAudioMixer.duckingMultipliersByTrackID(
        rules: rules,
        tracks: tracks,
        context: OfflineMixContext(
            frameCount: 4,
            range: TimeRange(start: .zero, duration: time(1, 1)),
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2)
        ),
        environment: &environment,
        nestingDepth: 0
    )
}

private func assertMultipliers(
    _ actual: [Double],
    equal expected: [Double],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for index in actual.indices {
        XCTAssertEqual(actual[index], expected[index], accuracy: 0.00001, file: file, line: line)
    }
}
