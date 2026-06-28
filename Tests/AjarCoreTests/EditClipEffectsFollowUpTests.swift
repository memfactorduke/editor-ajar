// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditClipEffectsFollowUpTests: XCTestCase {
    func testFRCOMP003ColorEditPreservesUnchangedEffectAnimations() throws {
        let fixture = try makeEditFixture(seed: 1_141)
        let effectsAnimation = try makeFollowUpAnimatedEffects(seed: 1_141)
        let clip = try makeEditClip(
            id: fixture.clipID,
            mediaID: fixture.mediaID,
            startFrame: 0,
            effects: effectsAnimation.baseEffects,
            effectsAnimation: effectsAnimation
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)
        let correction = ClipColorCorrection(exposure: RationalValue(2))

        let edited = try apply(
            .setClipColorCorrection(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                correction: correction
            ),
            to: project
        )
        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(editedClip.effects.colorCorrection, correction)
        XCTAssertEqual(editedClip.effectsAnimation.chromaKey, effectsAnimation.chromaKey)
        XCTAssertEqual(editedClip.effectsAnimation.lumaKey, effectsAnimation.lumaKey)
        XCTAssertEqual(editedClip.effectsAnimation.masks, effectsAnimation.masks)
        XCTAssertEqual(editedClip.effectsAnimation.colorCorrection, .constant(correction))
    }

    func testFRCOMP003MaskEditPreservesUnchangedEffectAnimations() throws {
        let fixture = try makeEditFixture(seed: 1_142)
        let effectsAnimation = try makeFollowUpAnimatedEffects(seed: 1_142)
        let clip = try makeEditClip(
            id: fixture.clipID,
            mediaID: fixture.mediaID,
            startFrame: 0,
            effects: effectsAnimation.baseEffects,
            effectsAnimation: effectsAnimation
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)
        let addedMask = try makeFollowUpEllipseMask(id: try editUUID(1_142_900))

        let edited = try apply(
            .addClipMask(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                mask: addedMask
            ),
            to: project
        )
        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(editedClip.effects.masks, effectsAnimation.baseEffects.masks + [addedMask])
        XCTAssertEqual(editedClip.effectsAnimation.chromaKey, effectsAnimation.chromaKey)
        XCTAssertEqual(editedClip.effectsAnimation.lumaKey, effectsAnimation.lumaKey)
        XCTAssertEqual(
            editedClip.effectsAnimation.colorCorrection,
            effectsAnimation.colorCorrection
        )
        XCTAssertEqual(
            editedClip.effectsAnimation.masks,
            editedClip.effects.masks.map(AnimatableClipMask.constant)
        )
    }

    func testFRCOMP003AnimatableMaskValidationDoesNotDuplicateZeroTimeErrors() throws {
        let maskID = try editUUID(1_170_100)
        let invalidFeather = RationalValue(-1)
        let effects = AnimatableClipEffects(
            masks: [
                try AnimatableClipMask(
                    id: maskID,
                    shape: .rectangle(
                        AnimatableClipRectangleMask(
                            x: .constant(.zero),
                            y: .constant(.zero),
                            width: Animatable(
                                base: .zero,
                                keyframes: [
                                    Keyframe(
                                        time: try editTime(0),
                                        value: .zero,
                                        interpolation: .linear
                                    )
                                ]
                            ),
                            height: .constant(.one)
                        )
                    ),
                    featherRadius: Animatable(
                        base: invalidFeather,
                        keyframes: [
                            Keyframe(
                                time: try editTime(0),
                                value: invalidFeather,
                                interpolation: .linear
                            )
                        ]
                    )
                )
            ]
        )
        let errors = ClipEffectsValidator.errors(for: effects)

        XCTAssertEqual(
            errors.filter { $0 == .clipMaskRectangleSizeInvalid(maskID: maskID) }.count,
            1
        )
        XCTAssertEqual(
            errors.filter {
                $0 == .clipMaskFeatherRadiusNegative(maskID: maskID, invalidFeather)
            }.count,
            1
        )
    }

    func testFRCOMP003AnimatablePolygonValidationDoesNotDuplicatePointCountErrors() throws {
        let maskID = try editUUID(1_171_100)
        let effects = AnimatableClipEffects(
            masks: [
                AnimatableClipMask.constant(
                    ClipMask(
                        id: maskID,
                        shape: .polygon(
                            ClipPolygonMask(
                                points: [
                                    CanvasPoint(x: .zero, y: .zero),
                                    CanvasPoint(x: .one, y: .zero)
                                ]
                            )
                        )
                    )
                )
            ]
        )
        let expectedError = ClipEffectsValidationError.clipMaskPolygonPointCountInvalid(
            maskID: maskID,
            count: 2,
            maximum: ClipMaskLimits.maximumPolygonPointCount
        )

        XCTAssertEqual(
            ClipEffectsValidator.errors(for: effects).filter { $0 == expectedError }.count,
            1
        )
    }
}

