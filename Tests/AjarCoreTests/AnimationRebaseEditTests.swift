// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Issue #198: absolute keyframe times must rebase when `timelineRange` body-moves
/// (move / make-compound / decompose / ripple). Clip-relative animation shape is preserved.
final class AnimationRebaseEditTests: XCTestCase {
    // MARK: - Move preserves clip-relative shape (per family)

    func testMoveRebasesTransformAnimationClipRelativeShape() throws {
        let fixture = try makeEditFixture(seed: 19_801)
        let project = try projectWithAnimatedClip(fixture: fixture, families: .transform)
        let before = try requiredClip(fixture.clipID, in: project, fixture: fixture)
        let beforeShape = try clipRelativeShape(
            of: before.transformAnimation.opacity,
            clipStart: before.timelineRange.start
        )

        let edited = try apply(
            animationRebaseMoveCommand(fixture: fixture, toStartFrame: 12),
            to: project
        )
        let after = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(after.timelineRange.start, try editTime(12))
        try assertClipRelativeShape(
            of: after.transformAnimation.opacity,
            clipStart: after.timelineRange.start,
            equals: beforeShape
        )
        XCTAssertEqual(
            after.transformAnimation.opacity.keyframes.map(\.time),
            [try editTime(14), try editTime(18)]
        )
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testMoveRebasesAudioMixAutomationClipRelativeShape() throws {
        let fixture = try makeEditFixture(seed: 19_802)
        let project = try projectWithAnimatedClip(fixture: fixture, families: .audioMix)
        let before = try requiredClip(fixture.clipID, in: project, fixture: fixture)
        let beforeGain = try clipRelativeShape(
            of: before.audioMix.gain,
            clipStart: before.timelineRange.start
        )
        let beforePan = try clipRelativeShape(
            of: before.audioMix.pan,
            clipStart: before.timelineRange.start
        )

        let edited = try apply(
            animationRebaseMoveCommand(fixture: fixture, toStartFrame: 8),
            to: project
        )
        let after = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        try assertClipRelativeShape(
            of: after.audioMix.gain,
            clipStart: after.timelineRange.start,
            equals: beforeGain
        )
        try assertClipRelativeShape(
            of: after.audioMix.pan,
            clipStart: after.timelineRange.start,
            equals: beforePan
        )
        XCTAssertEqual(
            after.audioMix.gain.keyframes.map(\.time),
            [try editTime(10), try editTime(14)]
        )
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testMoveRebasesEffectStackAnimationClipRelativeShape() throws {
        let fixture = try makeEditFixture(seed: 19_803)
        let project = try projectWithAnimatedClip(fixture: fixture, families: .effectStack)
        let before = try requiredClip(fixture.clipID, in: project, fixture: fixture)
        let beforeAmount = try placeholderAmount(of: before.effectStackAnimation)
        let beforeShape = try clipRelativeShape(
            of: beforeAmount,
            clipStart: before.timelineRange.start
        )

        let edited = try apply(
            animationRebaseMoveCommand(fixture: fixture, toStartFrame: 6),
            to: project
        )
        let after = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let afterAmount = try placeholderAmount(of: after.effectStackAnimation)

        try assertClipRelativeShape(
            of: afterAmount,
            clipStart: after.timelineRange.start,
            equals: beforeShape
        )
        XCTAssertEqual(afterAmount.keyframes.map(\.time), [try editTime(8), try editTime(12)])
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testMoveRebasesTitleRevealFractionClipRelativeShape() throws {
        let fixture = try makeEditFixture(seed: 19_804)
        let project = try projectWithAnimatedClip(fixture: fixture, families: .titleReveal)
        let before = try requiredClip(fixture.clipID, in: project, fixture: fixture)
        let beforeReveal = try revealFraction(of: before)
        let beforeShape = try clipRelativeShape(
            of: beforeReveal,
            clipStart: before.timelineRange.start
        )

        let edited = try apply(
            animationRebaseMoveCommand(fixture: fixture, toStartFrame: 15),
            to: project
        )
        let after = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let afterReveal = try revealFraction(of: after)

        try assertClipRelativeShape(
            of: afterReveal,
            clipStart: after.timelineRange.start,
            equals: beforeShape
        )
        XCTAssertEqual(afterReveal.keyframes.map(\.time), [try editTime(17), try editTime(21)])
        XCTAssertEqual(edited.validate(), .valid)
    }

    // MARK: - Make-compound → decompose round-trip

    func testMakeCompoundThenDecomposeRoundTripsAllAnimationFamilies() throws {
        let fixture = try makeEditFixture(seed: 19_810)
        let families: AnimationFamily = [.transform, .audioMix, .effectStack, .titleReveal]
        let project = try projectWithAnimatedClip(
            fixture: fixture,
            families: families,
            startFrame: 10
        )
        let before = try requiredClip(fixture.clipID, in: project, fixture: fixture)

        let compoundSequenceID = try editUUID(19_810_901)
        let compoundClipID = try editUUID(19_810_902)
        let compounded = try apply(
            .makeCompoundClip(
                sequenceID: fixture.sequenceID,
                compoundSequenceID: compoundSequenceID,
                compoundClipID: compoundClipID,
                selectedClips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: fixture.clipID)
                ],
                name: "Animated Compound"
            ),
            to: project
        )

        let nestedSequence = try XCTUnwrap(
            compounded.sequences.first { $0.id == compoundSequenceID }
        )
        let nestedClip = try XCTUnwrap(clip(fixture.clipID, in: nestedSequence.videoTracks[0]))
        try assertRange(nestedClip.timelineRange, startFrame: 0, durationFrames: 10)
        XCTAssertEqual(
            nestedClip.transformAnimation.opacity.keyframes.map(\.time),
            [try editTime(2), try editTime(6)]
        )
        XCTAssertEqual(
            nestedClip.audioMix.gain.keyframes.map(\.time),
            [try editTime(2), try editTime(6)]
        )
        let nestedAmount = try placeholderAmount(of: nestedClip.effectStackAnimation)
        XCTAssertEqual(nestedAmount.keyframes.map(\.time), [try editTime(2), try editTime(6)])
        let nestedReveal = try revealFraction(of: nestedClip)
        XCTAssertEqual(nestedReveal.keyframes.map(\.time), [try editTime(2), try editTime(6)])

        let expanded = try apply(
            .decomposeCompoundClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: compoundClipID
            ),
            to: compounded
        )
        let after = try requiredClip(fixture.clipID, in: expanded, fixture: fixture)

        XCTAssertEqual(after.timelineRange, before.timelineRange)
        XCTAssertEqual(after.transformAnimation, before.transformAnimation)
        XCTAssertEqual(after.audioMix.gain, before.audioMix.gain)
        XCTAssertEqual(after.audioMix.pan, before.audioMix.pan)
        XCTAssertEqual(after.effectStackAnimation, before.effectStackAnimation)
        XCTAssertEqual(try revealFraction(of: after), try revealFraction(of: before))
        XCTAssertEqual(expanded.validate(), .valid)
    }

