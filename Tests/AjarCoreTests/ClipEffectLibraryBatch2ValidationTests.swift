// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-002 batch-2 typed ranges, legacy-safe defaults, and keyframe validation.
final class ClipEffectLibraryBatch2ValidationTests: XCTestCase {
    func testFRFX002Batch2StaticParametersRejectEveryDocumentedOutOfRangeControl() throws {
        let cases = try invalidSpatialDefinitions() + invalidColorDefinitions()
        for (definition, expected) in cases {
            let stack = ClipEffectStack(
                nodes: [ClipEffectNode(id: try editUUID(6_300), definition: definition)]
            )
            let errors = ClipEffectStackValidator.errors(for: stack)
            XCTAssertTrue(
                errors.contains(expected),
                "expected \(expected) for \(definition.kind.rawValue), got \(errors)"
            )
        }
    }

    func testFRFX002Batch2AnimatableKeyframesUseTheSameTypedRanges() throws {
        let high = RationalValue(2)
        let cases: [(AnimatableClipEffectDefinition, ClipEffectStackValidationError)] = [
            (
                .vignette(
                    AnimatableClipVignetteSettings(amount: try invalidAnimation(value: high))
                ),
                .vignetteAmountOutOfRange(high)
            ),
            (
                .mosaic(
                    AnimatableClipMosaicSettings(cellSize: try invalidAnimation(value: .zero))
                ),
                .mosaicCellSizeOutOfRange(.zero)
            ),
            (
                .colorAdjust(
                    AnimatableClipColorAdjustSettings(tint: try invalidAnimation(value: high))
                ),
                .colorAdjustTintOutOfRange(high)
            ),
            (
                .posterize(
                    AnimatableClipPosterizeSettings(
                        levels: try invalidAnimation(value: .one, base: RationalValue(4))
                    )
                ),
                .posterizeLevelsOutOfRange(.one)
            )
        ]

        for (definition, expected) in cases {
            let node = AnimatableClipEffectNode(
                id: try editUUID(6_301),
                definition: definition
            )
            let errors = ClipEffectStackValidator.errors(
                for: AnimatableClipEffectStack(nodes: [node])
            )
            XCTAssertTrue(errors.contains(expected), "expected \(expected), got \(errors)")
        }
    }

    func testFRFX002Batch2MissingPayloadAndFieldsDecodeToTypedDefaults() throws {
        for kind in batch2Kinds {
            let missingPayload = Data(#"{"kind":"\#(kind.rawValue)"}"#.utf8)
            let emptyPayload = Data(#"{"kind":"\#(kind.rawValue)","parameters":{}}"#.utf8)
            let expected = ClipEffectDefinition.identity(for: kind)
            XCTAssertEqual(
                try JSONDecoder().decode(ClipEffectDefinition.self, from: missingPayload),
                expected
            )
            XCTAssertEqual(
                try JSONDecoder().decode(ClipEffectDefinition.self, from: emptyPayload),
                expected
            )

            let expectedAnimation = AnimatableClipEffectDefinition.identity(for: kind)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    AnimatableClipEffectDefinition.self,
                    from: missingPayload
                ),
                expectedAnimation
            )
            XCTAssertEqual(
                try JSONDecoder().decode(AnimatableClipEffectDefinition.self, from: emptyPayload),
                expectedAnimation
            )
        }
    }

    func testFRFX002MirrorRejectsUnknownAxisDuringTypedDecode() {
        let json = Data(
            #"{"kind":"mirror","parameters":{"axis":"diagonal"}}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(ClipEffectDefinition.self, from: json))
    }
}

private let batch2Kinds: [ClipEffectKind] = [
    .vignette, .mirror, .mosaic, .colorAdjust, .posterize, .invert
]

private typealias Batch2ValidationCase = (
    ClipEffectDefinition,
    ClipEffectStackValidationError
)

private func invalidSpatialDefinitions() throws -> [Batch2ValidationCase] {
    let high = try RationalValue(numerator: 3, denominator: 2)
    return [
        (
            .vignette(ClipVignetteParameters(amount: high)),
            .vignetteAmountOutOfRange(high)
        ),
        (
            .vignette(ClipVignetteParameters(radius: RationalValue(-1))),
            .vignetteRadiusOutOfRange(RationalValue(-1))
        ),
        (
            .vignette(ClipVignetteParameters(softness: high)),
            .vignetteSoftnessOutOfRange(high)
        ),
        (
            .mosaic(ClipMosaicParameters(cellSize: .zero)),
            .mosaicCellSizeOutOfRange(.zero)
        ),
        (
            .mosaic(ClipMosaicParameters(cellSize: RationalValue(257))),
            .mosaicCellSizeOutOfRange(RationalValue(257))
        )
    ]
}

private func invalidColorDefinitions() throws -> [Batch2ValidationCase] {
    let high = try RationalValue(numerator: 3, denominator: 2)
    return [
        (
            .colorAdjust(ClipColorAdjustParameters(brightness: RationalValue(-2))),
            .colorAdjustBrightnessOutOfRange(RationalValue(-2))
        ),
        (
            .colorAdjust(ClipColorAdjustParameters(contrast: RationalValue(5))),
            .colorAdjustContrastOutOfRange(RationalValue(5))
        ),
        (
            .colorAdjust(ClipColorAdjustParameters(saturation: RationalValue(-1))),
            .colorAdjustSaturationOutOfRange(RationalValue(-1))
        ),
        (
            .colorAdjust(ClipColorAdjustParameters(tint: high)),
            .colorAdjustTintOutOfRange(high)
        ),
        (
            .posterize(ClipPosterizeParameters(levels: .one)),
            .posterizeLevelsOutOfRange(.one)
        ),
        (
            .posterize(ClipPosterizeParameters(levels: RationalValue(257))),
            .posterizeLevelsOutOfRange(RationalValue(257))
        )
    ]
}

private func invalidAnimation(
    value: RationalValue,
    base: RationalValue = .one
) throws -> Animatable<RationalValue> {
    try Animatable(
        base: base,
        keyframes: [
            Keyframe(time: try editTime(2), value: value, interpolation: .linear)
        ]
    )
}
