// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// FR-CMP-001 make-compound audio playback through the full chain: the make-compound edit
/// command collapses selected clips into a `.video` compound clip on a video track, and the
/// offline mixer must resolve that clip's nested sequence audio so collapsing never silences it.
final class MakeCompoundAudioPlaybackTests: XCTestCase {
    func testFRCMP001MakeCompoundClipAudioPlaysInOfflineMix() throws {
        let fixture = try makePlaybackFixture(seed: 87_100)
        let before = try renderMix(project: fixture.project, sequenceID: fixture.sequenceID)
        assertSamples(before.samples, equal: [1, 1, 2, 2, 3, 3, 4, 4])

        let edited = try apply(fixture.collapseAllCommand, to: fixture.project)

        let compoundClip = try XCTUnwrap(compoundClip(in: edited, fixture: fixture))
        XCTAssertEqual(compoundClip.kind, .video)
        XCTAssertEqual(compoundClip.source, .sequence(id: fixture.compoundSequenceID))
        let after = try renderMix(project: edited, sequenceID: fixture.sequenceID)
        assertSamples(after.samples, equal: before.samples)
    }

    func testFRCMP001MakeCompoundClipDuckingStillAppliesInsideCompound() throws {
        let fixture = try makePlaybackFixture(seed: 87_200, withDucking: true)
        let before = try renderMix(project: fixture.project, sequenceID: fixture.sequenceID)
        // Trigger [0,1,1,0] over threshold 1/2 ducks the [2,2,2,2] bed to gain 1/4 on the
        // middle frames; the trigger itself still sums into the mix (2, 1+0.5, 1+0.5, 2).
        assertSamples(before.samples, equal: [2, 2, 1.5, 1.5, 1.5, 1.5, 2, 2])

        let edited = try apply(fixture.collapseAllCommand, to: fixture.project)

        let after = try renderMix(project: edited, sequenceID: fixture.sequenceID)
        assertSamples(after.samples, equal: before.samples)
    }

    func testFRCMP001MutedVideoTrackSilencesCompoundAudio() throws {
        let fixture = try makeManualCompoundFixture(seed: 87_300, videoTrackMuted: true)

        let buffer = try renderMix(project: fixture.project, sequenceID: fixture.sequenceID)

        assertSamples(buffer.samples, equal: [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testFRCMP001SoloedAudioTrackSilencesVideoTrackCompoundAudio() throws {
        let fixture = try makeManualCompoundFixture(
            seed: 87_400,
            includeBed: true,
            bedSolo: true
        )

        let buffer = try renderMix(project: fixture.project, sequenceID: fixture.sequenceID)

        assertSamples(buffer.samples, equal: [1, 1, 1, 1, 1, 1, 1, 1])
    }

    private func renderMix(project: Project, sequenceID: UUID) throws -> RenderedAudioBuffer {
        let sequence = try XCTUnwrap(project.sequences.first { $0.id == sequenceID })
        return try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: TimeRange(start: .zero, duration: try time(1, 1)),
            sourceProvider: InMemoryAudioSourceProvider(sources: playbackSources)
        )
    }

    private func compoundClip(
        in project: Project,
        fixture: PlaybackFixture
    ) throws -> Clip? {
        let sequence = try XCTUnwrap(
            project.sequences.first { $0.id == fixture.sequenceID }
        )
        for track in sequence.videoTracks {
            for item in track.items {
                if case .clip(let clip) = item, clip.id == fixture.compoundClipID {
                    return clip
                }
            }
        }
        return nil
    }
}

private struct PlaybackFixture {
    let project: Project
    let sequenceID: UUID
    let compoundSequenceID: UUID
    let compoundClipID: UUID
    let selectedClips: [ClipReference]

    var collapseAllCommand: EditCommand {
        .makeCompoundClip(
            sequenceID: sequenceID,
            compoundSequenceID: compoundSequenceID,
            compoundClipID: compoundClipID,
            selectedClips: selectedClips,
            name: "FR-CMP-001 Playback Compound"
        )
    }
}

private let stairMediaID = playbackUUID(87_001)
private let triggerMediaID = playbackUUID(87_002)
private let bedMediaID = playbackUUID(87_003)
private let videoMediaID = playbackUUID(87_004)
private let onesMediaID = playbackUUID(87_005)

private var playbackSources: [UUID: AudioSourceBuffer] {
    let sources: [UUID: [Float]] = [
        stairMediaID: [1, 2, 3, 4],
        triggerMediaID: [0, 1, 1, 0],
        bedMediaID: [2, 2, 2, 2],
        onesMediaID: [1, 1, 1, 1]
    ]
    return sources.compactMapValues { samples in
        try? AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
            frameCount: samples.count,
            samples: samples
        )
    }
}

private func playbackUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)) ?? UUID()
}

