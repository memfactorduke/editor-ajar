// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarAudio

/// FR-AUD-002 / FR-AUD-004 guard behavior around crossfade tails: ducking trigger detection
/// samples through the exact tail-aware, EOF-clamped mapping the mixer plays, and the ADR-0015
/// §7 tail-delivery check fires only for renders that actually mix tail frames.
final class OfflineAudioCrossfadeGuardTests: XCTestCase {
    // MARK: - Ducking hears exactly what the mix plays

    func testFRAUD002EOFSilencedTailDoesNotTriggerDucking() throws {
        // The trigger's tail lies wholly past its declared media end, so the mixer plays
        // silence there — even though the provider over-delivers loud frames. Ducking must
        // release at the cut instead of firing on audio the mix never plays.
        let fixture = try makeDuckingFixture(
            triggerShape: CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear),
            triggerSamples: [Float](repeating: 1, count: 8)
        )
        let project = try makeCrossfadeProject(
            sequences: [fixture.sequence],
            media: [
                makeCrossfadeMediaRef(
                    id: fixture.triggerMediaID,
                    declaredDuration: try time(1, 2)
                )
            ]
        )

        let output = try OfflineAudioMixer.render(
            project: project,
            sequence: fixture.sequence,
            range: try TimeRange(start: .zero, duration: time(1, 1)),
            sourceProvider: InMemoryAudioSourceProvider(sources: fixture.sources)
        )

        // Trigger body ducks the bed to 0.5 (sum 1.5); the EOF-silenced tail must not.
        assertSamples(
            output.samples,
            equal: stereoFrames([1.5, 1.5, 1.5, 1.5, 1, 1, 1, 1])
        )
    }

    func testFRAUD002ReverseTailDucksOnlyAudioTheMixPlays() throws {
        // The reversed trigger plays loud source [1/2, 1) backward; its tail keeps reading
        // backward through the *silent* first half. Detection must follow the same reversed
        // mapping — the naive forward mapping would read the loud frames again and duck the
        // bed during a tail the mix renders as silence.
        var shape = CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear)
        shape.outgoingSourceStart = try time(1, 2)
        shape.outgoingReverse = true
        let fixture = try makeDuckingFixture(
            triggerShape: shape,
            triggerSamples: [0, 0, 0, 0, 1, 1, 1, 1]
        )

        let output = try OfflineAudioMixer.render(
            sequence: fixture.sequence,
            range: try TimeRange(start: .zero, duration: time(1, 1)),
            format: crossfadeRenderFormat,
            sourceProvider: InMemoryAudioSourceProvider(sources: fixture.sources)
        )

        // Reversed body is loud (ducks the bed); the tail reads silence, so no ducking.
        assertSamples(
            output.samples,
            equal: stereoFrames([1.5, 1.5, 1.5, 1.5, 1, 1, 1, 1])
        )
    }

    // MARK: - §7 delivery check scoped to renders that mix tail frames

    func testFRAUD002RenderWindowEndingAtTheCutSkipsTailDeliveryCheck() throws {
        // A render window that ends at the cut mixes no tail frames, so a short provider
        // buffer is not a fault yet.
        let fixture = try makeUnderDeliveringPairFixture()

        let output = try OfflineAudioMixer.render(
            project: fixture.project,
            sequence: fixture.sequence,
            range: try TimeRange(start: .zero, duration: time(1, 2)),
            sourceProvider: InMemoryAudioSourceProvider(sources: fixture.sources)
        )

        assertSamples(output.samples, equal: stereoFrames([1, 2, 3, 4]))
    }

    func testFRAUD002RenderWindowWhollyAfterThePairSkipsTailDeliveryCheck() throws {
        // Chunked rendering of a later timeline region: the window starts after the clip's
        // extended mix window, plays zero frames of the pair, and must succeed even though
        // the provider under-delivers — while a window overlapping the tail still throws.
        let fixture = try makeUnderDeliveringPairFixture()

        let after = try OfflineAudioMixer.render(
            project: fixture.project,
            sequence: fixture.sequence,
            range: try TimeRange(start: time(1, 1), duration: time(1, 1)),
            sourceProvider: InMemoryAudioSourceProvider(sources: fixture.sources)
        )
        assertSamples(after.samples, equal: stereoFrames([0, 0, 0, 0, 0, 0, 0, 0]))

        // Windowed providers owe only the source-time image of frames this render will mix.
        // The provider ends at 5/8, but this chunk begins at 3/4, so the typed fault reports
        // the actually requested tail interval rather than unrelated earlier source frames.
        let expectedMissing = try TimeRange(start: time(3, 4), duration: time(1, 4))
        XCTAssertThrowsError(
            try OfflineAudioMixer.render(
                project: fixture.project,
                sequence: fixture.sequence,
                range: try TimeRange(start: time(3, 4), duration: time(3, 4)),
                sourceProvider: InMemoryAudioSourceProvider(sources: fixture.sources)
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .sourceUnderDelivered(
                    clipID: crossfadeOutgoingClipID,
                    missingRange: expectedMissing
                )
            )
        }
    }
}

