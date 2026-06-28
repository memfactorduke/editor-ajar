// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class OfflineAudioMixerTests: XCTestCase {
    func testFRAUD003MixesGainPanFadeAndClampsOvershootingAutomation() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085001")
        let clip = try makeClip(
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                gain: overshootingGain(),
                pan: .constant(RationalValue(2)),
                fadeIn: ClipAudioFade(duration: time(1, 2))
            )
        )
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [1, 1, 1, 1],
            sourceSampleRate: 4
        )

        assertSamples(buffer.samples, equal: [0, 0, 0, 2, 0, 4, 0, 4])
    }

    func testFRAUD009ResamplesAndMapsMonoSourceToStereoOutput() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000085002")
        let clip = try makeClip(mediaID: mediaID, duration: time(1, 1))
        let buffer = try render(
            clip: clip,
            mediaID: mediaID,
            sourceSamples: [0, 1],
            sourceSampleRate: 2
        )

        assertSamples(buffer.samples, equal: [0, 0, 0.5, 0.5, 1, 1, 1, 1])
    }

    func testFRAUD007RealtimePlanReportsNoLocksOrRenderAllocation() throws {
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
            frameCount: 2,
            samples: [1, 2, 3, 4]
        )
        var plan = RealtimeAudioRenderPlan(buffer: buffer)

        XCTAssertEqual(
            plan.safetyReport(),
            RealtimeAudioSafetyReport(
                usesLocks: false,
                allocatesDuringRender: false,
                preparedFrameCount: 2
            )
        )

        var output = [Float](repeating: -1, count: 6)
        let copied = output.withUnsafeMutableBufferPointer { pointer in
            plan.render(into: pointer)
        }

        XCTAssertEqual(copied, 2)
        XCTAssertEqual(output, [1, 2, 3, 4, 0, 0])
    }

    func testCrossfadePartnerMustBeRealAdjacentClip() throws {
        let firstClipID = try uuid("00000000-0000-0000-0000-000000085101")
        let secondClipID = try uuid("00000000-0000-0000-0000-000000085102")
        let mediaID = try uuid("00000000-0000-0000-0000-000000085103")
        let firstClip = try makeClip(id: firstClipID, mediaID: mediaID, duration: time(1, 1))
        let secondClip = try makeClip(
            id: secondClipID,
            mediaID: mediaID,
            timelineStart: time(2, 1),
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: firstClipID,
                    duration: time(1, 2)
                )
            )
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
                    edge: .leadingCrossfade,
                    clipID: secondClipID,
                    partnerClipID: firstClipID
                )
            )
        }
    }

    func testCrossfadePartnerMustExistOnOwningTrack() throws {
        let clipID = try uuid("00000000-0000-0000-0000-000000085201")
        let mediaID = try uuid("00000000-0000-0000-0000-000000085202")
        let missingPartnerID = try uuid("00000000-0000-0000-0000-000000085203")
        let clip = try makeClip(
            id: clipID,
            mediaID: mediaID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: missingPartnerID,
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
                .crossfadePartnerMissing(
                    edge: .leadingCrossfade,
                    clipID: clipID,
                    partnerClipID: missingPartnerID
                )
            )
        }
    }
}

private func render(
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

private func makeClip(
    id: UUID? = nil,
    mediaID: UUID,
    timelineStart: RationalTime = .zero,
    duration: RationalTime,
    audioMix: ClipAudioMix = .identity
) throws -> Clip {
    let clipID: UUID
    if let id {
        clipID = id
    } else {
        clipID = try uuid("00000000-0000-0000-0000-000000085301")
    }
    return Clip(
        id: clipID,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(start: timelineStart, duration: duration),
        kind: .audio,
        name: "Audio",
        audioMix: audioMix
    )
}

private func makeSequence(items: [TimelineItem]) throws -> Sequence {
    Sequence(
        id: try uuid("00000000-0000-0000-0000-000000085401"),
        name: "Audio Mix",
        videoTracks: [],
        audioTracks: [
            Track(
                id: try uuid("00000000-0000-0000-0000-000000085402"),
                kind: .audio,
                items: items
            )
        ],
        markers: [],
        timebase: try FrameRate(frames: 4)
    )
}

private func overshootingGain() throws -> Animatable<RationalValue> {
    let curve = CubicBezierTimingCurve(
        controlPoint1: CubicBezierTimingControlPoint(
            x: .zero,
            y: RationalValue(4)
        ),
        controlPoint2: CubicBezierTimingControlPoint(
            x: .one,
            y: RationalValue(4)
        )
    )
    return try Animatable(
        base: .one,
        keyframes: [
            Keyframe(time: .zero, value: .zero, interpolation: .bezier(curve)),
            Keyframe(time: time(1, 2), value: RationalValue(4), interpolation: .linear)
        ]
    )
}

private func assertSamples(
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

private func time(_ value: Int64, _ timescale: Int64) throws -> RationalTime {
    try RationalTime(value: value, timescale: timescale)
}

private func uuid(_ value: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: value))
}