private func makeFollowUpAnimatedEffects(seed: Int) throws -> AnimatableClipEffects {
    AnimatableClipEffects(
        chromaKey: AnimatableClipChromaKeySettings(
            enabled: true,
            tolerance: try followUpAnimatedRational(
                base: try RationalValue(numerator: 1, denominator: 10),
                changed: try RationalValue(numerator: 1, denominator: 5)
            ),
            edgeSoftness: .constant(try RationalValue(numerator: 1, denominator: 10)),
            spillSuppression: .constant(try RationalValue(numerator: 1, denominator: 5))
        ),
        lumaKey: AnimatableClipLumaKeySettings(
            enabled: true,
            lowThreshold: try followUpAnimatedRational(
                base: try RationalValue(numerator: 1, denominator: 10),
                changed: try RationalValue(numerator: 1, denominator: 5)
            ),
            highThreshold: .constant(try RationalValue(numerator: 9, denominator: 10)),
            softness: .constant(try RationalValue(numerator: 1, denominator: 10))
        ),
        colorCorrection: AnimatableClipColorCorrection(
            exposure: try followUpAnimatedRational(base: 0, changed: 1),
            saturation: .constant(try RationalValue(numerator: 3, denominator: 2))
        ),
        masks: [
            AnimatableClipMask.constant(
                try makeFollowUpRectangleMask(
                    id: try editUUID(seed * 1_000 + 910),
                    x: 0,
                    width: 5
                )
            )
        ]
    )
}

private func followUpAnimatedRational(
    base: RationalValue,
    changed: RationalValue
) throws -> Animatable<RationalValue> {
    try Animatable(
        base: base,
        keyframes: [
            Keyframe(time: try editTime(0), value: base, interpolation: .linear),
            Keyframe(time: try editTime(5), value: changed, interpolation: .hold)
        ]
    )
}

private func followUpAnimatedRational(
    base: Int64,
    changed: Int64
) throws -> Animatable<RationalValue> {
    try Animatable(
        base: RationalValue(base),
        keyframes: [
            Keyframe(time: try editTime(0), value: RationalValue(base), interpolation: .linear),
            Keyframe(time: try editTime(5), value: RationalValue(changed), interpolation: .hold)
        ]
    )
}

private func makeFollowUpRectangleMask(id: UUID, x: Int64, width: Int64) throws -> ClipMask {
    ClipMask(
        id: id,
        shape: .rectangle(
            ClipRectangleMask(
                x: RationalValue(x),
                y: .zero,
                width: RationalValue(width),
                height: RationalValue(10)
            )
        )
    )
}

private func makeFollowUpEllipseMask(id: UUID) throws -> ClipMask {
    ClipMask(
        id: id,
        shape: .ellipse(
            ClipEllipseMask(
                centerX: RationalValue(5),
                centerY: RationalValue(5),
                radiusX: RationalValue(4),
                radiusY: RationalValue(3)
            )
        )
    )
}
