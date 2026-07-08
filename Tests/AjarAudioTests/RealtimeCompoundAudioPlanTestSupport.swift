// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

@testable import AjarAudio

// MARK: - Fixtures

struct CompoundPlanFixture {
    let project: Project
    let sequence: Sequence
    let sources: [UUID: AudioSourceBuffer]
    let range: TimeRange
}

func makeAudioTrackCompoundFixture() throws -> CompoundPlanFixture {
    let mediaID = try uuid("00000000-0000-0000-0000-000000157001")
    let nestedSequenceID = try uuid("00000000-0000-0000-0000-000000157002")
    let nested = try compoundFixtureSequence(
        id: nestedSequenceID,
        audioTracks: [try makeTrack(items: [
            .clip(try makeClip(mediaID: mediaID, duration: time(1, 1)))
        ])]
    )
    let parent = try compoundFixtureSequence(
        id: try uuid("00000000-0000-0000-0000-000000157003"),
        audioTracks: [try makeTrack(items: [
            .clip(try compoundFixtureClip(
                id: try uuid("00000000-0000-0000-0000-000000157004"),
                sequenceID: nestedSequenceID,
                kind: .audio
            ))
        ])]
    )
    return try CompoundPlanFixture(
        project: compoundFixtureProject(sequences: [parent, nested]),
        sequence: parent,
        sources: [mediaID: try audioSource(samples: [1, 2, 3, 4])],
        range: TimeRange(start: .zero, duration: time(1, 1))
    )
}

func makeVideoTrackCompoundFixture() throws -> CompoundPlanFixture {
    let nestedMediaID = try uuid("00000000-0000-0000-0000-000000157011")
    let bedMediaID = try uuid("00000000-0000-0000-0000-000000157012")
    let nestedSequenceID = try uuid("00000000-0000-0000-0000-000000157013")
    let nested = try compoundFixtureSequence(
        id: nestedSequenceID,
        audioTracks: [try makeTrack(items: [
            .clip(try makeClip(mediaID: nestedMediaID, duration: time(1, 1)))
        ])]
    )
    let parent = try compoundFixtureSequence(
        id: try uuid("00000000-0000-0000-0000-000000157014"),
        videoTracks: [videoTrack(
            id: try uuid("00000000-0000-0000-0000-000000157015"),
            items: [.clip(try compoundFixtureClip(
                id: try uuid("00000000-0000-0000-0000-000000157016"),
                sequenceID: nestedSequenceID,
                kind: .video
            ))]
        )],
        audioTracks: [try makeTrack(items: [
            .clip(try makeClip(mediaID: bedMediaID, duration: time(1, 1)))
        ])]
    )
    return try CompoundPlanFixture(
        project: compoundFixtureProject(sequences: [parent, nested]),
        sequence: parent,
        sources: [
            nestedMediaID: try audioSource(samples: [2, 2, 2, 2]),
            bedMediaID: try audioSource(samples: [1, 1, 1, 1])
        ],
        range: TimeRange(start: .zero, duration: time(1, 1))
    )
}

func makeSoloedVisualOnlyCompoundFixture() throws -> CompoundPlanFixture {
    let bedMediaID = try uuid("00000000-0000-0000-0000-000000157021")
    let visualMediaID = try uuid("00000000-0000-0000-0000-000000157022")
    let nestedSequenceID = try uuid("00000000-0000-0000-0000-000000157023")
    let nested = try compoundFixtureSequence(
        id: nestedSequenceID,
        videoTracks: [videoTrack(
            id: try uuid("00000000-0000-0000-0000-000000157024"),
            items: [.clip(try videoClip(
                id: try uuid("00000000-0000-0000-0000-000000157025"),
                mediaID: visualMediaID
            ))]
        )]
    )
    let parent = try compoundFixtureSequence(
        id: try uuid("00000000-0000-0000-0000-000000157026"),
        videoTracks: [videoTrack(
            id: try uuid("00000000-0000-0000-0000-000000157027"),
            items: [.clip(try compoundFixtureClip(
                id: try uuid("00000000-0000-0000-0000-000000157028"),
                sequenceID: nestedSequenceID,
                kind: .video
            ))],
            solo: true
        )],
        audioTracks: [try makeTrack(items: [
            .clip(try makeClip(mediaID: bedMediaID, duration: time(1, 1)))
        ])]
    )
    return try CompoundPlanFixture(
        project: compoundFixtureProject(sequences: [parent, nested]),
        sequence: parent,
        sources: [bedMediaID: try audioSource(samples: [1, 1, 1, 1])],
        range: TimeRange(start: .zero, duration: time(1, 1))
    )
}

