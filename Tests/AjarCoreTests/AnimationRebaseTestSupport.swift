// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

struct AnimationFamily: OptionSet {
    let rawValue: Int
    static let transform = AnimationFamily(rawValue: 1 << 0)
    static let audioMix = AnimationFamily(rawValue: 1 << 1)
    static let effectStack = AnimationFamily(rawValue: 1 << 2)
    static let titleReveal = AnimationFamily(rawValue: 1 << 3)
}

func animationRebaseMoveCommand(
    fixture: EditFixture,
    toStartFrame start: Int64
) throws -> EditCommand {
    .moveClip(
        sequenceID: fixture.sequenceID,
        sourceTrackID: fixture.videoTrackID,
        clipID: fixture.clipID,
        destinationTrackID: fixture.videoTrackID,
        timelineRange: try editRange(startFrame: start, durationFrames: 10),
        linkedClipEditMode: .unlinked
    )
}

func projectWithAnimatedClip(
    fixture: EditFixture,
    families: AnimationFamily,
    startFrame: Int64 = 0
) throws -> Project {
    let clip = try makeFullyAnimatedClip(
        id: fixture.clipID,
        mediaID: fixture.mediaID,
        startFrame: startFrame,
        families: families
    )
    return try replacingVideoItems([.clip(clip)], in: fixture)
}

func makeFullyAnimatedClip(
    id: UUID,
    mediaID: UUID,
    startFrame: Int64,
    families: AnimationFamily
) throws -> Clip {
    let span = try animationSpan(startFrame: startFrame)
    let stack = try animatedEffectStack(families: families, span: span)
    return Clip(
        id: id,
        source: try animatedSource(mediaID: mediaID, families: families, span: span),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: startFrame, durationFrames: 10),
        kind: .video,
        name: "Animated clip",
        transformAnimation: try animatedTransform(families: families, span: span),
        effectStack: stack.stack,
        effectStackAnimation: stack.animation,
        audioMix: try animatedAudioMix(families: families, span: span)
    )
}

private struct AnimationSpan {
    let t0: RationalTime
    let t1: RationalTime
    let half: RationalValue
}

private func animationSpan(startFrame: Int64) throws -> AnimationSpan {
    AnimationSpan(
        t0: try editTime(startFrame + 2),
        t1: try editTime(startFrame + 6),
        half: try RationalValue(numerator: 1, denominator: 2)
    )
}

private func animatedTransform(
    families: AnimationFamily,
    span: AnimationSpan
) throws -> AnimatableClipTransform {
    guard families.contains(.transform) else {
        return .identity
    }
    return try AnimatableClipTransform(
        opacity: Animatable(
            base: .one,
            keyframes: [
                Keyframe(time: span.t0, value: .one, interpolation: .linear),
                Keyframe(time: span.t1, value: span.half, interpolation: .linear)
            ]
        )
    )
}

private func animatedAudioMix(
    families: AnimationFamily,
    span: AnimationSpan
) throws -> ClipAudioMix {
    guard families.contains(.audioMix) else {
        return .identity
    }
    return try ClipAudioMix(
        gain: Animatable(
            base: .one,
            keyframes: [
                Keyframe(time: span.t0, value: .one, interpolation: .linear),
                Keyframe(time: span.t1, value: span.half, interpolation: .linear)
            ]
        ),
        pan: Animatable(
            base: .zero,
            keyframes: [
                Keyframe(time: span.t0, value: .zero, interpolation: .linear),
                Keyframe(time: span.t1, value: span.half, interpolation: .linear)
            ]
        )
    )
}

private func animatedEffectStack(
    families: AnimationFamily,
    span: AnimationSpan
) throws -> (stack: ClipEffectStack, animation: AnimatableClipEffectStack) {
    guard families.contains(.effectStack) else {
        return (.empty, .empty)
    }
    let nodeID = try editUUID(19_800_001)
    let node = ClipEffectNode(
        id: nodeID,
        definition: .placeholder(ClipPlaceholderEffectParameters(amount: span.half))
    )
    let animation = AnimatableClipEffectStack(
        nodes: [
            AnimatableClipEffectNode(
                id: nodeID,
                definition: .placeholder(
                    AnimatableClipPlaceholderSettings(
                        amount: try Animatable(
                            base: span.half,
                            keyframes: [
                                Keyframe(time: span.t0, value: .zero, interpolation: .linear),
                                Keyframe(time: span.t1, value: span.half, interpolation: .linear)
                            ]
                        )
                    )
                )
            )
        ]
    )
    return (ClipEffectStack(nodes: [node]), animation)
}

private func animatedSource(
    mediaID: UUID,
    families: AnimationFamily,
    span: AnimationSpan
) throws -> ClipSource {
    guard families.contains(.titleReveal) else {
        return .media(id: mediaID)
    }
    let title = try makeSampleTitle(seed: 19_800).withRevealFraction(
        try Animatable(
            base: .zero,
            keyframes: [
                Keyframe(time: span.t0, value: .zero, interpolation: .linear),
                Keyframe(time: span.t1, value: .one, interpolation: .linear)
            ]
        )
    )
    return .title(title)
}

