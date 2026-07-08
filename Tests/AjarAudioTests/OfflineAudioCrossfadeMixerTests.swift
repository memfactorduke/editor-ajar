// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarAudio

/// FR-AUD-002 / ADR-0015 fade-tail crossfade rendering: the outgoing clip's source keeps
/// playing past its timeline out-point for the transition duration, mixed under the incoming
/// clip with the pair's curve, so both sources are audible across the region and the #101
/// silence notch cannot occur.
final class OfflineAudioCrossfadeMixerTests: XCTestCase {
    // MARK: - §1/§4 region rendering

    func testFRAUD002CorrelatedLinearCrossfadeReproducesTheUncutSource() throws {
        // A blade-style split of one staircase source rejoined by a linear crossfade must
        // render exactly the uncut source: out(t)·(1-x) + in(t)·x == source(t).
        let mediaID = try uuid("00000000-0000-0000-0000-000000164001")
        let uncut = try renderEightFrames(
            items: [
                .clip(
                    try makeClip(
                        id: try uuid("00000000-0000-0000-0000-000000164002"),
                        mediaID: mediaID,
                        duration: time(1, 1)
                    ))
            ],
            sources: [mediaID: try crossfadeStaircaseSource()]
        )

        var shape = CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear)
        shape.incomingSourceStart = try time(1, 2)
        let pair = try makeCrossfadedPair(mediaA: mediaID, mediaB: mediaID, shape: shape)
        let crossfaded = try renderEightFrames(
            items: pair,
            sources: [mediaID: try crossfadeStaircaseSource()]
        )