func makeNestedCompoundDepthTwoFixture() throws -> CompoundPlanFixture {
    let mediaID = try uuid("00000000-0000-0000-0000-000000157031")
    let innerSequenceID = try uuid("00000000-0000-0000-0000-000000157032")
    let midSequenceID = try uuid("00000000-0000-0000-0000-000000157033")
    let inner = try compoundFixtureSequence(
        id: innerSequenceID,
        audioTracks: [try makeTrack(items: [
            .clip(try makeClip(mediaID: mediaID, duration: time(1, 1)))
        ])]
    )
    let mid = try compoundFixtureSequence(
        id: midSequenceID,
        audioTracks: [try makeTrack(items: [
            .clip(try compoundFixtureClip(
                id: try uuid("00000000-0000-0000-0000-000000157034"),
                sequenceID: innerSequenceID,
                kind: .audio
            ))
        ])]
    )
    let parent = try compoundFixtureSequence(
        id: try uuid("00000000-0000-0000-0000-000000157035"),
        videoTracks: [videoTrack(
            id: try uuid("00000000-0000-0000-0000-000000157036"),
            items: [.clip(try compoundFixtureClip(
                id: try uuid("00000000-0000-0000-0000-000000157037"),
                sequenceID: midSequenceID,
                kind: .video
            ))]
        )]
    )
    return try CompoundPlanFixture(
        project: compoundFixtureProject(sequences: [parent, mid, inner]),
        sequence: parent,
        sources: [mediaID: try audioSource(samples: [1, 2, 3, 4])],
        range: TimeRange(start: .zero, duration: time(1, 1))
    )
}

/// A blade-style crossfaded pair per ADR-0015 (FR-AUD-002): one staircase source split at
/// 1/2 and rejoined by a linear crossfade, so the correct mix reproduces the uncut source.
func makeCrossfadedPairFixture() throws -> CompoundPlanFixture {
    let mediaID = try uuid("00000000-0000-0000-0000-000000157041")
    let outgoingID = try uuid("00000000-0000-0000-0000-000000157042")
    let incomingID = try uuid("00000000-0000-0000-0000-000000157043")
    let crossfadeDuration = try time(1, 2)
    let outgoing = try makeClip(
        id: outgoingID,
        mediaID: mediaID,
        duration: time(1, 2),
        audioMix: ClipAudioMix(
            trailingCrossfade: ClipAudioCrossfade(
                partnerClipID: incomingID,
                duration: crossfadeDuration,
                curve: .linear
            )
        )
    )
    let incoming = try makeClip(
        id: incomingID,
        mediaID: mediaID,
        sourceStart: time(1, 2),
        timelineStart: time(1, 2),
        duration: time(1, 2),
        audioMix: ClipAudioMix(
            leadingCrossfade: ClipAudioCrossfade(
                partnerClipID: outgoingID,
                duration: crossfadeDuration,
                curve: .linear
            )
        )
    )
    let parent = try compoundFixtureSequence(
        id: try uuid("00000000-0000-0000-0000-000000157044"),
        audioTracks: [try makeTrack(items: [.clip(outgoing), .clip(incoming)])]
    )
    return try CompoundPlanFixture(
        project: compoundFixtureProject(sequences: [parent]),
        sequence: parent,
        sources: [mediaID: try audioSource(samples: [1, 2, 3, 4])],
        range: TimeRange(start: .zero, duration: time(1, 1))
    )
}

func makeStressCompoundFixture(sentinel: Float) throws -> CompoundPlanFixture {
    let sampleRate = 4_000
    let seed = 157_100 + Int(sentinel) * 10
    let mediaID = try stressUUID(seed + 1)
    let nestedSequenceID = try stressUUID(seed + 2)
    let nested = try compoundFixtureSequence(
        id: nestedSequenceID,
        audioTracks: [try makeTrack(items: [
            .clip(try makeClip(mediaID: mediaID, duration: time(1, 1)))
        ])]
    )
    let parent = try compoundFixtureSequence(
        id: try stressUUID(seed + 3),
        audioTracks: [try makeTrack(items: [
            .clip(try compoundFixtureClip(
                id: try stressUUID(seed + 4),
                sequenceID: nestedSequenceID,
                kind: .audio
            ))
        ])]
    )
    let source = try AudioSourceBuffer(
        format: AudioRenderFormat(sampleRate: sampleRate, channelCount: 1),
        frameCount: sampleRate,
        samples: [Float](repeating: sentinel, count: sampleRate)
    )
    return try CompoundPlanFixture(
        project: compoundFixtureProject(sequences: [parent, nested], sampleRate: sampleRate),
        sequence: parent,
        sources: [mediaID: source],
        range: TimeRange(start: .zero, duration: time(1, 1))
    )
}

func stressUUID(_ value: Int) throws -> UUID {
    try uuid(String(format: "00000000-0000-0000-0000-%012d", value))
}

func compoundFixtureClip(id: UUID, sequenceID: UUID, kind: TrackKind) throws -> Clip {
    Clip(
        id: id,
        source: .sequence(id: sequenceID),
        sourceRange: try TimeRange(start: .zero, duration: time(1, 1)),
        timelineRange: try TimeRange(start: .zero, duration: time(1, 1)),
        kind: kind,
        name: "Compound"
    )
}

