// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class OfflineAudioMixerFollowUpTests: XCTestCase {
    func testFRAUD003RendersMultipleClipsOnOneTrack() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085003")
        let firstClip = try makeClip(
            id: try uuid("00000000-0000-0000-0000-000000085004"),
            mediaID: mediaID,
            duration: time(1, 2)
        )
        let secondClip = try makeClip(
            id: try uuid("00000000-0000-0000-0000-000000085005"),
            mediaID: mediaID,
            sourceStart: time(1, 2),
            timelineStart: time(1, 2),
            duration: time(1, 2)
        )
        let sequence = try makeSequence(items: [.clip(firstClip), .clip(secondClip)])
        let buffer = try render(
            sequence: sequence,
            sources: [mediaID: try audioSource(samples: [1, 1, 2, 2])]
        )

        assertSamples(buffer.samples, equal: [1, 1, 1, 1, 2, 2, 2, 2])
    }

    func testFRAUD003SumsTracksWithTrackGainPanMuteAndEnabledSelection() throws {
        let voiceID = try uuid("00000000-0000-0000-0000-000000085006")
        let musicID = try uuid("00000000-0000-0000-0000-000000085007")
        let ignoredID = try uuid("00000000-0000-0000-0000-000000085008")
        let sequence = try makeSequence(tracks: [
            makeTrack(
                items: [.clip(try makeClip(mediaID: voiceID, duration: time(1, 1)))],
                audioGain: .constant(RationalValue.approximating(0.5)),
                audioPan: .constant(RationalValue.approximating(-0.5))
            ),
            makeTrack(
                items: [.clip(try makeClip(mediaID: musicID, duration: time(1, 1)))],
                audioPan: .constant(RationalValue.approximating(0.5))
            ),
            makeTrack(
                items: [.clip(try makeClip(mediaID: ignoredID, duration: time(1, 1)))],
                muted: true
            ),
            makeTrack(
                items: [.clip(try makeClip(mediaID: ignoredID, duration: time(1, 1)))],
                enabled: false
            )
        ])
        let buffer = try render(
            sequence: sequence,
            sources: [
                voiceID: try audioSource(samples: [1, 1, 1, 1]),
                musicID: try audioSource(samples: [2, 2, 2, 2]),
                ignoredID: try audioSource(samples: [100, 100, 100, 100])
            ]
        )

        assertSamples(
            buffer.samples,
            equal: [1.5, 2.25, 1.5, 2.25, 1.5, 2.25, 1.5, 2.25]
        )
    }

    func testFRAUD003SoloTrackExcludesOtherwiseRenderableTracks() throws {
        let ignoredID = try uuid("00000000-0000-0000-0000-000000085009")
        let soloID = try uuid("00000000-0000-0000-0000-000000085010")
        let sequence = try makeSequence(tracks: [
            makeTrack(items: [.clip(try makeClip(mediaID: ignoredID, duration: time(1, 1)))]),
            makeTrack(
                items: [.clip(try makeClip(mediaID: soloID, duration: time(1, 1)))],
                solo: true
            )
        ])
        let buffer = try render(
            sequence: sequence,
            sources: [
                ignoredID: try audioSource(samples: [100, 100, 100, 100]),
                soloID: try audioSource(samples: [3, 3, 3, 3])
            ]
        )

        assertSamples(buffer.samples, equal: [3, 3, 3, 3, 3, 3, 3, 3])
    }

    func testFRAUD007RealtimePlanUsesPreparedPointerStorageAndCallerOwnedOutput() throws {
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
            frameCount: 2,
            samples: [1, 2, 3, 4]
        )
        var plan = RealtimeAudioRenderPlan(buffer: buffer)
        let report = plan.safetyReport()

        XCTAssertEqual(report.storageKind, .ownedPointer)
        XCTAssertTrue(report.usesCallerOwnedOutput)
        XCTAssertFalse(report.usesLocks)
        XCTAssertFalse(report.allocatesDuringRender)
        XCTAssertEqual(report.preparedFrameCount, 2)

        var output = [Float](repeating: -1, count: 6)
        let copied = output.withUnsafeMutableBufferPointer { pointer in
            plan.render(into: pointer)
        }

        XCTAssertEqual(copied, 2)
        XCTAssertEqual(output, [1, 2, 3, 4, 0, 0])
    }

    func testFRAUD002ValidExactAbutCrossfadeDoesNotIntroduceDropout() throws {
        let firstID = try uuid("00000000-0000-0000-0000-000000085011")
        let secondID = try uuid("00000000-0000-0000-0000-000000085012")
        let firstClipID = try uuid("00000000-0000-0000-0000-000000085013")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000085014")
        let sequence = try makeSequence(items: [
            .clip(try crossfadeOutClip(id: firstClipID, mediaID: firstID, partnerID: secondClipID)),
            .clip(try crossfadeInClip(id: secondClipID, mediaID: secondID, partnerID: firstClipID))
        ])
        let buffer = try render(
            sequence: sequence,
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

    func testTrailingCrossfadePartnerMustBeRealAdjacentClip() throws {
        let firstClipID = try uuid("00000000-0000-0000-0000-000000085104")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000085105")
        let mediaID = try uuid("00000000-0000-0000-0000-000000085106")
        let firstClip = try crossfadeOutClip(
            id: firstClipID,
            mediaID: mediaID,
            partnerID: secondClipID
        )
        let secondClip = try makeClip(
            id: secondClipID,
            mediaID: mediaID,
            timelineStart: time(2, 1),
            duration: time(1, 1)
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
                    edge: .trailingCrossfade,
                    clipID: firstClipID,
                    partnerClipID: secondClipID
                )
            )
        }
    }

    func testCrossfadePartnerMustNotMatchOwningClip() throws {
        let clipID = try uuid("00000000-0000-0000-0000-000000085107")
        let mediaID = try uuid("00000000-0000-0000-0000-000000085108")
        let clip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: clipID,
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
                .crossfadePartnerMatchesClip(edge: .leadingCrossfade, clipID: clipID)
            )
        }
    }

    func testCrossfadeValidationSkipsTracksThatRenderSelectionSkips() throws {
        let skippedClipID = try uuid("00000000-0000-0000-0000-000000085109")
        let missingPartnerID = try uuid("00000000-0000-0000-0000-000000085110")
        let skippedMediaID = try uuid("00000000-0000-0000-0000-000000085111")
        let renderedMediaID = try uuid("00000000-0000-0000-0000-000000085112")
        let invalidSkippedClip = try makeClip(
            id: skippedClipID,
            mediaID: skippedMediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: missingPartnerID,
                    duration: time(1, 2)
                )
            )
        )
        let sequence = try makeSequence(tracks: [
            makeTrack(items: [.clip(invalidSkippedClip)]),
            makeTrack(items: [.clip(invalidSkippedClip)], enabled: false),
            makeTrack(
                items: [.clip(try makeClip(mediaID: renderedMediaID, duration: time(1, 1)))],
                solo: true
            )
        ])

        let buffer = try render(
            sequence: sequence,
            sources: [
                skippedMediaID: try audioSource(samples: [100, 100, 100, 100]),
                renderedMediaID: try audioSource(samples: [2, 2, 2, 2])
            ]
        )

        assertSamples(buffer.samples, equal: [2, 2, 2, 2, 2, 2, 2, 2])
    }

    func testFRAUD009DownmixesFiveOneSourceToStereoOutput() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085204")
        let clip = try makeClip(mediaID: mediaID, duration: time(1, 4))
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 6),
            frameCount: 1,
            samples: [1, 2, 3, 4, 5, 6]
        )
        let buffer = try render(
            sequence: makeSequence(items: [.clip(clip)]),
            sources: [mediaID: source],
            duration: time(1, 4)
        )

        assertSamples(buffer.samples, equal: [6.6568546, 8.363961])
    }

    func testFRAUD009NonFiveOneMultichannelUsesDeterministicFallbackMapping() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085205")
        let clip = try makeClip(mediaID: mediaID, duration: time(1, 4))
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 4),
            frameCount: 1,
            samples: [1, 2, 3, 4]
        )
        let buffer = try render(
            sequence: makeSequence(items: [.clip(clip)]),
            sources: [mediaID: source],
            duration: time(1, 4)
        )

        assertSamples(buffer.samples, equal: [1, 2])
    }

    func testRenderRejectsOutputSampleCountOverflowBeforeAllocation() throws {
        let hugeDuration = try RationalTime(value: Int64(Int.max), timescale: 1)
        let sequence = try makeSequence(tracks: [])

        XCTAssertThrowsError(
            try OfflineAudioMixer.render(
                sequence: sequence,
                range: TimeRange(start: .zero, duration: hugeDuration),
                format: AudioRenderFormat(sampleRate: 1, channelCount: 2),
                sourceProvider: InMemoryAudioSourceProvider(sources: [:])
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .sampleCountOverflow(frameCount: Int.max, channelCount: 2)
            )
        }
    }
}

private func crossfadeOutClip(id: UUID, mediaID: UUID, partnerID: UUID) throws -> Clip {
    try makeClip(
        id: id,
        mediaID: mediaID,
        duration: time(1, 1),
        audioMix: ClipAudioMix(
            trailingCrossfade: ClipAudioCrossfade(
                partnerClipID: partnerID,
                duration: time(1, 2)
            )
        )
    )
}

private func crossfadeInClip(id: UUID, mediaID: UUID, partnerID: UUID) throws -> Clip {
    try makeClip(
        id: id,
        mediaID: mediaID,
        timelineStart: time(1, 1),
        duration: time(1, 1),
        audioMix: ClipAudioMix(
            leadingCrossfade: ClipAudioCrossfade(
                partnerClipID: partnerID,
                duration: time(1, 2)
            )
        )
    )
}
