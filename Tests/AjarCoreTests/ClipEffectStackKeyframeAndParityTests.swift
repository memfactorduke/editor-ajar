// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// Regression coverage for FR-FX-003 enable-toggle keyframe preservation and static/animated
/// stack parity validation.
final class ClipEffectStackKeyframeAndParityTests: XCTestCase {
    func testFRFX003EnableTogglePreservesKeyframedAmountBitIdentically() throws {
        let fixture = try makeEditFixture(seed: 5_400)
        let nodeID = try editUUID(5_400_100)
        let (project, originalAnimation) = try keyedStackProject(
            fixture: fixture,
            nodeID: nodeID,
            name: "Keyed stack"
        )
        XCTAssertTrue(project.validate().isValid)

        let disabled = try apply(
            .setClipEffectNodeEnabled(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                nodeID: nodeID,
                enabled: false
            ),
            to: project
        )
        let disabledClip = try requiredClip(fixture.clipID, in: disabled, fixture: fixture)
        XCTAssertEqual(disabledClip.effectStack.nodes[0].enabled, false)
        XCTAssertEqual(
            disabledClip.effectStackAnimation.nodes[0].definition,
            originalAnimation.nodes[0].definition
        )

        let reenabled = try apply(
            .setClipEffectNodeEnabled(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                nodeID: nodeID,
                enabled: true
            ),
            to: disabled
        )
        let reenabledClip = try requiredClip(fixture.clipID, in: reenabled, fixture: fixture)
        XCTAssertEqual(reenabledClip.effectStack.nodes[0].enabled, true)
        // Bit-identical animated definition after disable → enable (ADR-0016 §2).
        XCTAssertEqual(
            reenabledClip.effectStackAnimation.nodes[0].definition,
            originalAnimation.nodes[0].definition
        )
        XCTAssertEqual(reenabledClip.effectStackAnimation.nodes[0], originalAnimation.nodes[0])
        XCTAssertTrue(reenabled.validate().isValid)
    }

    func testFRFX003SetParametersOnKeyframedNodeConstantReplacesAnimation() throws {
        let fixture = try makeEditFixture(seed: 5_410)
        let nodeID = try editUUID(5_410_100)
        let (project, _) = try keyedStackProject(
            fixture: fixture,
            nodeID: nodeID,
            name: "Keyed params"
        )
        let newDefinition = ClipEffectDefinition.placeholder(
            ClipPlaceholderEffectParameters(amount: try rational(7, 10))
        )
        let updated = try apply(
            .setClipEffectNodeParameters(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                nodeID: nodeID,
                definition: newDefinition
            ),
            to: project
        )
        let clip = try requiredClip(fixture.clipID, in: updated, fixture: fixture)
        XCTAssertEqual(clip.effectStack.nodes[0].definition, newDefinition)
        XCTAssertEqual(clip.effectStackAnimation.nodes[0].definition, .constant(newDefinition))
        // Keyframes must be gone — constant-replacement discipline.
        guard case .placeholder(let parameters) = clip.effectStackAnimation.nodes[0].definition
        else {
            XCTFail("Expected placeholder definition")
            return
        }
        XCTAssertTrue(parameters.amount.keyframes.isEmpty)
        XCTAssertEqual(parameters.amount.base, try rational(7, 10))
        XCTAssertTrue(updated.validate().isValid)
    }

    func testFRFX003ValidationRejectsStaticAnimationIDMismatch() throws {
        let fixture = try makeEditFixture(seed: 5_420)
        let project = try mismatchedStackProject(
            fixture: fixture,
            staticNodes: [
                ClipEffectNode(
                    id: try editUUID(5_420_100),
                    definition: .placeholder(
                        ClipPlaceholderEffectParameters(amount: try rational(1, 5))
                    )
                )
            ],
            animatedNodes: [
                AnimatableClipEffectNode(
                    id: try editUUID(5_420_101),
                    definition: .placeholder(
                        AnimatableClipPlaceholderSettings(
                            amount: .constant(try rational(1, 5))
                        )
                    )
                )
            ]
        )
        assertParityMismatch(project, fixture: fixture)
    }