/// Clip-relative keyframe offsets (frames from `clipStart`) paired with values.
struct RelativeKeyframe<Value: Equatable>: Equatable {
    let offsetFrames: Int64
    let value: Value
}

func clipRelativeShape<Value: Equatable>(
    of animation: Animatable<Value>,
    clipStart: RationalTime
) throws -> [RelativeKeyframe<Value>] {
    try animation.keyframes.map { keyframe in
        let offset = try keyframe.time.subtracting(clipStart)
        return RelativeKeyframe(offsetFrames: offset.value, value: keyframe.value)
    }
}

func assertClipRelativeShape<Value: Equatable>(
    of animation: Animatable<Value>,
    clipStart: RationalTime,
    equals expected: [RelativeKeyframe<Value>],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(
        try clipRelativeShape(of: animation, clipStart: clipStart),
        expected,
        file: file,
        line: line
    )
}

func placeholderAmount(
    of stack: AnimatableClipEffectStack
) throws -> Animatable<RationalValue> {
    let node = try XCTUnwrap(stack.nodes.first)
    guard case .placeholder(let settings) = node.definition else {
        struct UnexpectedKind: Error {}
        throw UnexpectedKind()
    }
    return settings.amount
}

func revealFraction(of clip: Clip) throws -> Animatable<RationalValue> {
    guard case .title(let title) = clip.source else {
        struct ExpectedTitle: Error {}
        throw ExpectedTitle()
    }
    return title.revealFraction
}

func animationRebaseCompositeInput(in graph: RenderGraph) throws -> RenderCompositeInput {
    let output = try XCTUnwrap(graph.outputNode)
    guard case .composite(let composite) = output.kind else {
        struct ExpectedComposite: Error {}
        throw ExpectedComposite()
    }
    return try XCTUnwrap(composite.inputs.first)
}

/// Project whose video track carries keyframed opacity automation and a single clip.
func projectWithTrackAutomation(
    fixture: EditFixture,
    clipStartFrame: Int64,
    opacityKeyframes: [(frame: Int64, value: RationalValue)]
) throws -> Project {
    let clip = try makeEditClip(
        id: fixture.clipID,
        mediaID: fixture.mediaID,
        startFrame: clipStartFrame,
        durationFrames: 10
    )
    let keyframes = try opacityKeyframes.map { entry in
        Keyframe(
            time: try editTime(entry.frame),
            value: entry.value,
            interpolation: InterpolationMode.linear
        )
    }
    let track = Track(
        id: fixture.videoTrackID,
        kind: .video,
        items: [.clip(clip)],
        opacity: try Animatable(base: .one, keyframes: keyframes)
    )
    let sequence = Sequence(
        id: fixture.sequenceID,
        name: "Track automation sequence",
        videoTracks: [track],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: fixture.project.settings,
        mediaPool: fixture.project.mediaPool,
        sequences: [sequence]
    )
}

/// Project with a compound clip whose nested track has keyframed opacity automation.
func projectWithKeyframedNestedTrackAutomation(
    fixture: EditFixture,
    compoundSequenceID: UUID,
    compoundClipID: UUID,
    nestedTrackID: UUID,
    nestedClipID: UUID
) throws -> Project {
    let half = try RationalValue(numerator: 1, denominator: 2)
    let nestedTrack = Track(
        id: nestedTrackID,
        kind: .video,
        items: [
            .clip(
                try makeEditClip(
                    id: nestedClipID,
                    mediaID: fixture.mediaID,
                    startFrame: 0,
                    durationFrames: 10
                )
            )
        ],
        opacity: try Animatable(
            base: .one,
            keyframes: [
                Keyframe(time: try editTime(2), value: .one, interpolation: .linear),
                Keyframe(time: try editTime(8), value: half, interpolation: .linear)
            ]
        )
    )
    let nestedSequence = Sequence(
        id: compoundSequenceID,
        name: "Keyframed nested track",
        videoTracks: [nestedTrack],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    let compoundClip = Clip(
        id: compoundClipID,
        source: .sequence(id: compoundSequenceID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Compound with track automation"
    )
    let parentSequence = Sequence(
        id: fixture.sequenceID,
        name: "Parent",
        videoTracks: [
            Track(id: fixture.videoTrackID, kind: .video, items: [.clip(compoundClip)])
        ],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: fixture.project.settings,
        mediaPool: fixture.project.mediaPool,
        sequences: [parentSequence, nestedSequence]
    )
}

/// Project whose video track has constant non-identity opacity and one clip at frame 0.
func projectWithConstantTrackOpacity(
    fixture: EditFixture,
    opacity: RationalValue
) throws -> Project {
    let clip = try makeEditClip(
        id: fixture.clipID,
        mediaID: fixture.mediaID,
        startFrame: 0,
        durationFrames: 10
    )
    let parentTrack = Track(
        id: fixture.videoTrackID,
        kind: .video,
        items: [.clip(clip)],
        opacity: .constant(opacity)
    )
    let parentSequence = Sequence(
        id: fixture.sequenceID,
        name: "Constant track automation parent",
        videoTracks: [parentTrack],
        audioTracks: [],
        markers: [],
        timebase: try FrameRate(frames: 24)
    )
    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: fixture.project.settings,
        mediaPool: fixture.project.mediaPool,
        sequences: [parentSequence]
    )
}
