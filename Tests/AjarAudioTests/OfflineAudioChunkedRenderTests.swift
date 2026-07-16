// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarAudio

final class OfflineAudioChunkedRenderTests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testBoundedContinuationMatchesMonolithicCrossfadeRetimeAndDuckingSamples() throws {
        let outgoingMediaID = try uuid("00000000-0000-0000-0000-000000277301")
        let incomingMediaID = try uuid("00000000-0000-0000-0000-000000277302")
        let triggerMediaID = try uuid("00000000-0000-0000-0000-000000277303")
        let triggerTrackID = try uuid("00000000-0000-0000-0000-000000277304")
        let targetTrackID = try uuid("00000000-0000-0000-0000-000000277305")
        let pair = try makeCrossfadedPair(
            mediaA: outgoingMediaID,
            mediaB: incomingMediaID,
            shape: CrossfadePairShape(
                crossfadeDuration: time(1, 4),
                curve: .equalPower,
                outgoingSpeed: try RationalValue(numerator: 2, denominator: 1)
            )
        )
        let trigger = try makeClip(
            mediaID: triggerMediaID,
            duration: time(1, 1)
        )
        let sequence = try makeSequence(
            tracks: [
                makeTrack(id: triggerTrackID, items: [.clip(trigger)]),
                makeTrack(id: targetTrackID, items: pair)
            ],
            audioDucking: [
                AudioDuckingRule(
                    triggerTrackID: triggerTrackID,
                    targetTrackIDs: [targetTrackID],
                    threshold: RationalValue.approximating(0.5),
                    reductionGain: RationalValue.approximating(0.25),
                    attack: try time(1, 2),
                    release: try time(1, 2),
                    hold: try time(1, 8)
                )
            ]
        )
        let project = try makeCrossfadeProject(
            sequences: [sequence],
            media: [
                makeCrossfadeMediaRef(id: outgoingMediaID, declaredDuration: time(2, 1)),
                makeCrossfadeMediaRef(id: incomingMediaID, declaredDuration: time(1, 1)),
                makeCrossfadeMediaRef(id: triggerMediaID, declaredDuration: time(1, 1))
            ]
        )
        let provider = InMemoryAudioSourceProvider(sources: [
            outgoingMediaID: try crossfadeMonoSource((0..<16).map { Float($0 + 1) / 16 }),
            incomingMediaID: try crossfadeMonoSource((0..<8).map { Float(8 - $0) / 8 }),
            triggerMediaID: try crossfadeMonoSource([1, 1, 1, 1, 0, 0, 0, 0])
        ])
        let completeRange = try TimeRange(start: .zero, duration: time(1, 1))
        let monolithic = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: completeRange,
            format: crossfadeRenderFormat,
            sourceProvider: provider
        )

        var continuation = OfflineAudioRenderContinuation()
        var chunkedSamples: [Float] = []
        for start in [RationalTime.zero, try time(1, 2)] {
            let chunk = try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: TimeRange(start: start, duration: time(1, 2)),
                format: crossfadeRenderFormat,
                sourceProvider: provider,
                continuation: &continuation,
                cancellationCheck: {}
            )
            chunkedSamples.append(contentsOf: chunk.samples)
        }

        XCTAssertEqual(chunkedSamples, monolithic.samples)
    }

    /// Every compound layer asks its child for two leading and one trailing interpolation guard
    /// frames. At the maximum supported depth, the second one-second chunk therefore starts 48
    /// leaf frames before the first leaf render ended. The trigger has already gone silent before
    /// that restarted window, so only the saved envelope at that exact boundary can preserve the
    /// long release ramp.
    func testNestedDuckingMatchesMonolithicAcrossMaximumCompoundGuardOverlap() throws {
        let fixture = try makeMaximumDepthDuckingFixture()
        let completeRange = try TimeRange(start: .zero, duration: time(2, 1))
        let monolithic = try OfflineAudioMixer.render(
            project: fixture.project,
            sequence: fixture.sequence,
            range: completeRange,
            format: fixture.format,
            sourceProvider: fixture.provider
        )

        var continuation = OfflineAudioRenderContinuation()
        var chunkedSamples: [Float] = []
        for start in [RationalTime.zero, try time(1, 1)] {
            let chunk = try OfflineAudioMixer.render(
                project: fixture.project,
                sequence: fixture.sequence,
                range: TimeRange(start: start, duration: time(1, 1)),
                format: fixture.format,
                sourceProvider: fixture.provider,
                continuation: &continuation,
                cancellationCheck: {}
            )
            chunkedSamples.append(contentsOf: chunk.samples)
        }

        let boundarySample = fixture.format.sampleRate * fixture.format.channelCount
        XCTAssertLessThan(monolithic.samples[boundarySample], 1)
        XCTAssertEqual(chunkedSamples, monolithic.samples)
    }

    func testDuplicateCompoundInstancesKeepIndependentDuckingContinuationAcrossChunks() throws {
        let fixture = try makeDuplicateCompoundDuckingFixture()
        let completeRange = try TimeRange(start: .zero, duration: time(2, 1))
        let monolithic = try OfflineAudioMixer.render(
            project: fixture.project,
            sequence: fixture.sequence,
            range: completeRange,
            format: fixture.format,
            sourceProvider: fixture.provider
        )

        var continuation = OfflineAudioRenderContinuation()
        var chunkedSamples: [Float] = []
        for start in [RationalTime.zero, try time(1, 1)] {
            let chunk = try OfflineAudioMixer.render(
                project: fixture.project,
                sequence: fixture.sequence,
                range: TimeRange(start: start, duration: time(1, 1)),
                format: fixture.format,
                sourceProvider: fixture.provider,
                continuation: &continuation,
                cancellationCheck: {}
            )
            chunkedSamples.append(contentsOf: chunk.samples)
        }

        assertSamples(chunkedSamples, equal: monolithic.samples)
    }

    func testCancellationHookInterruptsFastCPUMixAtBoundedFrameInterval() throws {
        let sampleRate = 192_000
        let mediaID = try uuid("00000000-0000-0000-0000-000000277311")
        let duration = try time(1, 1)
        let clip = try makeClip(mediaID: mediaID, duration: duration)
        let sequence = try makeSequence(items: [.clip(clip)])
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: try FrameRate(frames: 30),
                resolution: PixelDimensions(width: 16, height: 16),
                colorSpace: .rec709,
                audioSampleRate: sampleRate
            ),
            mediaPool: [makeCrossfadeMediaRef(id: mediaID, declaredDuration: duration)],
            sequences: [sequence]
        )
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
            frameCount: sampleRate,
            samples: [Float](repeating: 0.25, count: sampleRate)
        )
        let probe = MixerCancellationProbe(cancelAtPoll: 8)
        var continuation = OfflineAudioRenderContinuation()

        XCTAssertThrowsError(
            try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: TimeRange(start: .zero, duration: duration),
                format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 2),
                sourceProvider: InMemoryAudioSourceProvider(sources: [mediaID: source]),
                continuation: &continuation,
                cancellationCheck: { try probe.poll() }
            )
        ) { error in
            XCTAssertTrue(error is MixerCancellationProbe.Cancelled)
        }
        XCTAssertEqual(probe.pollCount, 8)
    }
}