func videoClip(id: UUID, mediaID: UUID) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: time(1, 1)),
        timelineRange: try TimeRange(start: .zero, duration: time(1, 1)),
        kind: .video,
        name: "Visual"
    )
}

func videoTrack(id: UUID, items: [TimelineItem], solo: Bool = false) -> Track {
    Track(id: id, kind: .video, items: items, solo: solo)
}

func compoundFixtureSequence(
    id: UUID,
    videoTracks: [Track] = [],
    audioTracks: [Track] = []
) throws -> Sequence {
    Sequence(
        id: id,
        name: "RT Compound Fixture",
        videoTracks: videoTracks,
        audioTracks: audioTracks,
        markers: [],
        timebase: try FrameRate(frames: 4)
    )
}

func compoundFixtureProject(sequences: [Sequence], sampleRate: Int = 4) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 4),
            resolution: PixelDimensions(width: 16, height: 16),
            colorSpace: .rec709,
            audioSampleRate: sampleRate
        ),
        mediaPool: [],
        sequences: sequences
    )
}

// MARK: - Render helpers

func offlineMix(_ fixture: CompoundPlanFixture) throws -> RenderedAudioBuffer {
    try OfflineAudioMixer.render(
        project: fixture.project,
        sequence: fixture.sequence,
        range: fixture.range,
        sourceProvider: InMemoryAudioSourceProvider(sources: fixture.sources)
    )
}

func makeRealtimePlan(for fixture: CompoundPlanFixture) throws -> RealtimeAudioRenderPlan {
    try RealtimeAudioRenderPlan.preparingCompoundMix(
        project: fixture.project,
        sequence: fixture.sequence,
        range: fixture.range,
        sourceProvider: InMemoryAudioSourceProvider(sources: fixture.sources)
    )
}

/// Drains a realtime plan through the caller-owned-output callback path in fixed-size chunks,
/// the way a render callback consumes it.
func realtimeSamples(
    for fixture: CompoundPlanFixture,
    chunkFrames: Int
) throws -> [Float] {
    var plan = try makeRealtimePlan(for: fixture)
    let channelCount = plan.format.channelCount
    var rendered: [Float] = []
    var chunk = [Float](repeating: 0, count: chunkFrames * channelCount)
    while true {
        let copied = chunk.withUnsafeMutableBufferPointer { pointer in
            plan.render(into: pointer)
        }
        guard copied > 0 else {
            return rendered
        }
        rendered.append(contentsOf: chunk.prefix(copied * channelCount))
    }
}

// MARK: - Stress harness

func startCompoundPlanPublisher(
    handoff: RealtimeAudioRenderPlanHandoff,
    plans: [RealtimeAudioRenderPlan],
    group: DispatchGroup,
    start: DispatchSemaphore,
    state: CompoundPlanStressState
) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            state.markPublisherDone()
            group.leave()
        }
        start.wait()
        for iteration in 0..<4_000 {
            do {
                try handoff.publish(plans[iteration % plans.count])
            } catch {
                state.appendFailure("publish failed: \(error)")
                return
            }
        }
    }
}

func startCompoundPlanObserver(
    handoff: RealtimeAudioRenderPlanHandoff,
    validSentinels: Set<Float>,
    group: DispatchGroup,
    start: DispatchSemaphore,
    state: CompoundPlanStressState
) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer { group.leave() }
        start.wait()
        while !state.isPublisherDone {
            guard let output = renderOneFrame(from: handoff) else {
                continue
            }
            state.incrementObservedCount()

            if output[0] != output[1] || !validSentinels.contains(output[0]) {
                state.appendFailure("torn or unknown frame: \(output)")
                return
            }
        }
    }
}

func renderOneFrame(from handoff: RealtimeAudioRenderPlanHandoff) -> [Float]? {
    var output = [Float](repeating: -1, count: 2)
    let copied = handoff.withCurrentPlan { plan in
        output.withUnsafeMutableBufferPointer { pointer in
            plan.render(into: pointer)
        }
    }
    guard copied != nil else {
        return nil
    }
    return output
}

final class CompoundPlanStressState: @unchecked Sendable {
    private let lock = NSLock()
    private var publisherDone = false
    private var observedCount = 0
    private var failures: [String] = []

    var isPublisherDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return publisherDone
    }

    func markPublisherDone() {
        lock.lock()
        publisherDone = true
        lock.unlock()
    }

    func incrementObservedCount() {
        lock.lock()
        observedCount += 1
        lock.unlock()
    }

    func appendFailure(_ message: String) {
        lock.lock()
        failures.append(message)
        lock.unlock()
    }

    func snapshot() -> (failures: [String], observedCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (failures, observedCount)
    }
}
