// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

@testable import AjarAudio

func plannerProject(
    sequences: [Sequence],
    sampleRate: Int = 48_000
) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 30),
            resolution: PixelDimensions(width: 16, height: 16),
            colorSpace: .rec709,
            audioSampleRate: sampleRate
        ),
        mediaPool: [],
        sequences: sequences
    )
}

func plannerSequence(
    id: UUID = UUID(),
    tracks: [Track],
    videoTracks: [Track] = [],
    ducking: [AudioDuckingRule] = []
) throws -> Sequence {
    Sequence(
        id: id,
        name: "Planner",
        videoTracks: videoTracks,
        audioTracks: tracks,
        markers: [],
        audioDucking: ducking,
        timebase: try FrameRate(frames: 30)
    )
}

func plannerClip(
    id: UUID = UUID(),
    source: ClipSource,
    sourceStart: RationalTime,
    sourceDuration: RationalTime,
    timelineStart: RationalTime,
    timelineDuration: RationalTime,
    audioMix: ClipAudioMix = .identity,
    speed: RationalValue = .one,
    reverse: Bool = false,
    freezeFrame: Bool = false,
    timeRemap: ClipTimeRemap? = nil,
    kind: TrackKind = .audio
) throws -> Clip {
    Clip(
        id: id,
        source: source,
        sourceRange: try TimeRange(start: sourceStart, duration: sourceDuration),
        timelineRange: try TimeRange(start: timelineStart, duration: timelineDuration),
        kind: kind,
        name: "Planned audio",
        audioMix: audioMix,
        speed: speed,
        reverse: reverse,
        freezeFrame: freezeFrame,
        timeRemap: timeRemap
    )
}

func plannerPlan(
    clip: Clip,
    range: TimeRange,
    sampleRate: Int = 48_000
) throws -> AudioSourcePlan {
    let sequence = try plannerSequence(tracks: [makeTrack(items: [.clip(clip)])])
    return try AudioSourcePlanner.plan(
        project: plannerProject(sequences: [sequence], sampleRate: sampleRate),
        sequence: sequence,
        range: range
    )
}

func plannerRange(_ start: RationalTime, _ duration: RationalTime) throws -> TimeRange {
    try TimeRange(start: start, duration: duration)
}
