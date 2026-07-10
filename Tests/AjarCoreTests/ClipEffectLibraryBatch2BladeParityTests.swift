// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-002 batch-2 blade fidelity and static/animation parity validation.
final class ClipEffectLibraryBatch2BladeParityTests: XCTestCase {
    func testFRFX002Batch2BladeSplitPreservesEveryScalarAndDiscreteSetting() throws {
        let animation = try batch2AnimationStack()
        let cut = try editTime(4)
        let before = try editTime(2)
        let after = try editTime(6)
        let split = try animation.bladed(at: cut)

        XCTAssertEqual(split.left.value(at: before), animation.value(at: before))
        XCTAssertEqual(split.left.value(at: cut), animation.value(at: cut))
        XCTAssertEqual(split.right.value(at: cut), animation.value(at: cut))
        XCTAssertEqual(split.right.value(at: after), animation.value(at: after))
        XCTAssertEqual(split.left.nodes.map(\.id), animation.nodes.map(\.id))
        XCTAssertEqual(split.right.nodes.map(\.kind), animation.nodes.map(\.kind))
    }

    func testFRFX002Batch2ProjectParityAcceptsMatchingBaseAndRejectsChangedBase() throws {
        let fixture = try makeEditFixture(seed: 6_340)
        let animation = try batch2AnimationStack()
        let stack = animation.baseStack
        let good = try fx002Project(stack: stack, animation: animation, fixture: fixture)
        XCTAssertTrue(good.validate().isValid)

        var changedNodes = animation.nodes
        let colorIndex = try XCTUnwrap(changedNodes.firstIndex { $0.kind == .colorAdjust })
        changedNodes[colorIndex] = AnimatableClipEffectNode(
            id: changedNodes[colorIndex].id,
            definition: .colorAdjust(
                AnimatableClipColorAdjustSettings(brightness: .constant(.one))
            )
        )
        let bad = try fx002Project(
            stack: stack,
            animation: AnimatableClipEffectStack(nodes: changedNodes),
            fixture: fixture
        )
        guard case .invalid(let errors) = bad.validate() else {
            return XCTFail("expected batch-2 static/animation parity mismatch")
        }
        XCTAssertTrue(
            errors.contains {
                if case .invalidClipEffectStack(_, _, _, .staticAnimationParityMismatch) = $0 {
                    return true
                }
                return false
            }
        )
    }
}

private func batch2AnimationStack() throws -> AnimatableClipEffectStack {
    AnimatableClipEffectStack(
        nodes: try batch2SpatialAnimationNodes() + batch2ColorAnimationNodes()
    )
}

private func batch2SpatialAnimationNodes() throws -> [AnimatableClipEffectNode] {
    [
        AnimatableClipEffectNode(
            id: try editUUID(6_341),
            definition: .vignette(
                AnimatableClipVignetteSettings(
                    amount: try keyedBatch2Value(.zero, .one),
                    radius: try keyedBatch2Value(
                        try RationalValue(numerator: 1, denominator: 4),
                        try RationalValue(numerator: 3, denominator: 4)
                    ),
                    softness: try keyedBatch2Value(
                        try RationalValue(numerator: 1, denominator: 5),
                        try RationalValue(numerator: 2, denominator: 5)
                    )
                )
            )
        ),
        AnimatableClipEffectNode(
            id: try editUUID(6_342),
            definition: .mirror(AnimatableClipMirrorSettings(axis: .quad))
        ),
        AnimatableClipEffectNode(
            id: try editUUID(6_343),
            definition: .mosaic(
                AnimatableClipMosaicSettings(
                    cellSize: try keyedBatch2Value(.one, RationalValue(12))
                )
            )
        )
    ]
}

private func batch2ColorAnimationNodes() throws -> [AnimatableClipEffectNode] {
    [
        AnimatableClipEffectNode(
            id: try editUUID(6_344),
            definition: .colorAdjust(
                AnimatableClipColorAdjustSettings(
                    brightness: try keyedBatch2Value(.zero, .one),
                    contrast: try keyedBatch2Value(.one, RationalValue(2)),
                    saturation: try keyedBatch2Value(.one, RationalValue(3)),
                    tint: try keyedBatch2Value(.zero, RationalValue(-1))
                )
            )
        ),
        AnimatableClipEffectNode(
            id: try editUUID(6_345),
            definition: .posterize(
                AnimatableClipPosterizeSettings(
                    levels: try keyedBatch2Value(RationalValue(4), RationalValue(12))
                )
            )
        ),
        AnimatableClipEffectNode(
            id: try editUUID(6_346),
            definition: .invert(AnimatableClipInvertSettings())
        )
    ]
}

private func keyedBatch2Value(
    _ start: RationalValue,
    _ end: RationalValue
) throws -> Animatable<RationalValue> {
    try Animatable(
        base: start,
        keyframes: [
            Keyframe(time: try editTime(0), value: start, interpolation: .linear),
            Keyframe(time: try editTime(8), value: end, interpolation: .linear)
        ]
    )
}