private struct ChunkedDuckingFixture {
    let project: Project
    let sequence: Sequence
    let provider: InMemoryAudioSourceProvider
    let format: AudioRenderFormat
}

// swiftlint:disable:next function_body_length
private func makeDuplicateCompoundDuckingFixture() throws -> ChunkedDuckingFixture {
    let sampleRate = 8
    let duration = try time(2, 1)
    let secondHalf = try time(1, 1)
    let format = AudioRenderFormat(sampleRate: sampleRate, channelCount: 2)
    let triggerMediaID = try chunkedUUID(277_801)
    let bedMediaID = try chunkedUUID(277_802)
    let triggerTrackID = try chunkedUUID(277_803)
    let bedTrackID = try chunkedUUID(277_804)
    let nestedSequenceID = try chunkedUUID(277_805)
    let rootSequenceID = try chunkedUUID(277_806)

    let nested = Sequence(
        id: nestedSequenceID,
        name: "Ducked nested source",
        videoTracks: [],
        audioTracks: [
            try makeTrack(
                id: triggerTrackID,
                items: [
                    .clip(
                        try makeClip(
                            id: chunkedUUID(277_807),
                            mediaID: triggerMediaID,
                            duration: duration
                        )
                    )
                ]
            ),
            try makeTrack(
                id: bedTrackID,
                items: [
                    .clip(
                        try makeClip(
                            id: chunkedUUID(277_808),
                            mediaID: bedMediaID,
                            duration: duration
                        )
                    )
                ]
            )
        ],
        markers: [],
        audioDucking: [
            AudioDuckingRule(
                triggerTrackID: triggerTrackID,
                targetTrackIDs: [bedTrackID],
                threshold: RationalValue.approximating(0.5),
                reductionGain: RationalValue.approximating(0.25),
                attack: .zero,
                release: duration
            )
        ],
        timebase: try FrameRate(frames: Int64(sampleRate))
    )

    let firstInstance = Clip(
        id: try chunkedUUID(277_809),
        source: .sequence(id: nestedSequenceID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(start: .zero, duration: duration),
        kind: .audio,
        name: "Continuous instance"
    )
    let secondInstance = Clip(
        id: try chunkedUUID(277_810),
        source: .sequence(id: nestedSequenceID),
        sourceRange: try TimeRange(start: secondHalf, duration: secondHalf),
        timelineRange: try TimeRange(start: secondHalf, duration: secondHalf),
        kind: .audio,
        name: "Fresh instance"
    )
    let root = Sequence(
        id: rootSequenceID,
        name: "Repeated compound root",
        videoTracks: [],
        audioTracks: [
            try makeTrack(
                id: chunkedUUID(277_811),
                items: [.clip(firstInstance)]
            ),
            try makeTrack(
                id: chunkedUUID(277_812),
                items: [.clip(secondInstance)]
            )
        ],
        markers: [],
        timebase: try FrameRate(frames: Int64(sampleRate))
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: Int64(sampleRate)),
            resolution: PixelDimensions(width: 16, height: 16),
            colorSpace: .rec709,
            audioSampleRate: sampleRate
        ),
        mediaPool: [
            makeCrossfadeMediaRef(id: triggerMediaID, declaredDuration: duration),
            makeCrossfadeMediaRef(id: bedMediaID, declaredDuration: duration)
        ],
        sequences: [root, nested]
    )
    return ChunkedDuckingFixture(
        project: project,
        sequence: root,
        provider: InMemoryAudioSourceProvider(sources: [
            triggerMediaID: try AudioSourceBuffer(
                format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
                frameCount: sampleRate * 2,
                samples: [Float](repeating: 1, count: sampleRate / 4)
                    + [Float](repeating: 0, count: (sampleRate * 2) - (sampleRate / 4))
            ),
            bedMediaID: try AudioSourceBuffer(
                format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
                frameCount: sampleRate * 2,
                samples: [Float](repeating: 1, count: sampleRate * 2)
            )
        ]),
        format: format
    )
}

