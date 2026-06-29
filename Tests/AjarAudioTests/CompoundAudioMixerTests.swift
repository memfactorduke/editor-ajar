// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class CompoundAudioMixerTests: XCTestCase {
    func testFRCMP001FRAUD003RendersNestedSequenceAudioWithCompoundGain() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000086001")
        let nestedSequenceID = try uuid("00000000-0000-0000-0000-000000086002")
        let parentSequenceID = try uuid("00000000-0000-0000-0000-000000086003")
        let nestedSequence = try audioSequence(
            id: nestedSequenceID,
            items: [
                .clip(try makeClip(mediaID: mediaID, duration: time(1, 1)))
            ]
        )
        let compoundClip = try makeCompoundClip(
            sequenceID: nestedSequenceID,
            duration: time(1, 1),
            audioMix: ClipAudioMix(
                gain: .constant(try RationalValue(numerator: 1, denominator: 2))
            )
        )
        let parentSequence = try audioSequence(
            id: parentSequenceID,
            items: [.clip(compoundClip)]
        )
        let project = try audioProject(sequences: [parentSequence, nestedSequence])
        let buffer = try render(
            project: project,
            sequence: parentSequence,
            sources: [mediaID: try audioSource(samples: [1, 2, 3, 4])]
        )

        assertSamples(buffer.samples, equal: [
            0.5, 0.5,
            1.0, 1.0,
            1.5, 1.5,
            2.0, 2.0
        ])
    }

    func testFRCMP001FRSPD001RetimesNestedSequenceAudioWithCompoundSpeed() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000086011")
        let nestedSequenceID = try uuid("00000000-0000-0000-0000-000000086012")
        let parentSequenceID = try uuid("00000000-0000-0000-0000-000000086013")
        let nestedSequence = try audioSequence(
            id: nestedSequenceID,
            items: [
                .clip(try makeClip(mediaID: mediaID, duration: time(1, 1)))
            ]
        )
        let compoundClip = try makeCompoundClip(
            sequenceID: nestedSequenceID,
            duration: time(1, 1),
            speed: RationalValue(2)
        )
        let parentSequence = try audioSequence(
            id: parentSequenceID,
            items: [.clip(compoundClip)]
        )
        let project = try audioProject(sequences: [parentSequence, nestedSequence])
        let buffer = try render(
            project: project,
            sequence: parentSequence,
            sources: [mediaID: try audioSource(samples: [0, 1, 2, 3])]
        )

        assertSamples(buffer.samples, equal: [
            0, 0,
            2, 2,
            0, 0,
            0, 0
        ])
    }

    func testFRCMP001FRAUD003NestedAudioCycleStopsAtTypedDepthError() throws {
        let sequenceID = try uuid("00000000-0000-0000-0000-000000086021")
        let clipID = try uuid("00000000-0000-0000-0000-000000086022")
        let compoundClip = try makeCompoundClip(
            id: clipID,
            sequenceID: sequenceID,
            duration: time(1, 1)
        )
        let sequence = try audioSequence(id: sequenceID, items: [.clip(compoundClip)])
        let project = try audioProject(sequences: [sequence])

        XCTAssertThrowsError(
            try render(project: project, sequence: sequence, sources: [:])
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .maximumCompoundNestingDepthExceeded(
                    clipID: clipID,
                    depth: RenderGraphBuilder.maximumCompoundNestingDepth
                )
            )
        }
    }

    func testFRCMP001FRAUD003MissingNestedSequenceIsTypedError() throws {
        let missingSequenceID = try uuid("00000000-0000-0000-0000-000000086031")
        let clipID = try uuid("00000000-0000-0000-0000-000000086032")
        let parentSequence = try audioSequence(
            id: try uuid("00000000-0000-0000-0000-000000086033"),
            items: [
                .clip(
                    try makeCompoundClip(
                        id: clipID,
                        sequenceID: missingSequenceID,
                        duration: time(1, 1)
                    )
                )
            ]
        )
        let project = try audioProject(sequences: [parentSequence])

        XCTAssertThrowsError(
            try render(project: project, sequence: parentSequence, sources: [:])
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .missingSequenceReference(clipID: clipID, sequenceID: missingSequenceID)
            )
        }
    }
}

private func render(
    project: Project,
    sequence: Sequence,
    sources: [UUID: AudioSourceBuffer],
    duration: RationalTime? = nil
) throws -> RenderedAudioBuffer {
    try OfflineAudioMixer.render(
        project: project,
        sequence: sequence,
        range: TimeRange(start: .zero, duration: duration ?? time(1, 1)),
        sourceProvider: InMemoryAudioSourceProvider(sources: sources)
    )
}

private func makeCompoundClip(
    id: UUID? = nil,
    sequenceID: UUID,
    sourceStart: RationalTime = .zero,
    timelineStart: RationalTime = .zero,
    duration: RationalTime,
    audioMix: ClipAudioMix = .identity,
    speed: RationalValue = .one
) throws -> Clip {
    let clipSpeed = speed
    return Clip(
        id: try id ?? uuid("00000000-0000-0000-0000-000000086301"),
        source: .sequence(id: sequenceID),
        sourceRange: try TimeRange(start: sourceStart, duration: duration),
        timelineRange: try TimeRange(
            start: timelineStart,
            duration: Clip.timelineDuration(forSourceDuration: duration, speed: clipSpeed)
        ),
        kind: .audio,
        name: "Compound Audio",
        audioMix: audioMix,
        speed: clipSpeed
    )
}

private func audioSequence(id: UUID, items: [TimelineItem]) throws -> Sequence {
    try audioSequence(id: id, tracks: [makeTrack(items: items)])
}

private func audioSequence(id: UUID, tracks: [Track]) throws -> Sequence {
    Sequence(
        id: id,
        name: "Audio Sequence",
        videoTracks: [],
        audioTracks: tracks,
        markers: [],
        timebase: try FrameRate(frames: 4)
    )
}

private func audioProject(sequences: [Sequence]) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 4),
            resolution: PixelDimensions(width: 16, height: 16),
            colorSpace: .rec709,
            audioSampleRate: 4
        ),
        mediaPool: [],
        sequences: sequences
    )
}