private struct PlaybackAudioLayout {
    let audioTracks: [Track]
    let selections: [ClipReference]
    let ducking: [AudioDuckingRule]
}

private func makePlaybackFixture(
    seed: Int,
    withDucking: Bool = false
) throws -> PlaybackFixture {
    let sequenceID = playbackUUID(seed + 1)
    let videoTrackID = playbackUUID(seed + 2)
    let videoClipID = playbackUUID(seed + 5)
    let videoTrack = Track(
        id: videoTrackID,
        kind: .video,
        items: [
            .clip(try playbackClip(id: videoClipID, mediaID: videoMediaID, kind: .video))
        ]
    )
    let layout = try makePlaybackAudioLayout(seed: seed, withDucking: withDucking)

    let sequence = Sequence(
        id: sequenceID,
        name: "FR-CMP-001 Playback Source",
        videoTracks: [videoTrack],
        audioTracks: layout.audioTracks,
        markers: [],
        audioDucking: layout.ducking,
        timebase: try FrameRate(frames: 4)
    )
    return PlaybackFixture(
        project: try playbackProject(sequences: [sequence]),
        sequenceID: sequenceID,
        compoundSequenceID: playbackUUID(seed + 8),
        compoundClipID: playbackUUID(seed + 9),
        selectedClips: [ClipReference(trackID: videoTrackID, clipID: videoClipID)]
            + layout.selections
    )
}

private func makePlaybackAudioLayout(
    seed: Int,
    withDucking: Bool
) throws -> PlaybackAudioLayout {
    let triggerTrackID = playbackUUID(seed + 3)
    let bedTrackID = playbackUUID(seed + 4)
    let triggerClipID = playbackUUID(seed + 6)
    let bedClipID = playbackUUID(seed + 7)
    let triggerSelection = ClipReference(trackID: triggerTrackID, clipID: triggerClipID)

    guard withDucking else {
        return PlaybackAudioLayout(
            audioTracks: [
                try playbackAudioTrack(
                    id: triggerTrackID,
                    clipID: triggerClipID,
                    mediaID: stairMediaID
                )
            ],
            selections: [triggerSelection],
            ducking: []
        )
    }

    return PlaybackAudioLayout(
        audioTracks: [
            try playbackAudioTrack(
                id: triggerTrackID,
                clipID: triggerClipID,
                mediaID: triggerMediaID
            ),
            try playbackAudioTrack(id: bedTrackID, clipID: bedClipID, mediaID: bedMediaID)
        ],
        selections: [
            triggerSelection,
            ClipReference(trackID: bedTrackID, clipID: bedClipID)
        ],
        ducking: [
            AudioDuckingRule(
                triggerTrackID: triggerTrackID,
                targetTrackIDs: [bedTrackID],
                threshold: try RationalValue(numerator: 1, denominator: 2),
                reductionGain: try RationalValue(numerator: 1, denominator: 4),
                attack: .zero,
                release: .zero
            )
        ]
    )
}