// swiftlint:disable:next function_body_length
private func makeMaximumDepthDuckingFixture() throws -> ChunkedDuckingFixture {
    let sampleRate = 64
    let duration = try time(2, 1)
    let format = AudioRenderFormat(sampleRate: sampleRate, channelCount: 2)
    let triggerMediaID = try chunkedUUID(277_401)
    let bedMediaID = try chunkedUUID(277_402)
    let triggerTrackID = try chunkedUUID(277_403)
    let bedTrackID = try chunkedUUID(277_404)
    let triggerSamples = (0..<(sampleRate * 2)).map { frame in
        frame < sampleRate / 4 ? Float(1) : Float(0)
    }
    let bedSamples = [Float](repeating: 1, count: sampleRate * 2)
    let leafID = try chunkedUUID(277_500 + RenderGraphBuilder.maximumCompoundNestingDepth)
    let leaf = Sequence(
        id: leafID,
        name: "Maximum-depth ducking leaf",
        videoTracks: [],
        audioTracks: [
            try makeTrack(
                id: triggerTrackID,
                items: [
                    .clip(try makeClip(mediaID: triggerMediaID, duration: duration))
                ]
            ),
            try makeTrack(
                id: bedTrackID,
                items: [
                    .clip(
                        try makeClip(
                            id: chunkedUUID(277_406),
                            mediaID: bedMediaID,
                            duration: duration
                        )
                    )
                ]
            )
        ],
        markers: [],
        audioDucking: [
            AudioDuckingRule(
                triggerTrackID: triggerTrackID,
                targetTrackIDs: [bedTrackID],
                threshold: RationalValue.approximating(0.5),
                reductionGain: RationalValue.approximating(0.25),
                attack: .zero,
                release: duration
            )
        ],
        timebase: try FrameRate(frames: Int64(sampleRate))
    )

    var sequences = [leaf]
    var childSequenceID = leaf.id
    for depth in stride(
        from: RenderGraphBuilder.maximumCompoundNestingDepth - 1,
        through: 0,
        by: -1
    ) {
        let sequenceID = try chunkedUUID(277_500 + depth)
        let compound = Clip(
            id: try chunkedUUID(277_600 + depth),
            source: .sequence(id: childSequenceID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .audio,
            name: "Guard layer \(depth)"
        )
        let parent = Sequence(
            id: sequenceID,
            name: "Guard layer \(depth)",
            videoTracks: [],
            audioTracks: [
                try makeTrack(
                    id: chunkedUUID(277_700 + depth),
                    items: [.clip(compound)]
                )
            ],
            markers: [],
            timebase: try FrameRate(frames: Int64(sampleRate))
        )
        sequences.append(parent)
        childSequenceID = sequenceID
    }
    let root = try XCTUnwrap(sequences.last)
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: Int64(sampleRate)),
            resolution: PixelDimensions(width: 16, height: 16),
            colorSpace: .rec709,
            audioSampleRate: sampleRate
        ),
        mediaPool: [
            makeCrossfadeMediaRef(id: triggerMediaID, declaredDuration: duration),
            makeCrossfadeMediaRef(id: bedMediaID, declaredDuration: duration)
        ],
        sequences: sequences
    )
    return ChunkedDuckingFixture(
        project: project,
        sequence: root,
        provider: InMemoryAudioSourceProvider(sources: [
            triggerMediaID: try AudioSourceBuffer(
                format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
                frameCount: triggerSamples.count,
                samples: triggerSamples
            ),
            bedMediaID: try AudioSourceBuffer(
                format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
                frameCount: bedSamples.count,
                samples: bedSamples
            )
        ]),
        format: format
    )
}

private func chunkedUUID(_ value: Int) throws -> UUID {
    try uuid(String(format: "00000000-0000-0000-0000-%012d", value))
}

private final class MixerCancellationProbe: @unchecked Sendable {
    struct Cancelled: Error {}

    private let lock = NSLock()
    private let cancelAtPoll: Int
    private var count = 0

    init(cancelAtPoll: Int) {
        self.cancelAtPoll = cancelAtPoll
    }

    var pollCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func poll() throws {
        lock.lock()
        count += 1
        let shouldCancel = count >= cancelAtPoll
        lock.unlock()
        if shouldCancel {
            throw Cancelled()
        }
    }
}
