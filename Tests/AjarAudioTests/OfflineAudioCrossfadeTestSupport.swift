// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarAudio

/// Shared FR-AUD-002 crossfade fixture vocabulary (8 kHz stereo renders).
let crossfadeRenderFormat = AudioRenderFormat(sampleRate: 8, channelCount: 2)

/// Deterministic ID of the outgoing (trailing-record) clip in crossfade pair fixtures.
let crossfadeOutgoingClipID = UUID(
    uuidString: "00000000-0000-0000-0000-000000164101"
) ?? UUID()

/// Deterministic ID of the incoming (leading-mirror) clip in crossfade pair fixtures.
let crossfadeIncomingClipID = UUID(
    uuidString: "00000000-0000-0000-0000-000000164102"
) ?? UUID()

/// Retime and source options for a crossfaded pair fixture.
struct CrossfadePairShape {
    var crossfadeDuration: RationalTime
    var curve: ClipAudioFadeCurve
    var outgoingSource: ClipSource?
    var outgoingSourceStart: RationalTime = .zero
    var outgoingSpeed: RationalValue = .one
    var outgoingReverse = false
    var outgoingFreezeFrame = false
    var outgoingTimelineDuration: RationalTime?
    var incomingSourceStart: RationalTime = .zero
}

/// Builds a valid ADR-0015 §5 pair: the outgoing clip owns the trailing record, the incoming
/// clip mirrors it, both clips abut at the cut.
func makeCrossfadedPair(
    mediaA: UUID,
    mediaB: UUID,
    shape: CrossfadePairShape
) throws -> [TimelineItem] {
    let timelineDuration = try shape.outgoingTimelineDuration ?? time(1, 2)
    let sourceDuration = try Clip.sourceDuration(
        forTimelineDuration: timelineDuration,
        speed: shape.outgoingSpeed
    )
    let outgoing = Clip(
        id: crossfadeOutgoingClipID,
        source: shape.outgoingSource ?? .media(id: mediaA),
        sourceRange: try TimeRange(start: shape.outgoingSourceStart, duration: sourceDuration),
        timelineRange: try TimeRange(start: .zero, duration: timelineDuration),
        kind: .audio,
        name: "Outgoing",
        audioMix: ClipAudioMix(
            trailingCrossfade: ClipAudioCrossfade(
                partnerClipID: crossfadeIncomingClipID,
                duration: shape.crossfadeDuration,
                curve: shape.curve
            )
        ),
        speed: shape.outgoingSpeed,
        reverse: shape.outgoingReverse,
        freezeFrame: shape.outgoingFreezeFrame
    )
    let incoming = try makeClip(
        id: crossfadeIncomingClipID,
        mediaID: mediaB,
        sourceStart: shape.incomingSourceStart,
        timelineStart: timelineDuration,
        duration: try time(1, 2),
        audioMix: ClipAudioMix(
            leadingCrossfade: ClipAudioCrossfade(
                partnerClipID: crossfadeOutgoingClipID,
                duration: shape.crossfadeDuration,
                curve: shape.curve
            )
        )
    )
    return [.clip(outgoing), .clip(incoming)]
}

/// Project wrapper for crossfade fixtures (8 kHz audio settings).
func makeCrossfadeProject(sequences: [Sequence], media: [MediaRef]) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 8),
            resolution: PixelDimensions(width: 16, height: 16),
            colorSpace: .rec709,
            audioSampleRate: crossfadeRenderFormat.sampleRate
        ),
        mediaPool: media,
        sequences: sequences
    )
}

/// Media-pool entry declaring an exact media duration (ADR-0015 §7 declared bounds).
func makeCrossfadeMediaRef(id: UUID, declaredDuration: RationalTime) -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: nil,
        contentHash: nil,
        metadata: MediaMetadata(
            codecID: "pcm_f32le",
            pixelDimensions: nil,
            frameRate: nil,
            duration: declaredDuration,
            colorSpace: .unspecified,
            audioChannelLayout: AudioChannelLayout(channelCount: 1),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

/// Ascending staircase mono source `[1..8]` at the crossfade fixture sample rate.
func crossfadeStaircaseSource() throws -> AudioSourceBuffer {
    try crossfadeMonoSource([1, 2, 3, 4, 5, 6, 7, 8])
}

/// Constant-valued 8-frame mono source at the crossfade fixture sample rate.
func crossfadeConstantSource(_ value: Float) throws -> AudioSourceBuffer {
    try crossfadeMonoSource([Float](repeating: value, count: 8))
}

/// Mono source buffer at the crossfade fixture sample rate.
func crossfadeMonoSource(_ samples: [Float]) throws -> AudioSourceBuffer {
    try AudioSourceBuffer(
        format: AudioRenderFormat(
            sampleRate: crossfadeRenderFormat.sampleRate,
            channelCount: 1
        ),
        frameCount: samples.count,
        samples: samples
    )
}

/// Duplicates mono frames into the stereo interleaved layout the mixer emits.
func stereoFrames(_ frames: [Float]) -> [Float] {
    frames.flatMap { [$0, $0] }
}