    // MARK: - Ripple move rebases downstream clips

    func testRippleInsertRebasesDownstreamAnimatedClip() throws {
        let fixture = try makeEditFixture(seed: 19_820)
        let animated = try makeFullyAnimatedClip(
            id: fixture.clipID,
            mediaID: fixture.mediaID,
            startFrame: 10,
            families: .transform
        )
        let project = try replacingVideoItems([.clip(animated)], in: fixture)
        let before = try requiredClip(fixture.clipID, in: project, fixture: fixture)
        let beforeShape = try clipRelativeShape(
            of: before.transformAnimation.opacity,
            clipStart: before.timelineRange.start
        )

        let inserted = try makeEditClip(
            id: try editUUID(19_820_050),
            mediaID: fixture.mediaID,
            startFrame: 0,
            durationFrames: 4
        )
        let edited = try apply(
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: inserted
            ),
            to: project
        )
        let after = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(after.timelineRange.start, try editTime(14))
        try assertClipRelativeShape(
            of: after.transformAnimation.opacity,
            clipStart: after.timelineRange.start,
            equals: beforeShape
        )
        XCTAssertEqual(
            after.transformAnimation.opacity.keyframes.map(\.time),
            [try editTime(16), try editTime(20)]
        )
        XCTAssertEqual(edited.validate(), .valid)
    }

    // MARK: - Mid-animation render content-hash after move

    func testMovedClipMidAnimationContentHashMatchesClipRelativeOffset() throws {
        let fixture = try makeEditFixture(seed: 19_830)
        let project = try projectWithAnimatedClip(
            fixture: fixture,
            families: .transform,
            startFrame: 0
        )
        let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })

        let beforeGraph = try buildRenderGraph(
            for: sequence,
            at: try editTime(4),
            in: project
        )
        let beforeHash = try XCTUnwrap(beforeGraph.outputNode?.contentHash)
        let beforeTransform = try animationRebaseCompositeInput(in: beforeGraph).transform

        let moved = try apply(
            animationRebaseMoveCommand(fixture: fixture, toStartFrame: 20),
            to: project
        )
        let movedSequence = try XCTUnwrap(moved.sequences.first { $0.id == fixture.sequenceID })
        let afterGraph = try buildRenderGraph(
            for: movedSequence,
            at: try editTime(24),
            in: moved
        )
        let afterHash = try XCTUnwrap(afterGraph.outputNode?.contentHash)
        let afterTransform = try animationRebaseCompositeInput(in: afterGraph).transform

        XCTAssertEqual(beforeTransform, afterTransform)
        XCTAssertEqual(beforeHash, afterHash)
    }

    // MARK: - Blade remains absolute (no double-rebase regression)

    func testBladeKeyframeTimesRemainAbsoluteSequenceTimes() throws {
        let fixture = try makeEditFixture(seed: 19_840)
        let project = try projectWithAnimatedClip(
            fixture: fixture,
            families: .transform,
            startFrame: 0
        )
        let cut = try editTime(4)
        let edited = try apply(
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                atTime: cut,
                rightClipID: try editUUID(19_840_500)
            ),
            to: project
        )
        let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let right = try requiredClip(
            try editUUID(19_840_500),
            trackID: fixture.videoTrackID,
            in: edited,
            sequenceID: fixture.sequenceID
        )
        XCTAssertEqual(
            left.transformAnimation.opacity.keyframes.map(\.time),
            [try editTime(2), cut]
        )
        XCTAssertEqual(
            right.transformAnimation.opacity.keyframes.map(\.time),
            [cut, try editTime(6)]
        )
        XCTAssertEqual(edited.validate(), .valid)
    }
}
