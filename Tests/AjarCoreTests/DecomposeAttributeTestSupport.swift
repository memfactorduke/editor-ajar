// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

struct AttributeDecomposeFixture {
    let project: Project
    let parentSequenceID: UUID
    let trackID: UUID
    let compoundClipID: UUID
}

enum DecomposeAttributeScenario: CaseIterable {
    case transform
    case transformAnimation
    case effects
    case effectsAnimation
    case audioMix
    case reverse
    case freezeFrame

    var expectedAttribute: CompoundClipDecomposeAttribute {
        switch self {
        case .transform, .transformAnimation:
            return .transform
        case .effects, .effectsAnimation:
            return .effects
        case .audioMix:
            return .audioMix
        case .reverse:
            return .reverse
        case .freezeFrame:
            return .freezeFrame
        }
    }
}

func makeAttributeDecomposeFixture(
    seed: Int,
    scenario: DecomposeAttributeScenario?
) throws -> AttributeDecomposeFixture {
    let base = seed * 1_000
    let mediaID = try editUUID(base + 1)
    let parentSequenceID = try editUUID(base + 2)
    let targetSequenceID = try editUUID(base + 3)
    let trackID = try editUUID(base + 4)
    let compoundClipID = try editUUID(base + 5)
    let innerClip = try makeEditClip(
        id: try editUUID(base + 6),
        mediaID: mediaID,
        startFrame: 0,
        durationFrames: 10
    )
    let targetSequence = Sequence(
        id: targetSequenceID,
        name: "FR-CMP-004 attribute target",
        videoTracks: [Track(id: trackID, kind: .video, items: [.clip(innerClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let parentSequence = try makeAttributeParentSequence(
        id: parentSequenceID,
        trackID: trackID,
        compoundClip: try makeAttributeCompoundClip(
            id: compoundClipID,
            targetSequenceID: targetSequenceID,
            scenario: scenario
        )
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: try compoundSettings(),
        mediaPool: [try makeEditMediaRef(id: mediaID)],
        sequences: [parentSequence, targetSequence]
    )

    return AttributeDecomposeFixture(
        project: project,
        parentSequenceID: parentSequenceID,
        trackID: trackID,
        compoundClipID: compoundClipID
    )
}

private func makeAttributeParentSequence(
    id: UUID,
    trackID: UUID,
    compoundClip: Clip
) throws -> Sequence {
    Sequence(
        id: id,
        name: "FR-CMP-004 attribute parent",
        videoTracks: [Track(id: trackID, kind: .video, items: [.clip(compoundClip)])],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
}

private func makeAttributeCompoundClip(
    id: UUID,
    targetSequenceID: UUID,
    scenario: DecomposeAttributeScenario?
) throws -> Clip {
    let half = try RationalValue(numerator: 1, denominator: 2)
    let activeLumaKey = ClipLumaKeySettings(enabled: true)
    var transform = ClipTransform.identity
    var transformAnimation: AnimatableClipTransform?
    var effects = ClipEffects.none
    var effectsAnimation: AnimatableClipEffects?
    var audioMix = ClipAudioMix.identity
    var reverse = false
    var freezeFrame = false
    switch scenario {
    case .transform:
        transform = ClipTransform(opacity: half)
    case .transformAnimation:
        transformAnimation = AnimatableClipTransform(opacity: .constant(half))
    case .effects:
        effects = ClipEffects(lumaKey: activeLumaKey)
    case .effectsAnimation:
        effectsAnimation = AnimatableClipEffects(lumaKey: .constant(activeLumaKey))
    case .audioMix:
        audioMix = ClipAudioMix(gain: .constant(half))
    case .reverse:
        reverse = true
    case .freezeFrame:
        freezeFrame = true
    case .none:
        break
    }
    return Clip(
        id: id,
        source: .sequence(id: targetSequenceID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "FR-CMP-004 attribute compound",
        transform: transform,
        transformAnimation: transformAnimation,
        effects: effects,
        effectsAnimation: effectsAnimation,
        audioMix: audioMix,
        reverse: reverse,
        freezeFrame: freezeFrame
    )
}

/// A compound whose timeline footprint disagrees with its `sourceRange` at its speed.
func makeMismatchedDurationDecomposeFixture(seed: Int) throws -> AttributeDecomposeFixture {
    let fixture = try makeAttributeDecomposeFixture(seed: seed, scenario: nil)
    let mismatched = Project(
        schemaVersion: fixture.project.schemaVersion,
        settings: fixture.project.settings,
        mediaPool: fixture.project.mediaPool,
        sequences: try fixture.project.sequences.map { sequence in
            guard sequence.id == fixture.parentSequenceID else {
                return sequence
            }
            return try replacingCompoundTimelineDuration(
                in: sequence,
                trackID: fixture.trackID,
                clipID: fixture.compoundClipID,
                durationFrames: 8
            )
        }
    )

    return AttributeDecomposeFixture(
        project: mismatched,
        parentSequenceID: fixture.parentSequenceID,
        trackID: fixture.trackID,
        compoundClipID: fixture.compoundClipID
    )
}

private func replacingCompoundTimelineDuration(
    in sequence: Sequence,
    trackID: UUID,
    clipID: UUID,
    durationFrames: Int64
) throws -> Sequence {
    let videoTracks = try sequence.videoTracks.map { track -> Track in
        guard track.id == trackID else {
            return track
        }
        let items = try track.items.map { item -> TimelineItem in
            guard case .clip(let clip) = item, clip.id == clipID else {
                return item
            }
            return .clip(
                Clip(
                    id: clip.id,
                    source: clip.source,
                    sourceRange: clip.sourceRange,
                    timelineRange: try TimeRange(
                        start: clip.timelineRange.start,
                        duration: editTime(durationFrames)
                    ),
                    kind: clip.kind,
                    name: clip.name
                )
            )
        }
        return Track(id: track.id, kind: track.kind, items: items)
    }
    return Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: videoTracks,
        audioTracks: sequence.audioTracks,
        markers: sequence.markers,
        timebase: sequence.timebase
    )
}
