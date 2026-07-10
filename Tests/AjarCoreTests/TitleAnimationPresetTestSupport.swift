// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

func applyTitlePreset(
    _ kind: TitleAnimationPresetKind,
    duration: RationalTime,
    fixture: TitleProjectFixture,
    direction: TitleAnimationDirection = .left
) throws -> Clip {
    let applied = try EditReducer.apply(
        .applyTitleAnimationPreset(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            preset: TitleAnimationPreset(
                kind: kind,
                duration: duration,
                direction: direction
            )
        ),
        to: fixture.project
    )
    return try titleClip(
        fixture.clipID,
        trackID: fixture.videoTrackID,
        in: applied,
        sequenceID: fixture.sequenceID
    )
}

func firstTitleRenderNode(in graph: RenderGraph) throws -> RenderNode {
    try XCTUnwrap(
        graph.nodes.first { node in
            if case .title = node.kind { return true }
            return false
        }
    )
}

func makeNestedTitleCompoundForPreset(seed: Int) throws -> Project {
    let outer = try makeEditFixture(seed: seed)
    let title = try makeSampleTitle(seed: seed)
    let innerSequenceID = try editUUID(seed * 1_000 + 300)
    let innerTrackID = try editUUID(seed * 1_000 + 301)
    let titleClipID = try editUUID(seed * 1_000 + 302)
    let compoundClipID = try editUUID(seed * 1_000 + 303)
    let nestedTitleClip = Clip(
        id: titleClipID,
        source: .title(title),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Nested title"
    )
    let innerSequence = Sequence(
        id: innerSequenceID,
        name: "Inner title sequence",
        videoTracks: [
            Track(id: innerTrackID, kind: .video, items: [.clip(nestedTitleClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let compoundClip = Clip(
        id: compoundClipID,
        source: .sequence(id: innerSequenceID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Compound with title"
    )
    let outerSequence = try XCTUnwrap(
        outer.project.sequences.first { $0.id == outer.sequenceID }
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: outer.project.settings,
        mediaPool: outer.project.mediaPool,
        sequences: [
            Sequence(
                id: outerSequence.id,
                name: outerSequence.name,
                videoTracks: [
                    Track(
                        id: outer.videoTrackID,
                        kind: .video,
                        items: [.clip(compoundClip)]
                    )
                ],
                audioTracks: outerSequence.audioTracks,
                markers: [],
                timebase: outerSequence.timebase
            ),
            innerSequence
        ]
    )
}

func jsonSettingSchemaMinor(_ minor: Int, in data: Data) throws -> Data {
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["schemaMinor"] = minor
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func titleSource(from clip: Clip) throws -> TitleSource {
    guard case .title(let title) = clip.source else {
        XCTFail("expected title source")
        throw TitleSourceValidationError.emptyFontFamily
    }
    return title
}

/// Title clip with user position/rotation keyframes and a typewriter reveal program.
func projectWithUserAuthoredTitleAnimation(
    fixture: TitleProjectFixture
) throws -> Project {
    let baseClip = try titleClip(
        fixture.clipID,
        trackID: fixture.videoTrackID,
        in: fixture.project,
        sequenceID: fixture.sequenceID
    )
    let authoredTitle = try titleSource(from: baseClip)
        .withRevealFraction(try userAuthoredRevealFraction())
    let authoredTransform = AnimatableClipTransform.constant(baseClip.transform)
        .replacing(
            position: try userAuthoredPositionAnimation(),
            rotation: try userAuthoredRotationAnimation()
        )
    let authoredClip = EditReducer.copying(
        baseClip,
        source: .title(authoredTitle),
        transform: authoredTransform.baseTransform,
        transformAnimation: authoredTransform
    )
    return try replacingTitleClip(authoredClip, in: fixture)
}

private func userAuthoredPositionAnimation() throws -> Animatable<CanvasPoint> {
    try Animatable(
        base: .zero,
        keyframes: [
            Keyframe(
                time: try editTime(0),
                value: CanvasPoint(x: RationalValue(10), y: RationalValue(20)),
                interpolation: .linear
            ),
            Keyframe(
                time: try editTime(8),
                value: CanvasPoint(x: RationalValue(40), y: RationalValue(60)),
                interpolation: .hold
            )
        ]
    )
}

private func userAuthoredRotationAnimation() throws -> Animatable<ClipRotation> {
    try Animatable(
        base: .zero,
        keyframes: [
            Keyframe(
                time: try editTime(0),
                value: ClipRotation(degrees: RationalValue(15)),
                interpolation: .linear
            ),
            Keyframe(
                time: try editTime(8),
                value: ClipRotation(degrees: RationalValue(45)),
                interpolation: .hold
            )
        ]
    )
}

private func userAuthoredRevealFraction() throws -> Animatable<RationalValue> {
    try Animatable(
        base: RationalValue.one,
        keyframes: [
            Keyframe(
                time: try editTime(0),
                value: RationalValue.zero,
                interpolation: .linear
            ),
            Keyframe(
                time: try editTime(8),
                value: RationalValue.one,
                interpolation: .hold
            )
        ]
    )
}

func replacingTitleClip(
    _ clip: Clip,
    in fixture: TitleProjectFixture
) throws -> Project {
    let project = fixture.project
    let sequence = try XCTUnwrap(
        project.sequences.first { $0.id == fixture.sequenceID }
    )
    let videoTracks = sequence.videoTracks.map { track -> Track in
        guard track.id == fixture.videoTrackID else {
            return track
        }
        return Track(
            id: track.id,
            kind: track.kind,
            items: [.clip(clip)],
            enabled: track.enabled,
            locked: track.locked,
            muted: track.muted,
            solo: track.solo,
            hidden: track.hidden
        )
    }
    let replacement = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: videoTracks,
        audioTracks: sequence.audioTracks,
        markers: sequence.markers,
        timebase: sequence.timebase
    )
    return Project(
        schemaVersion: project.schemaVersion,
        schemaMinor: project.schemaMinor,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: project.sequences.map { item in
            item.id == sequence.id ? replacement : item
        }
    )
}
