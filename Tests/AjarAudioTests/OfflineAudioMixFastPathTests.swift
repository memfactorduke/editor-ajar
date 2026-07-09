// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// Differential and eligibility coverage for the FR-AUD-007 off-RT bulk mix path (#178).
final class OfflineAudioMixFastPathTests: XCTestCase {
    // MARK: - Differential property: fast path == exact path bit-for-bit

    func testFRAUD007FastPathSingleUglyGainPanIsBitwiseIdentical() throws {
        try assertFastMatchesExact(
            FastPathDiffCase(
                gain: 0.7,
                pan: 0.5,
                ducking: nil,
                sourceChannels: 2,
                outputChannels: 2,
                frameOffset: 0,
                sampleRate: 4,
                label: "single ugly gain/pan"
            )
        )
    }

    func testFRAUD007FastPathIsBitwiseIdenticalToExactPathAcrossRandomStaticConfigs() throws {
        // Ugly static values where Float multiply order vs the slow path is stressed.
        let gainCases: [Double] = [0.7, 1.3, 0.25, 1.75, 0.333333, 2.5]
        let panCases: [Double] = [-1, -0.5, -0.25, 0, 0.25, 0.5, 1]
        let duckCases: [[Double]?] = [
            nil,
            [1, 1, 1, 1],
            [0.5, 0.75, 1.0, 0.25],
            [0.1, 0.2, 0.3, 0.4]
        ]
        let layouts: [(sourceChannels: Int, outputChannels: Int)] = [
            (1, 2),
            (2, 2),
            (6, 2),
            (2, 1)
        ]
        let frameOffsets = [0, 2, 5]
        let sampleRate = 4
        var caseIndex = 0

        for gainD in gainCases {
            for panD in panCases {
                for ducking in duckCases {
                    for layout in layouts {
                        for frameOffset in frameOffsets {
                            caseIndex += 1
                            try assertFastMatchesExact(
                                FastPathDiffCase(
                                    gain: gainD,
                                    pan: panD,
                                    ducking: ducking,
                                    sourceChannels: layout.sourceChannels,
                                    outputChannels: layout.outputChannels,
                                    frameOffset: frameOffset,
                                    sampleRate: sampleRate,
                                    label: "case \(caseIndex)"
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Eligibility: dynamic / retimed configs refuse the fast path

    func testFRAUD007OptimizedPathRejectsKeyframedGain() throws {
        let keyframes = [
            Keyframe(
                time: .zero,
                value: RationalValue.approximating(0.5),
                interpolation: InterpolationMode.linear
            ),
            Keyframe(
                time: try time(1, 1),
                value: RationalValue.approximating(1.5),
                interpolation: InterpolationMode.linear
            )
        ]
        let state = try makeFastPathState(
            audioMix: ClipAudioMix(gain: try Animatable(base: .one, keyframes: keyframes))
        )
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsFadeIn() throws {
        let state = try makeFastPathState(
            audioMix: ClipAudioMix(fadeIn: ClipAudioFade(duration: try time(1, 4)))
        )
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsFadeOut() throws {
        let state = try makeFastPathState(
            audioMix: ClipAudioMix(fadeOut: ClipAudioFade(duration: try time(1, 4)))
        )
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsLeadingCrossfade() throws {
        let partner = try uuid("00000000-0000-0000-0000-000000085901")
        let state = try makeFastPathState(
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: partner,
                    duration: try time(1, 4)
                )
            )
        )
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsTrailingCrossfade() throws {
        let partner = try uuid("00000000-0000-0000-0000-000000085902")
        let state = try makeFastPathState(
            audioMix: ClipAudioMix(
                trailingCrossfade: ClipAudioCrossfade(
                    partnerClipID: partner,
                    duration: try time(1, 4)
                )
            )
        )
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsDeclaredTailEOF() throws {
        let state = try makeFastPathState(declaredTailSourceEndFrame: 2)
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsReverse() throws {
        let state = try makeFastPathState(reverse: true)
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsNonUnitSpeed() throws {
        let state = try makeFastPathState(speed: RationalValue(2))
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsFreezeFrame() throws {
        let state = try makeFastPathState(freezeFrame: true)
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsTimeRemap() throws {
        let curve = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: .zero, sourceTime: .zero),
            TimeRemapKeyframe(time: try time(1, 1), sourceTime: try time(1, 1))
        ])
        let state = try makeFastPathState(timeRemap: curve)
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathRejectsStretchedRead() throws {
        let state = try makeFastPathState(
            stretchedRead: OfflineStretchedReadState(startFrame: 0, anchor: .zero)
        )
        try assertOptimizedReturnsFalse(state: state, ducking: nil)
    }

    func testFRAUD007OptimizedPathAcceptsUnitRateStaticEnvelope() throws {
        let state = try makeFastPathState()
        let context = try makeTrackMixContext(ducking: nil, frameCount: 4, sampleRate: 4)
        let intersection = 0..<4
        var output = Array(repeating: Float(0), count: 8)
        let handled = try OfflineAudioMixer.mixClipOptimized(
            state: state,
            into: &output,
            context: context,
            intersection: intersection
        )
        XCTAssertTrue(handled)
    }
}

// MARK: - Helpers

/// Bundle of differential-test mix parameters (keeps helper arity within lint limits).
private struct FastPathDiffCase {
    let gain: Double
    let pan: Double
    let ducking: [Double]?
    let sourceChannels: Int
    let outputChannels: Int
    let frameOffset: Int
    let sampleRate: Int
    let label: String
}

/// Resolved fixtures for one differential comparison run.
private struct FastPathDiffFixtures {
    let state: OfflineClipMixState
    let context: OfflineTrackMixContext
    let intersection: Range<Int>
    let sampleCount: Int
}

private extension OfflineAudioMixFastPathTests {
    func assertFastMatchesExact(_ config: FastPathDiffCase) throws {
        let fixtures = try makeDiffFixtures(config: config, frameCount: 4)

        var fast = Array(repeating: Float(0), count: fixtures.sampleCount)
        let handled = try OfflineAudioMixer.mixClipOptimized(
            state: fixtures.state,
            into: &fast,
            context: fixtures.context,
            intersection: fixtures.intersection
        )
        XCTAssertTrue(handled, "\(config.label): expected fast path to handle unit-rate case")

        var exact = Array(repeating: Float(0), count: fixtures.sampleCount)
        try OfflineAudioMixer.mixClipExact(
            state: fixtures.state,
            into: &exact,
            context: fixtures.context,
            intersection: fixtures.intersection
        )
        XCTAssertEqual(fast, exact, diffFailureMessage(config))
        try assertMixClipForceExactMatches(
            state: fixtures.state,
            context: fixtures.context,
            sampleCount: fixtures.sampleCount
        )
    }

    func makeDiffFixtures(
        config: FastPathDiffCase,
        frameCount: Int
    ) throws -> FastPathDiffFixtures {
        // Buffer window starts at `frameOffset`; clip sourceRange starts there so unit-rate
        // integer bulk path can index into the delivered frames (buffer-edge coverage).
        let source = try makeSourceBuffer(
            channels: config.sourceChannels,
            frameCount: frameCount + 2,
            frameOffset: config.frameOffset,
            sampleRate: config.sampleRate
        )
        let sourceStart = try time(Int64(config.frameOffset), Int64(config.sampleRate))
        let state = try makeFastPathState(
            gain: config.gain,
            pan: config.pan,
            source: source,
            sourceStart: sourceStart,
            duration: try time(Int64(frameCount), Int64(config.sampleRate)),
            sampleRate: config.sampleRate
        )
        let context = try makeTrackMixContext(
            ducking: config.ducking,
            frameCount: frameCount,
            sampleRate: config.sampleRate,
            channelCount: config.outputChannels
        )
        return FastPathDiffFixtures(
            state: state,
            context: context,
            intersection: 0..<frameCount,
            sampleCount: frameCount * config.outputChannels
        )
    }

    func assertMixClipForceExactMatches(
        state: OfflineClipMixState,
        context: OfflineTrackMixContext,
        sampleCount: Int
    ) throws {
        var viaMixClip = Array(repeating: Float(0), count: sampleCount)
        try OfflineAudioMixer.mixClip(
            state: state,
            into: &viaMixClip,
            context: context,
            forceExact: false
        )
        var viaForceExact = Array(repeating: Float(0), count: sampleCount)
        try OfflineAudioMixer.mixClip(
            state: state,
            into: &viaForceExact,
            context: context,
            forceExact: true
        )
        XCTAssertEqual(viaMixClip, viaForceExact)
    }

    func diffFailureMessage(_ config: FastPathDiffCase) -> String {
        "\(config.label): gain=\(config.gain) pan=\(config.pan) "
            + "srcCh=\(config.sourceChannels) outCh=\(config.outputChannels) "
            + "offset=\(config.frameOffset) duck=\(String(describing: config.ducking))"
    }

    func assertOptimizedReturnsFalse(
        state: OfflineClipMixState,
        ducking: [Double]?
    ) throws {
        let context = try makeTrackMixContext(ducking: ducking, frameCount: 4, sampleRate: 4)
        var output = Array(repeating: Float(0), count: 8)
        let handled = try OfflineAudioMixer.mixClipOptimized(
            state: state,
            into: &output,
            context: context,
            intersection: 0..<4
        )
        XCTAssertFalse(handled)
    }

    func makeFastPathState(
        audioMix: ClipAudioMix? = nil,
        gain: Double = 1,
        pan: Double = 0,
        source: AudioSourceBuffer? = nil,
        sourceStart: RationalTime = .zero,
        duration: RationalTime? = nil,
        sampleRate: Int = 4,
        speed: RationalValue = .one,
        reverse: Bool = false,
        freezeFrame: Bool = false,
        timeRemap: ClipTimeRemap? = nil,
        declaredTailSourceEndFrame: Double? = nil,
        stretchedRead: OfflineStretchedReadState? = nil
    ) throws -> OfflineClipMixState {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085800")
        let mix: ClipAudioMix
        if let audioMix {
            mix = audioMix
        } else {
            mix = ClipAudioMix(
                gain: .constant(RationalValue.approximating(gain)),
                pan: .constant(RationalValue.approximating(pan))
            )
        }
        let clipDuration = try duration ?? time(1, 1)
        let clip = try makeClip(
            mediaID: mediaID,
            sourceStart: sourceStart,
            duration: clipDuration,
            audioMix: mix,
            speed: speed,
            reverse: reverse,
            freezeFrame: freezeFrame,
            timeRemap: timeRemap
        )
        let track = try makeTrack(items: [.clip(clip)])
        let resolvedSource: AudioSourceBuffer
        if let source {
            resolvedSource = source
        } else {
            resolvedSource = try makeSourceBuffer(
                channels: 1,
                frameCount: sampleRate,
                frameOffset: 0,
                sampleRate: sampleRate
            )
        }
        return OfflineClipMixState(
            clip: clip,
            track: track,
            source: resolvedSource,
            declaredTailSourceEndFrame: declaredTailSourceEndFrame,
            stretchedRead: stretchedRead
        )
    }

    func makeTrackMixContext(
        ducking: [Double]?,
        frameCount: Int,
        sampleRate: Int,
        channelCount: Int = 2
    ) throws -> OfflineTrackMixContext {
        OfflineTrackMixContext(
            mix: OfflineMixContext(
                frameCount: frameCount,
                range: try TimeRange(
                    start: .zero,
                    duration: try time(Int64(frameCount), Int64(sampleRate))
                ),
                format: AudioRenderFormat(sampleRate: sampleRate, channelCount: channelCount)
            ),
            duckingMultipliers: ducking
        )
    }

    func makeSourceBuffer(
        channels: Int,
        frameCount: Int,
        frameOffset: Int,
        sampleRate: Int
    ) throws -> AudioSourceBuffer {
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * channels)
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                // Deterministic non-trivial pattern so pan/gain rounding is exercised.
                let value = Float(frame + 1) * 0.1 + Float(channel) * 0.01
                samples.append(value)
            }
        }
        return try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: channels),
            frameCount: frameCount,
            samples: samples,
            frameOffset: frameOffset
        )
    }
}