    func testFRFX003ValidationRejectsStaticAnimationOrderMismatch() throws {
        let fixture = try makeEditFixture(seed: 5_430)
        let first = ClipEffectNode(
            id: try editUUID(5_430_100),
            definition: .placeholder(
                ClipPlaceholderEffectParameters(amount: try rational(1, 5))
            )
        )
        let second = ClipEffectNode(
            id: try editUUID(5_430_101),
            definition: .placeholder(
                ClipPlaceholderEffectParameters(amount: try rational(2, 5))
            )
        )
        let reversedAnimation: [AnimatableClipEffectNode] =
            [AnimatableClipEffectNode.constant(second)]
            + [AnimatableClipEffectNode.constant(first)]
        let project = try mismatchedStackProject(
            fixture: fixture,
            staticNodes: [first, second],
            animatedNodes: reversedAnimation
        )
        assertParityMismatch(project, fixture: fixture)
    }

    func testFRFX003ValidationAcceptsMatchingStaticAndAnimationStacks() throws {
        let fixture = try makeEditFixture(seed: 5_440)
        let (project, animation) = try keyedStackProject(
            fixture: fixture,
            nodeID: try editUUID(5_440_100),
            name: "Parity match"
        )
        let clip = try requiredClip(fixture.clipID, in: project, fixture: fixture)
        XCTAssertEqual(animation.baseStack, clip.effectStack)
        XCTAssertTrue(project.validate().isValid)
    }
}

private func keyedStackProject(
    fixture: EditFixture,
    nodeID: UUID,
    name: String
) throws -> (Project, AnimatableClipEffectStack) {
    let keyedAmount = try makeKeyedAmount()
    let stack = ClipEffectStack(
        nodes: [
            ClipEffectNode(
                id: nodeID,
                enabled: true,
                definition: .placeholder(
                    ClipPlaceholderEffectParameters(amount: keyedAmount.base)
                )
            )
        ]
    )
    let animation = AnimatableClipEffectStack(
        nodes: [
            AnimatableClipEffectNode(
                id: nodeID,
                enabled: true,
                definition: .placeholder(
                    AnimatableClipPlaceholderSettings(amount: keyedAmount)
                )
            )
        ]
    )
    let project = try replacingVideoItems(
        [
            .clip(
                Clip(
                    id: fixture.clipID,
                    source: .media(id: fixture.mediaID),
                    sourceRange: try editRange(startFrame: 0, durationFrames: 10),
                    timelineRange: try editRange(startFrame: 0, durationFrames: 10),
                    kind: .video,
                    name: name,
                    effectStack: stack,
                    effectStackAnimation: animation
                )
            )
        ],
        in: fixture
    )
    return (project, animation)
}

private func makeKeyedAmount() throws -> Animatable<RationalValue> {
    let start = Keyframe(
        time: try editTime(0),
        value: try rational(1, 5),
        interpolation: InterpolationMode.linear
    )
    let end = Keyframe(
        time: try editTime(8),
        value: try rational(4, 5),
        interpolation: InterpolationMode.linear
    )
    return try Animatable(base: try rational(1, 5), keyframes: [start, end])
}

private func mismatchedStackProject(
    fixture: EditFixture,
    staticNodes: [ClipEffectNode],
    animatedNodes: [AnimatableClipEffectNode]
) throws -> Project {
    try replacingVideoItems(
        [
            .clip(
                Clip(
                    id: fixture.clipID,
                    source: .media(id: fixture.mediaID),
                    sourceRange: try editRange(startFrame: 0, durationFrames: 10),
                    timelineRange: try editRange(startFrame: 0, durationFrames: 10),
                    kind: .video,
                    name: "Parity mismatch",
                    effectStack: ClipEffectStack(nodes: staticNodes),
                    effectStackAnimation: AnimatableClipEffectStack(nodes: animatedNodes)
                )
            )
        ],
        in: fixture
    )
}

private func assertParityMismatch(_ project: Project, fixture: EditFixture) {
    guard case .invalid(let errors) = project.validate() else {
        XCTFail("Expected parity mismatch to fail validation")
        return
    }
    XCTAssertTrue(
        errors.contains(
            .invalidClipEffectStack(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                error: .staticAnimationParityMismatch
            )
        )
    )
}
