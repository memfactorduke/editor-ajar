// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// FR-AUD-002 / FR-AUD-003 meter parity across a crossfaded cut: `AudioMixerMeterAnalyzer`
/// reuses the mixer path, so its readings must agree exactly with the rendered mix —
/// including the ADR-0015 fade-tail region past the outgoing clip's out-point.
final class AudioCrossfadeMeterParityTests: XCTestCase {
    func testFRAUD002FRAUD003MeterAgreesWithRenderAcrossCorrelatedLinearCrossfade() throws {
        // A blade-split staircase rejoined by a linear crossfade renders the uncut source
        // [1..8]; the peak of 8 lands inside the transition region, so agreement here
        // proves the meter includes the outgoing tail.
        let mediaID = try uuid("00000000-0000-0000-0000-000000165001")
        var shape = CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .linear)
        shape.incomingSourceStart = try time(1, 2)
        let sequence = try makeSequence(
            items: makeCrossfadedPair(mediaA: mediaID, mediaB: mediaID, shape: shape)
        )
        let sources = [mediaID: try crossfadeStaircaseSource()]
        let range = try TimeRange(start: .zero, duration: time(1, 1))

        let rendered = try OfflineAudioMixer.render(
            sequence: sequence,
            range: range,
            format: crossfadeRenderFormat,
            sourceProvider: InMemoryAudioSourceProvider(sources: sources)
        )
        let report = try AudioMixerMeterAnalyzer.measure(
            sequence: sequence,
            range: range,
            format: crossfadeRenderFormat,
            sourceProvider: InMemoryAudioSourceProvider(sources: sources)
        )

        assertSamples(rendered.samples, equal: stereoFrames([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(report.mixLevels, AudioMixerMeterAnalyzer.measure(buffer: rendered))
        XCTAssertEqual(report.trackLevels.count, 1)
        XCTAssertEqual(report.trackLevels[0].levels, report.mixLevels)
        XCTAssertEqual(report.mixLevels.map(\.peak), [8, 8])
    }

    func testFRAUD002FRAUD003MeterAgreesWithRenderAcrossEqualPowerCrossfade() throws {
        // Uncorrelated constant sources under the §4 equal-power curve: the metered mix
        // must match the render sample-for-sample-derived levels through the region.
        let mediaA = try uuid("00000000-0000-0000-0000-000000165002")
        let mediaB = try uuid("00000000-0000-0000-0000-000000165003")
        let sequence = try makeSequence(
            items: makeCrossfadedPair(
                mediaA: mediaA,
                mediaB: mediaB,
                shape: CrossfadePairShape(crossfadeDuration: try time(1, 2), curve: .equalPower)
            )
        )
        let sources = [
            mediaA: try crossfadeConstantSource(0.8),
            mediaB: try crossfadeConstantSource(0.6)
        ]
        let range = try TimeRange(start: .zero, duration: time(1, 1))

        let rendered = try OfflineAudioMixer.render(
            sequence: sequence,
            range: range,
            format: crossfadeRenderFormat,
            sourceProvider: InMemoryAudioSourceProvider(sources: sources)
        )
        let report = try AudioMixerMeterAnalyzer.measure(
            sequence: sequence,
            range: range,
            format: crossfadeRenderFormat,
            sourceProvider: InMemoryAudioSourceProvider(sources: sources)
        )

        XCTAssertEqual(report.mixLevels, AudioMixerMeterAnalyzer.measure(buffer: rendered))
        XCTAssertEqual(report.trackLevels.count, 1)
        XCTAssertEqual(report.trackLevels[0].levels, report.mixLevels)
    }
}