private func makeManualCompoundFixture(
    seed: Int,
    videoTrackMuted: Bool = false,
    includeBed: Bool = false,
    bedSolo: Bool = false
) throws -> PlaybackFixture {
    let sequenceID = playbackUUID(seed + 1)
    let nestedSequenceID = playbackUUID(seed + 2)
    let nestedTrackID = playbackUUID(seed + 3)
    let nestedClipID = playbackUUID(seed + 4)
    let videoTrackID = playbackUUID(seed + 5)
    let compoundClipID = playbackUUID(seed + 6)

    let nestedSequence = Sequence(
        id: nestedSequenceID,
        name: "Nested",
        videoTracks: [],
        audioTracks: [
            try playbackAudioTrack(id: nestedTrackID, clipID: nestedClipID, mediaID: bedMediaID)
        ],
        markers: [],
        timebase: try FrameRate(frames: 4)
    )
    let compoundClip = Clip(
        id: compoundClipID,
        source: .sequence(id: nestedSequenceID),
        sourceRange: try TimeRange(start: .zero, duration: try time(1, 1)),
        timelineRange: try TimeRange(start: .zero, duration: try time(1, 1)),
        kind: .video,
        name: "Manual Compound"
    )
    var audioTracks: [Track] = []
    if includeBed {
        audioTracks = [
            try playbackAudioTrack(
                id: playbackUUID(seed + 7),
                clipID: playbackUUID(seed + 8),
                mediaID: onesMediaID,
                solo: bedSolo
            )
        ]
    }
    let parent = Sequence(
        id: sequenceID,
        name: "Manual Compound Parent",
        videoTracks: [
            Track(
                id: videoTrackID,
                kind: .video,
                items: [.clip(compoundClip)],
                muted: videoTrackMuted
            )
        ],
        audioTracks: audioTracks,
        markers: [],
        timebase: try FrameRate(frames: 4)
    )
    return PlaybackFixture(
        project: try playbackProject(sequences: [parent, nestedSequence]),
        sequenceID: sequenceID,
        compoundSequenceID: nestedSequenceID,
        compoundClipID: compoundClipID,
        selectedClips: []
    )
}

private func playbackClip(id: UUID, mediaID: UUID, kind: TrackKind) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: try time(1, 1)),
        timelineRange: try TimeRange(start: .zero, duration: try time(1, 1)),
        kind: kind,
        name: "Playback \(kind)"
    )
}

private func playbackAudioTrack(
    id: UUID,
    clipID: UUID,
    mediaID: UUID,
    solo: Bool = false
) throws -> Track {
    Track(
        id: id,
        kind: .audio,
        items: [.clip(try playbackClip(id: clipID, mediaID: mediaID, kind: .audio))],
        solo: solo
    )
}

private func playbackProject(sequences: [Sequence]) throws -> Project {
    Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: try FrameRate(frames: 4),
            resolution: PixelDimensions(width: 16, height: 16),
            colorSpace: .rec709,
            audioSampleRate: 4
        ),
        mediaPool: try playbackMediaPool(),
        sequences: sequences
    )
}

private func playbackMediaPool() throws -> [MediaRef] {
    [
        try playbackMediaRef(id: stairMediaID, hasVideo: false),
        try playbackMediaRef(id: triggerMediaID, hasVideo: false),
        try playbackMediaRef(id: bedMediaID, hasVideo: false),
        try playbackMediaRef(id: videoMediaID, hasVideo: true)
    ]
}

private func playbackMediaRef(id: UUID, hasVideo: Bool) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: hasVideo ? "h264" : "pcm_f32le",
            pixelDimensions: hasVideo ? PixelDimensions(width: 16, height: 16) : nil,
            frameRate: hasVideo ? try FrameRate(frames: 4) : nil,
            duration: try time(1, 1),
            colorSpace: hasVideo ? .rec709 : .unspecified,
            audioChannelLayout: AudioChannelLayout(channelCount: 1),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}
