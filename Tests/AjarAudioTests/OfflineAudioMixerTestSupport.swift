// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

func render(
    clip: Clip,
    mediaID: UUID,
    sourceSamples: [Float],
    sourceSampleRate: Int
) throws -> RenderedAudioBuffer {
    let source = try AudioSourceBuffer(
        format: AudioRenderFormat(sampleRate: sourceSampleRate, channelCount: 1),
        frameCount: sourceSamples.count,
        samples: sourceSamples
    )
    return try OfflineAudioMixer.render(
        sequence: makeSequence(items: [.clip(clip)]),
        range: TimeRange(start: .zero, duration: time(1, 1)),
        format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
        sourceProvider: InMemoryAudioSourceProvider(sources: [mediaID: source])
    )
}

func render(
    sequence: Sequence,
    sources: [UUID: AudioSourceBuffer],
    duration: RationalTime? = nil
) throws -> RenderedAudioBuffer {
    let renderDuration: RationalTime
    if let duration {
        renderDuration = duration
    } else {
        renderDuration = try time(1, 1)
    }
    return try OfflineAudioMixer.render(
        sequence: sequence,
        range: TimeRange(start: .zero, duration: renderDuration),
        format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
        sourceProvider: InMemoryAudioSourceProvider(sources: sources)
    )
}

func audioSource(samples: [Float]) throws -> AudioSourceBuffer {
    try AudioSourceBuffer(
        format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
        frameCount: samples.count,
        samples: samples
    )
}

func makeClip(
    id: UUID? = nil,
    mediaID: UUID,
    sourceStart: RationalTime = .zero,
    timelineStart: RationalTime = .zero,
    duration: RationalTime,
    audioMix: ClipAudioMix = .identity
) throws -> Clip {
    let clipID = try id ?? uuid("00000000-0000-0000-0000-000000085301")
    return Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: sourceStart, duration: duration),
        timelineRange: try TimeRange(start: timelineStart, duration: duration),
        kind: .audio,
        name: "Audio",
        audioMix: audioMix
    )
}

func makeSequence(items: [TimelineItem]) throws -> Sequence {
    try makeSequence(tracks: [makeTrack(items: items)])
}

func makeSequence(
    tracks: [Track],
    audioDucking: [AudioDuckingRule] = []
) throws -> Sequence {
    Sequence(
        id: try uuid("00000000-0000-0000-0000-000000085401"),
        name: "Audio Mix",
        videoTracks: [],
        audioTracks: tracks,
        markers: [],
        audioDucking: audioDucking,
        timebase: try FrameRate(frames: 4)
    )
}

func makeTrack(
    id: UUID? = nil,
    items: [TimelineItem],
    enabled: Bool = true,
    muted: Bool = false,
    solo: Bool = false,
    audioGain: Animatable<RationalValue> = .constant(.one),
    audioPan: Animatable<RationalValue> = .constant(.zero)
) throws -> Track {
    let trackID = id ?? UUID()
    return Track(
        id: trackID,
        kind: .audio,
        items: items,
        enabled: enabled,
        muted: muted,
        solo: solo,
        audioGain: audioGain,
        audioPan: audioPan
    )
}

func assertSamples(
    _ actual: [Float],
    equal expected: [Float],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for index in actual.indices {
        XCTAssertEqual(actual[index], expected[index], accuracy: 0.00001, file: file, line: line)
    }
}

func time(_ value: Int64, _ timescale: Int64) throws -> RationalTime {
    try RationalTime(value: value, timescale: timescale)
}

func uuid(_ value: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: value))
}