        XCTAssertEqual(uncut.samples, stereoFrames([1, 2, 3, 4, 5, 6, 7, 8]))
        assertSamples(crossfaded.samples, equal: uncut.samples)
    }

    func testFRAUD002EqualPowerCrossfadeAppliesSineCosineGains() throws {
        // ADR-0015 §4: g_out(x) = cos(πx/2) on the outgoing tail, g_in(x) = sin(πx/2) on the
        // incoming clip, with g_out² + g_in² = 1 at every region frame.
        let mediaA = try uuid("00000000-0000-0000-0000-000000164011")
        let mediaB = try uuid("00000000-0000-0000-0000-000000164012")
        let pair = try makeCrossfadedPair(
            mediaA: mediaA,
            mediaB: mediaB,
            shape: CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .equalPower)
        )

        let output = try renderEightFrames(
            items: pair,
            sources: [
                mediaA: try crossfadeConstantSource(0.8),
                mediaB: try crossfadeConstantSource(0.6)
            ]
        )

        var expected: [Float] = [0.8, 0.8, 0.8, 0.8]
        for fraction in [0.0, 0.25, 0.5, 0.75] {
            let gainOut = cos(fraction * Double.pi / 2)
            let gainIn = sin(fraction * Double.pi / 2)
            XCTAssertEqual((gainOut * gainOut) + (gainIn * gainIn), 1, accuracy: 1e-12)
            expected.append(Float((0.8 * gainOut) + (0.6 * gainIn)))
        }
        assertSamples(output.samples, equal: stereoFrames(expected))
    }

    // MARK: - §2 tail sampling through retimes

    func testFRAUD002ReverseTailContinuesBackwardPastSourceRangeStart() throws {
        // The reversed clip plays source [1/2, 1) backward as 8,7,6,5; its tail keeps reading
        // backward past sourceRange.start through samples 4,3,2,1 under the linear ramp.
        let mediaA = try uuid("00000000-0000-0000-0000-000000164021")
        let mediaB = try uuid("00000000-0000-0000-0000-000000164022")
        var shape = CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear)
        shape.outgoingSourceStart = try time(1, 2)
        shape.outgoingReverse = true
        let pair = try makeCrossfadedPair(mediaA: mediaA, mediaB: mediaB, shape: shape)

        let output = try renderEightFrames(
            items: pair,
            sources: [
                mediaA: try crossfadeStaircaseSource(),
                mediaB: try crossfadeConstantSource(0)
            ]
        )

        assertSamples(output.samples, equal: stereoFrames([8, 7, 6, 5, 4, 2.25, 1, 0.25]))
    }

    func testFRAUD002FreezeFrameTailKeepsHoldingItsFrame() throws {
        let mediaA = try uuid("00000000-0000-0000-0000-000000164031")
        let mediaB = try uuid("00000000-0000-0000-0000-000000164032")
        var shape = CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear)
        shape.outgoingSourceStart = try time(1, 4)
        shape.outgoingFreezeFrame = true
        let pair = try makeCrossfadedPair(mediaA: mediaA, mediaB: mediaB, shape: shape)

        let output = try renderEightFrames(
            items: pair,
            sources: [
                mediaA: try crossfadeStaircaseSource(),
                mediaB: try crossfadeConstantSource(0)
            ]
        )

        // The frozen frame is source sample 3 (source time 1/4); the tail ramps it out.
        assertSamples(output.samples, equal: stereoFrames([3, 3, 3, 3, 3, 2.25, 1.5, 0.75]))
    }

    func testFRAUD002ConstantSpeedTailExtendsTheMappingLinearly() throws {
        // A 2x clip consumes source [0, 1/2) over timeline [0, 1/4); its D=1/4 tail keeps
        // consuming at 2x through source [1/2, 1): samples 5 and 7 under the linear ramp.
        let mediaA = try uuid("00000000-0000-0000-0000-000000164041")
        let mediaB = try uuid("00000000-0000-0000-0000-000000164042")
        var shape = CrossfadePairShape(crossfadeDuration: try time(1, 4), curve: .linear)
        shape.outgoingSpeed = RationalValue(2)
        shape.outgoingTimelineDuration = try time(1, 4)
        let pair = try makeCrossfadedPair(mediaA: mediaA, mediaB: mediaB, shape: shape)

        let output = try OfflineAudioMixer.render(
            sequence: makeSequence(items: pair),
            range: TimeRange(start: .zero, duration: time(1, 2)),
            format: crossfadeRenderFormat,
            sourceProvider: InMemoryAudioSourceProvider(sources: [
                mediaA: try crossfadeStaircaseSource(),
                mediaB: try crossfadeConstantSource(0)
            ])
        )

        assertSamples(output.samples, equal: stereoFrames([1, 3, 5, 3.5]))
    }

    // MARK: - §3 effective read window as the cache key

    func testFRAUD002CompoundSourceKeyVariesWithCrossfadeDuration() throws {
        // ADR-0015 §3: adding, removing, or resizing a crossfade must change the compound
        // source cache key, or a stale tail-less buffer would be returned.
        let sequenceID = try uuid("00000000-0000-0000-0000-000000164051")
        let durations: [RationalTime?] = [nil, try time(1, 4), try time(1, 2)]
        let keys = try durations.map { duration -> CompoundAudioSourceKey in
            let clip = try makeCompoundOutgoingClip(
                sequenceID: sequenceID,
                crossfadeDuration: duration
            )
            let window = try OfflineAudioMixer.alignedSourceWindow(
                for: OfflineAudioMixer.effectiveSourceWindow(for: clip),
                sampleRate: crossfadeRenderFormat.sampleRate
            )
            return CompoundAudioSourceKey(
                sequenceID: sequenceID,
                sourceRange: window.range,
                format: crossfadeRenderFormat
            )
        }

        XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertNotEqual(keys[1], keys[2])
        XCTAssertNotEqual(keys[0], keys[2])
    }

    func testFRAUD002CompoundOutgoingClipRendersItsNestedTailPastTheWindow() throws {
        // The compound clip's window is [0, 1/2) of the nested sequence; the tail must keep
        // reading the nested program through [1/2, 1) (ADR-0015 §2).
        let mediaID = try uuid("00000000-0000-0000-0000-000000164061")
        let silentMediaID = try uuid("00000000-0000-0000-0000-000000164062")
        let nestedSequenceID = try uuid("00000000-0000-0000-0000-000000164063")
        let nested = Sequence(
            id: nestedSequenceID,
            name: "Nested",
            videoTracks: [],
            audioTracks: [
                try makeTrack(items: [
                    .clip(
                        try makeClip(
                            id: try uuid("00000000-0000-0000-0000-000000164064"),
                            mediaID: mediaID,
                            duration: try time(1, 1)
                        ))
                ])
            ],
            markers: [],
            timebase: try FrameRate(frames: 8)
        )
        var shape = CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear)
        shape.outgoingSource = .sequence(id: nestedSequenceID)
        let pair = try makeCrossfadedPair(mediaA: mediaID, mediaB: silentMediaID, shape: shape)
        let parent = Sequence(
            id: try uuid("00000000-0000-0000-0000-000000164065"),
            name: "Parent",
            videoTracks: [],
            audioTracks: [try makeTrack(items: pair)],
            markers: [],
            timebase: try FrameRate(frames: 8)
        )
        let project = try makeCrossfadeProject(sequences: [parent, nested], media: [])

        let output = try OfflineAudioMixer.render(
            project: project,
            sequence: parent,
            range: try TimeRange(start: .zero, duration: time(1, 1)),
            sourceProvider: InMemoryAudioSourceProvider(sources: [
                mediaID: try crossfadeStaircaseSource(),
                silentMediaID: try crossfadeConstantSource(0)
            ])
        )

        assertSamples(output.samples, equal: stereoFrames([1, 2, 3, 4, 5, 4.5, 3.5, 2]))
    }

    // MARK: - §7 EOF silence-padding vs provider under-delivery

    func testFRAUD002TailPastDeclaredMediaDurationSilencePadsDeterministically() throws {
        // The media pool declares 5/8s (media drifted after validation): tail reads inside
        // the declared bounds play, reads past them are silence — even when the provider
        // happens to deliver extra frames beyond the declared end.
        let mediaA = try uuid("00000000-0000-0000-0000-000000164071")
        let mediaB = try uuid("00000000-0000-0000-0000-000000164072")
        let pair = try makeCrossfadedPair(
            mediaA: mediaA,
            mediaB: mediaB,
            shape: CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear)
        )
        let sequence = try makeSequence(items: pair)
        let project = try makeCrossfadeProject(
            sequences: [sequence],
            media: [
                makeCrossfadeMediaRef(id: mediaA, declaredDuration: try time(5, 8)),
                makeCrossfadeMediaRef(id: mediaB, declaredDuration: try time(1, 1))
            ]
        )
        let expected = stereoFrames([1, 2, 3, 4, 5, 0, 0, 0])

        for providedFrames in [5, 8] {
            let provided = Array([Float]([1, 2, 3, 4, 5, 6, 7, 8]).prefix(providedFrames))
            let output = try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: try TimeRange(start: .zero, duration: time(1, 1)),
                sourceProvider: InMemoryAudioSourceProvider(sources: [
                    mediaA: try crossfadeMonoSource(provided),
                    mediaB: try crossfadeConstantSource(0)
                ])
            )
            assertSamples(output.samples, equal: expected)
        }
    }

    func testFRAUD002ProviderUnderDeliveryWithinDeclaredBoundsThrowsTypedError() throws {
        // The pool declares a full second but the provider returns only 5 frames: the tail
        // frames [5/8, 1) are inside the declared bounds, so this is a decoder fault and must
        // surface as sourceUnderDelivered — never silent zeros.
        let mediaA = try uuid("00000000-0000-0000-0000-000000164081")
        let mediaB = try uuid("00000000-0000-0000-0000-000000164082")
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
        let expectedMissing = try TimeRange(start: time(5, 8), duration: time(3, 8))

        XCTAssertThrowsError(
            try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: try TimeRange(start: .zero, duration: time(1, 1)),
                sourceProvider: InMemoryAudioSourceProvider(sources: [
                    mediaA: try crossfadeMonoSource([1, 2, 3, 4, 5]),
                    mediaB: try crossfadeConstantSource(0)
                ])
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

extension OfflineAudioCrossfadeMixerTests {
    private func makeCompoundOutgoingClip(
        sequenceID: UUID,
        crossfadeDuration: RationalTime?
    ) throws -> Clip {
        var audioMix = ClipAudioMix.identity
        if let crossfadeDuration {
            audioMix = ClipAudioMix(
                trailingCrossfade: ClipAudioCrossfade(
                    partnerClipID: crossfadeIncomingClipID,
                    duration: crossfadeDuration,
                    curve: .linear
                )
            )
        }
        return Clip(
            id: crossfadeOutgoingClipID,
            source: .sequence(id: sequenceID),
            sourceRange: try TimeRange(start: .zero, duration: time(1, 2)),
            timelineRange: try TimeRange(start: .zero, duration: time(1, 2)),
            kind: .audio,
            name: "Compound",
            audioMix: audioMix
        )
    }

    private func renderEightFrames(
        items: [TimelineItem],
        sources: [UUID: AudioSourceBuffer]
    ) throws -> RenderedAudioBuffer {
        try OfflineAudioMixer.render(
            sequence: makeSequence(items: items),
            range: TimeRange(start: .zero, duration: time(1, 1)),
            format: crossfadeRenderFormat,
            sourceProvider: InMemoryAudioSourceProvider(sources: sources)
        )
    }
}
