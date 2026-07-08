// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// Shared fixtures for FR-SPD-001 pitch-corrected mixer tests.
struct CrossfadePairFixture {
    let clips: [Clip]
    let sources: [UUID: AudioSourceBuffer]
}

/// One pitch-corrected 2x clip with a 0.1 s linear trailing crossfade into an abutting
/// silent clip carrying the mirroring leading record (ADR-0015 pair taxonomy).
func makeCrossfadePair(
    source: [Float],
    tailRate: Int
) throws -> CrossfadePairFixture {
    let mediaID = try uuid("00000000-0000-0000-0000-000000086008")
    let silentID = try uuid("00000000-0000-0000-0000-000000086009")
    let clipAID = try uuid("00000000-0000-0000-0000-000000086010")
    let clipBID = try uuid("00000000-0000-0000-0000-000000086011")
    let crossfadeDuration = try time(1, 10)
    let crossfade = ClipAudioCrossfade(
        partnerClipID: clipBID,
        duration: crossfadeDuration,
        curve: .linear
    )
    let mirror = ClipAudioCrossfade(
        partnerClipID: clipAID,
        duration: crossfadeDuration,
        curve: .linear
    )
    let clipA = try makeRetimedClip(
        id: clipAID,
        mediaID: mediaID,
        speed: try RationalValue(numerator: 2, denominator: 1),
        retimeMode: .pitchCorrected,
        sourceDurationFrames: tailRate,
        sampleRate: tailRate,
        audioMix: ClipAudioMix(trailingCrossfade: crossfade, retimeMode: .pitchCorrected)
    )
    let clipB = try makeRetimedClip(
        id: clipBID,
        mediaID: silentID,
        speed: .one,
        retimeMode: .pitchShifted,
        timelineStartFrames: 500,
        sourceDurationFrames: 400,
        sampleRate: tailRate,
        audioMix: ClipAudioMix(leadingCrossfade: mirror)
    )
    return CrossfadePairFixture(
        clips: [clipA, clipB],
        sources: [
            mediaID: try monoSource(source, sampleRate: tailRate),
            silentID: try monoSource([Float](repeating: 0, count: 400), sampleRate: tailRate)
        ]
    )
}

/// One unit-speed clip whose source range starts on a fractional sample (100.5 frames), with
/// a 0.1 s linear trailing crossfade into an abutting silent clip, used to prove unit-speed
/// pitch-corrected playback is bit-identical to varispeed, tail included.
func makeFractionalStartPair(
    retimeMode: ClipAudioRetimeMode,
    source: [Float],
    rate: Int
) throws -> CrossfadePairFixture {
    let mediaID = try uuid("00000000-0000-0000-0000-000000086016")
    let silentID = try uuid("00000000-0000-0000-0000-000000086017")
    let clipAID = try uuid("00000000-0000-0000-0000-000000086018")
    let clipBID = try uuid("00000000-0000-0000-0000-000000086019")
    let crossfadeDuration = try time(1, 10)
    let clipA = try makeRetimedClip(
        id: clipAID,
        mediaID: mediaID,
        speed: .one,
        retimeMode: retimeMode,
        // 100.5 source frames: half a sample past a frame boundary.
        sourceStart: try time(201, Int64(rate) * 2),
        sourceDurationFrames: rate,
        sampleRate: rate,
        audioMix: ClipAudioMix(
            trailingCrossfade: ClipAudioCrossfade(
                partnerClipID: clipBID,
                duration: crossfadeDuration,
                curve: .linear
            ),
            retimeMode: retimeMode
        )
    )
    let clipB = try makeRetimedClip(
        id: clipBID,
        mediaID: silentID,
        speed: .one,
        retimeMode: .pitchShifted,
        timelineStartFrames: Int64(rate),
        sourceDurationFrames: 400,
        sampleRate: rate,
        audioMix: ClipAudioMix(
            leadingCrossfade: ClipAudioCrossfade(
                partnerClipID: clipAID,
                duration: crossfadeDuration,
                curve: .linear
            )
        )
    )
    return CrossfadePairFixture(
        clips: [clipA, clipB],
        sources: [
            mediaID: try monoSource(source, sampleRate: rate),
            silentID: try monoSource([Float](repeating: 0, count: 400), sampleRate: rate)
        ]
    )
}

func makeRetimedClip(
    id: UUID,
    mediaID: UUID,
    speed: RationalValue,
    retimeMode: ClipAudioRetimeMode,
    reverse: Bool = false,
    freezeFrame: Bool = false,
    timelineStartFrames: Int64 = 0,
    sourceStart: RationalTime = .zero,
    sourceDurationFrames: Int,
    sampleRate: Int = 2_000,
    audioMix: ClipAudioMix? = nil
) throws -> Clip {
    let rate = Int64(sampleRate)
    let sourceDuration = try time(Int64(sourceDurationFrames), rate)
    let timelineDuration = freezeFrame
        ? sourceDuration
        : try Clip.timelineDuration(forSourceDuration: sourceDuration, speed: speed)
    return Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: sourceStart, duration: sourceDuration),
        timelineRange: try TimeRange(
            start: try time(timelineStartFrames, rate),
            duration: timelineDuration
        ),
        kind: .audio,
        name: "Retimed Audio",
        audioMix: audioMix ?? ClipAudioMix(retimeMode: retimeMode),
        speed: speed,
        reverse: reverse,
        freezeFrame: freezeFrame
    )
}

func monoSource(_ samples: [Float], sampleRate: Int) throws -> AudioSourceBuffer {
    try AudioSourceBuffer(
        format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
        frameCount: samples.count,
        samples: samples
    )
}