// MARK: - Fixture helpers

extension OfflineAudioCrossfadeGuardTests {
    private struct DuckingFixture {
        let sequence: Sequence
        let sources: [UUID: AudioSourceBuffer]
        let triggerMediaID: UUID
    }

    private struct UnderDeliveringPairFixture {
        let project: Project
        let sequence: Sequence
        let sources: [UUID: AudioSourceBuffer]
    }

    /// Trigger track: a crossfaded pair (loud outgoing, silent incoming). Target track: a
    /// constant-1 bed spanning the render, ducked to 0.5 while the trigger exceeds 0.5.
    private func makeDuckingFixture(
        triggerShape: CrossfadePairShape,
        triggerSamples: [Float]
    ) throws -> DuckingFixture {
        let triggerMediaID = try uuid("00000000-0000-0000-0000-000000164201")
        let silentMediaID = try uuid("00000000-0000-0000-0000-000000164202")
        let bedMediaID = try uuid("00000000-0000-0000-0000-000000164203")
        let triggerTrackID = try uuid("00000000-0000-0000-0000-000000164204")
        let bedTrackID = try uuid("00000000-0000-0000-0000-000000164205")
        let pair = try makeCrossfadedPair(
            mediaA: triggerMediaID,
            mediaB: silentMediaID,
            shape: triggerShape
        )
        let bedClip = try makeClip(
            id: try uuid("00000000-0000-0000-0000-000000164206"),
            mediaID: bedMediaID,
            duration: try time(1, 1)
        )
        let rule = AudioDuckingRule(
            triggerTrackID: triggerTrackID,
            targetTrackIDs: [bedTrackID],
            threshold: RationalValue.approximating(0.5),
            reductionGain: RationalValue.approximating(0.5),
            attack: .zero,
            release: .zero,
            hold: .zero
        )
        let sequence = try makeSequence(
            tracks: [
                makeTrack(id: triggerTrackID, items: pair),
                makeTrack(id: bedTrackID, items: [.clip(bedClip)])
            ],
            audioDucking: [rule]
        )
        return DuckingFixture(
            sequence: sequence,
            sources: [
                triggerMediaID: try crossfadeMonoSource(triggerSamples),
                silentMediaID: try crossfadeConstantSource(0),
                bedMediaID: try crossfadeConstantSource(1)
            ],
            triggerMediaID: triggerMediaID
        )
    }

    /// A crossfaded pair whose outgoing media declares a full second but whose provider
    /// delivers only 5 of the 8 declared frames — an ADR-0015 §7 decoder fault for any
    /// render that mixes tail frames.
    private func makeUnderDeliveringPairFixture() throws -> UnderDeliveringPairFixture {
        let mediaA = try uuid("00000000-0000-0000-0000-000000164211")
        let mediaB = try uuid("00000000-0000-0000-0000-000000164212")
        let pair = try makeCrossfadedPair(
            mediaA: mediaA,
            mediaB: mediaB,
            shape: CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear)
        )
        let sequence = try makeSequence(items: pair)
        let project = try makeCrossfadeProject(
            sequences: [sequence],
            media: [
                makeCrossfadeMediaRef(id: mediaA, declaredDuration: try time(1, 1)),
                makeCrossfadeMediaRef(id: mediaB, declaredDuration: try time(1, 1))
            ]
        )
        return UnderDeliveringPairFixture(
            project: project,
            sequence: sequence,
            sources: [
                mediaA: try crossfadeMonoSource([1, 2, 3, 4, 5]),
                mediaB: try crossfadeConstantSource(0)
            ]
        )
    }
}
