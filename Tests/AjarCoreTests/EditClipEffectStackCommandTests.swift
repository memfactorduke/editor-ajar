// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-003 unit coverage for the per-clip video effects stack edit commands.
final class EditClipEffectStackCommandTests: XCTestCase {
    func testFRFX003EmptyStackIsDefaultOnNewClips() throws {
        let fixture = try makeEditFixture(seed: 5_100)
        let clip = try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)

        XCTAssertEqual(clip.effectStack, .empty)
        XCTAssertEqual(clip.effectStackAnimation, .empty)
        XCTAssertEqual(clip.effectStackAnimation, .constant(clip.effectStack))
    }

    func testFRFX003AddRemoveReorderToggleSetParameterResetUndoRoundTrips() throws {
        let fixture = try makeEditFixture(seed: 5_110)
        let first = try makePlaceholderNode(id: editUUID(5_110_100), amount: rational(1, 4))
        let second = try makePlaceholderNode(id: editUUID(5_110_101), amount: rational(1, 2))
        let third = try makePlaceholderNode(
            id: editUUID(5_110_102),
            amount: rational(3, 4),
            enabled: false
        )
        var history = EditHistory(project: fixture.project)
        let snapshots = try applyStackEditSequence(
            history: &history,
            fixture: fixture,
            first: first,
            second: second,
            third: third
        )
        XCTAssertEqual(history.undo(), snapshots.afterRemove)
        XCTAssertEqual(history.undo(), snapshots.afterResetNode)
        XCTAssertEqual(history.undo(), snapshots.afterSet)
        XCTAssertEqual(history.undo(), snapshots.afterToggle)
        XCTAssertEqual(history.undo(), snapshots.afterMove)
        XCTAssertEqual(history.undo(), snapshots.afterInsertThird)
        XCTAssertEqual(history.undo(), snapshots.afterAddSecond)
        XCTAssertEqual(history.undo(), snapshots.afterAddFirst)
        XCTAssertEqual(history.undo(), fixture.project)
    }

    func testFRFX003TypedErrorsForMissingNodeBadIndexDuplicateAndOutOfRange() throws {
        let fixture = try makeEditFixture(seed: 5_120)
        let node = try makePlaceholderNode(id: editUUID(5_120_100), amount: rational(1, 5))
        let withNode = try apply(addNodeCommand(node, fixture: fixture), to: fixture.project)
        let missingID = try editUUID(5_120_999)

        assertInvalidEdit(
            {
                try apply(
                    .removeClipEffectNode(
                        sequenceID: fixture.sequenceID,
                        trackID: fixture.videoTrackID,
                        clipID: fixture.clipID,
                        nodeID: missingID
                    ),
                    to: withNode
                )
            },
            equals: .clipEffectNodeNotFound(clipID: fixture.clipID, nodeID: missingID)
        )
        assertInvalidEdit(
            {
                try apply(
                    .moveClipEffectNode(
                        sequenceID: fixture.sequenceID,
                        trackID: fixture.videoTrackID,
                        clipID: fixture.clipID,
                        nodeID: node.id,
                        destinationIndex: 3
                    ),
                    to: withNode
                )
            },
            equals: .clipEffectNodeDestinationIndexOutOfRange(
                clipID: fixture.clipID, index: 3, count: 1
            )
        )
        assertInvalidEdit(
            { try apply(addNodeCommand(node, fixture: fixture), to: withNode) },
            equals: .duplicateClipEffectNodeID(clipID: fixture.clipID, nodeID: node.id)
        )
        let highAmount = try rational(5, 4)
        assertInvalidEdit(
            {
                try apply(
                    .setClipEffectNodeParameters(
                        sequenceID: fixture.sequenceID,
                        trackID: fixture.videoTrackID,
                        clipID: fixture.clipID,
                        nodeID: node.id,
                        definition: .placeholder(
                            ClipPlaceholderEffectParameters(amount: highAmount)
                        )
                    ),
                    to: withNode
                )
            },
            equals: .invalidClipEffectStack(
                clipID: fixture.clipID,
                error: .placeholderAmountOutOfRange(highAmount)
            )
        )
    }

    func testFRFX003BladeAndCopyPreserveEffectStack() throws {
        let fixture = try makeEditFixture(seed: 5_130)
        let keyed = try makeKeyedStackProject(fixture: fixture)
        let bladed = try apply(
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                atTime: try editTime(4),
                rightClipID: keyed.rightClipID
            ),
            to: keyed.project
        )
        let left = try requiredClip(fixture.clipID, in: bladed, fixture: fixture)
        let right = try requiredClip(keyed.rightClipID, in: bladed, fixture: fixture)
        let nodeID = keyed.stack.nodes[0].id

        XCTAssertEqual(left.effectStack, keyed.stack)
        XCTAssertEqual(right.effectStack, keyed.stack)
        XCTAssertEqual(left.effectStack.nodes.map(\.id), [nodeID])
        XCTAssertEqual(right.effectStack.nodes.map(\.id), [nodeID])
        let midLeft = try editTime(2)
        let midRight = try editTime(6)
        XCTAssertEqual(
            left.effectStackAnimation.value(at: midLeft).nodes[0].definition,
            keyed.animation.value(at: midLeft).nodes[0].definition
        )
        XCTAssertEqual(
            right.effectStackAnimation.value(at: midRight).nodes[0].definition,
            keyed.animation.value(at: midRight).nodes[0].definition
        )
        let renamed = EditReducer.copying(left, name: "Renamed")
        XCTAssertEqual(renamed.effectStack, left.effectStack)
        XCTAssertEqual(renamed.effectStackAnimation, left.effectStackAnimation)
    }

    func testFRFX003ProjectValidationRejectsInvalidStoredStack() throws {
        let fixture = try makeEditFixture(seed: 5_140)
        let highAmount = try rational(3, 2)
        let invalid = Clip(
            id: fixture.clipID,
            source: .media(id: fixture.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Invalid stack",
            effectStack: ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try editUUID(5_140_100),
                        definition: .placeholder(
                            ClipPlaceholderEffectParameters(amount: highAmount)
                        )
                    )
                ]
            )
        )
        let project = try replacingVideoItems([.clip(invalid)], in: fixture)
        guard case .invalid(let errors) = project.validate() else {
            XCTFail("Expected invalid project")
            return
        }
        XCTAssertTrue(
            errors.contains(
                .invalidClipEffectStack(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    error: .placeholderAmountOutOfRange(highAmount)
                )
            )
        )
    }
}

