// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-003 property-style coverage: random command sequences keep the stack consistent
/// and full undo restores the start project exactly.
final class EditClipEffectStackPropertyTests: XCTestCase {
    func testFRFX003PropertyRandomCommandSequencesKeepStackConsistentAndUndoExact() throws {
        for seed in 0..<24 {
            try runEffectStackPropertyTrial(seed: 5_200 + seed)
        }
    }
}

private func runEffectStackPropertyTrial(seed: Int) throws {
    let fixture = try makeEditFixture(seed: seed)
    var history = EditHistory(project: fixture.project)
    var rng = EffectStackRNG(seed: UInt64(seed))
    var nextNodeSeed = seed * 1_000 + 50

    for _ in 0..<40 {
        let clip = try requiredClip(
            fixture.clipID,
            in: history.currentProject,
            fixture: fixture
        )
        try applyRandomStackCommand(
            nodes: clip.effectStack.nodes,
            fixture: fixture,
            history: &history,
            rng: &rng,
            nextNodeSeed: &nextNodeSeed
        )
        let after = try requiredClip(
            fixture.clipID,
            in: history.currentProject,
            fixture: fixture
        )
        assertEffectStackConsistent(after.effectStack, animation: after.effectStackAnimation)
        XCTAssertTrue(history.currentProject.validate().isValid)
    }

    while history.undoCount > 0 {
        _ = history.undo()
    }
    XCTAssertEqual(history.currentProject, fixture.project)
}

private func applyRandomStackCommand(
    nodes: [ClipEffectNode],
    fixture: EditFixture,
    history: inout EditHistory,
    rng: inout EffectStackRNG,
    nextNodeSeed: inout Int
) throws {
    let choice = rng.nextInt(upperBound: 7)
    if choice == 0 {
        try applyRandomAdd(
            nodes: nodes,
            fixture: fixture,
            history: &history,
            rng: &rng,
            nextNodeSeed: &nextNodeSeed
        )
        return
    }
    if nodes.isEmpty {
        _ = try? history.apply(
            .resetClipEffectStack(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            )
        )
        return
    }
    let node = nodes[rng.nextInt(upperBound: nodes.count)]
    let roll = MutationRoll(
        choice: choice,
        node: node,
        nodeCount: nodes.count,
        destinationIndex: rng.nextInt(upperBound: max(nodes.count, 1)),
        enabled: rng.nextInt(upperBound: 2) == 0,
        amount: try rational(Int64(rng.nextInt(upperBound: 11)), 10)
    )
    _ = try? history.apply(randomMutationCommand(roll: roll, fixture: fixture))
}

private struct MutationRoll {
    let choice: Int
    let node: ClipEffectNode
    let nodeCount: Int
    let destinationIndex: Int
    let enabled: Bool
    let amount: RationalValue
}

private func randomMutationCommand(roll: MutationRoll, fixture: EditFixture) -> EditCommand {
    switch roll.choice {
    case 1:
        return .removeClipEffectNode(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: roll.node.id
        )
    case 2 where roll.nodeCount >= 2:
        return .moveClipEffectNode(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: roll.node.id,
            destinationIndex: roll.destinationIndex
        )
    case 3:
        return .setClipEffectNodeEnabled(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: roll.node.id,
            enabled: roll.enabled
        )
    case 4:
        return .setClipEffectNodeParameters(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: roll.node.id,
            definition: .placeholder(ClipPlaceholderEffectParameters(amount: roll.amount))
        )
    case 5:
        return .resetClipEffectNode(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            nodeID: roll.node.id
        )
    default:
        return .resetClipEffectStack(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID
        )
    }
}

private func applyRandomAdd(
    nodes: [ClipEffectNode],
    fixture: EditFixture,
    history: inout EditHistory,
    rng: inout EffectStackRNG,
    nextNodeSeed: inout Int
) throws {
    let nodeID = try editUUID(nextNodeSeed)
    nextNodeSeed += 1
    let amount = try rational(Int64(rng.nextInt(upperBound: 11)), 10)
    let node = ClipEffectNode(
        id: nodeID,
        enabled: rng.nextInt(upperBound: 2) == 0,
        definition: .placeholder(ClipPlaceholderEffectParameters(amount: amount))
    )
    let destination: Int?
    if nodes.isEmpty || rng.nextInt(upperBound: 2) == 0 {
        destination = nil
    } else {
        destination = rng.nextInt(upperBound: nodes.count + 1)
    }
    _ = try? history.apply(
        addNodeCommand(node, fixture: fixture, destinationIndex: destination)
    )
}

private func assertEffectStackConsistent(
    _ stack: ClipEffectStack,
    animation: AnimatableClipEffectStack
) {
    XCTAssertEqual(stack.nodes.count, animation.nodes.count)
    var seen: Set<UUID> = []
    for (staticNode, animatedNode) in zip(stack.nodes, animation.nodes) {
        XCTAssertEqual(staticNode.id, animatedNode.id)
        XCTAssertEqual(staticNode.enabled, animatedNode.enabled)
        XCTAssertEqual(staticNode.kind, animatedNode.kind)
        XCTAssertFalse(seen.contains(staticNode.id))
        seen.insert(staticNode.id)
    }
    XCTAssertEqual(ClipEffectStackValidator.errors(for: stack), [])
    XCTAssertEqual(ClipEffectStackValidator.errors(for: animation), [])
}

/// Tiny deterministic PRNG for property-style edit sequences (SplitMix64 step).
private struct EffectStackRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else {
            return 0
        }
        return Int(next() % UInt64(upperBound))
    }
}