// MARK: - Helpers

private struct StackEditSnapshots {
    let afterAddFirst: Project
    let afterAddSecond: Project
    let afterInsertThird: Project
    let afterMove: Project
    let afterToggle: Project
    let afterSet: Project
    let afterResetNode: Project
    let afterRemove: Project
}

// swiftlint:disable:next function_body_length
private func applyStackEditSequence(
    history: inout EditHistory,
    fixture: EditFixture,
    first: ClipEffectNode,
    second: ClipEffectNode,
    third: ClipEffectNode
) throws -> StackEditSnapshots {
    let afterAddFirst = try history.apply(addNodeCommand(first, fixture: fixture))
    let afterAddSecond = try history.apply(addNodeCommand(second, fixture: fixture))
    let afterInsertThird = try history.apply(
        addNodeCommand(third, fixture: fixture, destinationIndex: 1)
    )
    let afterMove = try history.apply(
        .moveClipEffectNode(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: third.id,
            destinationIndex: 2
        )
    )
    let afterToggle = try history.apply(
        .setClipEffectNodeEnabled(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: second.id,
            enabled: false
        )
    )
    let newDefinition = ClipEffectDefinition.placeholder(
        ClipPlaceholderEffectParameters(amount: try rational(1, 1))
    )
    let afterSet = try history.apply(
        .setClipEffectNodeParameters(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: first.id,
            definition: newDefinition
        )
    )
    let setClip = try requiredClip(fixture.clipID, in: afterSet, fixture: fixture)
    XCTAssertEqual(setClip.effectStack.nodes[0].definition, newDefinition)
    let afterResetNode = try history.apply(
        .resetClipEffectNode(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: first.id
        )
    )
    let afterRemove = try history.apply(
        .removeClipEffectNode(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: third.id
        )
    )
    _ = try history.apply(
        .resetClipEffectStack(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID
        )
    )
    return StackEditSnapshots(
        afterAddFirst: afterAddFirst,
        afterAddSecond: afterAddSecond,
        afterInsertThird: afterInsertThird,
        afterMove: afterMove,
        afterToggle: afterToggle,
        afterSet: afterSet,
        afterResetNode: afterResetNode,
        afterRemove: afterRemove
    )
}

private struct KeyedStackFixture {
    let project: Project
    let stack: ClipEffectStack
    let animation: AnimatableClipEffectStack
    let rightClipID: UUID
}

private func makeKeyedStackProject(fixture: EditFixture) throws -> KeyedStackFixture {
    let startKey = Keyframe(
        time: try editTime(0), value: try rational(1, 5), interpolation: InterpolationMode.linear
    )
    let endKey = Keyframe(
        time: try editTime(8), value: try rational(4, 5), interpolation: InterpolationMode.linear
    )
    let keyedAmount = try Animatable(base: try rational(1, 5), keyframes: [startKey, endKey])
    // Static snapshot must match animation base (FR-FX-003 parity).
    let node = try makePlaceholderNode(id: editUUID(5_130_100), amount: keyedAmount.base)
    let stack = ClipEffectStack(nodes: [node])
    let animation = AnimatableClipEffectStack(
        nodes: [
            AnimatableClipEffectNode(
                id: node.id,
                enabled: true,
                definition: .placeholder(AnimatableClipPlaceholderSettings(amount: keyedAmount))
            )
        ]
    )
    let clip = Clip(
        id: fixture.clipID,
        source: .media(id: fixture.mediaID),
        sourceRange: try editRange(startFrame: 0, durationFrames: 10),
        timelineRange: try editRange(startFrame: 0, durationFrames: 10),
        kind: .video,
        name: "Stack clip",
        effectStack: stack,
        effectStackAnimation: animation
    )
    return KeyedStackFixture(
        project: try replacingVideoItems([.clip(clip)], in: fixture),
        stack: stack,
        animation: animation,
        rightClipID: try editUUID(5_130_200)
    )
}

func makePlaceholderNode(
    id: UUID,
    amount: RationalValue,
    enabled: Bool = true
) -> ClipEffectNode {
    ClipEffectNode(
        id: id,
        enabled: enabled,
        definition: .placeholder(ClipPlaceholderEffectParameters(amount: amount))
    )
}

func addNodeCommand(
    _ node: ClipEffectNode,
    fixture: EditFixture,
    destinationIndex: Int? = nil
) -> EditCommand {
    .addClipEffectNode(
        sequenceID: fixture.sequenceID,
        trackID: fixture.videoTrackID,
        clipID: fixture.clipID,
        node: node,
        destinationIndex: destinationIndex
    )
}

func rational(_ numerator: Int64, _ denominator: Int64) throws -> RationalValue {
    try RationalValue(numerator: numerator, denominator: denominator)
}

private func assertInvalidEdit(
    _ expression: () throws -> Project,
    equals expected: EditCommandValidationError
) {
    XCTAssertThrowsError(try expression()) { error in
        XCTAssertEqual(error as? EditReducerError, .invalidEdit(expected))
    }
}
