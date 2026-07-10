// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-002 batch-1 parameter validation plus all-kind identity and schema coverage.
final class ClipEffectLibraryFX002ValidationTests: XCTestCase {
    func testFRFX002ParameterValidationRejectsOutOfRangeValues() throws {
        let highAmount = try RationalValue(numerator: 3, denominator: 2)
        // swift-format-ignore
        let cases: [(ClipEffectDefinition, ClipEffectStackValidationError)] = try [
            (
                .gaussianBlur(ClipGaussianBlurParameters(radius: RationalValue(65))),
                .gaussianBlurRadiusOutOfRange(RationalValue(65))
            ),
            (
                .boxBlur(ClipBoxBlurParameters(radius: RationalValue(-1))),
                .boxBlurRadiusOutOfRange(RationalValue(-1))
            ),
            (
                .boxBlur(ClipBoxBlurParameters(radius: RationalValue(17))),
                .boxBlurRadiusOutOfRange(RationalValue(17))
            ),
            (
                .zoomBlur(ClipZoomBlurParameters(amount: highAmount)),
                .zoomBlurAmountOutOfRange(highAmount)
            ),
            (
                .zoomBlur(ClipZoomBlurParameters(amount: .zero, centerX: highAmount)),
                .zoomBlurCenterOutOfRange(axis: .x, value: highAmount)
            ),
            (
                .sharpen(ClipSharpenParameters(amount: highAmount)),
                .sharpenAmountOutOfRange(highAmount)
            ),
            (
                .sharpen(ClipSharpenParameters(amount: .one, radius: RationalValue(9))),
                .sharpenRadiusOutOfRange(RationalValue(9))
            ),
            (
                .glow(ClipGlowParameters(radius: RationalValue(65), amount: .one)),
                .glowRadiusOutOfRange(RationalValue(65))
            ),
            (
                .glow(ClipGlowParameters(radius: .one, amount: highAmount)),
                .glowAmountOutOfRange(highAmount)
            )
        ]

        for (definition, expected) in cases {
            let stack = ClipEffectStack(
                nodes: [ClipEffectNode(id: try editUUID(6_100), definition: definition)]
            )
            let errors = ClipEffectStackValidator.errors(for: stack)
            XCTAssertTrue(
                errors.contains(expected),
                "expected \(expected) in \(errors) for \(definition.kind.rawValue)"
            )
        }
    }

    func testFRFX002IdentityDefinitionsAndConstantAnimatable() {
        for kind in ClipEffectKind.allCases {
            let identity = ClipEffectDefinition.identity(for: kind)
            XCTAssertEqual(identity.kind, kind)
            let animatable = AnimatableClipEffectDefinition.constant(identity)
            XCTAssertEqual(animatable.kind, kind)
            XCTAssertEqual(animatable.baseDefinition, identity)
            XCTAssertEqual(animatable.value(at: .zero), identity)
        }
    }

    func testFRFX002SchemaMinorIsEightAfterCurves() {
        // 2 = FR-FX-002 batch 1; 3 = FR-COL-004 lut; 4 = FR-TXT-002 styling;
        // 5 = FR-FX-002 batch 2; 6 = FR-FX-001 video transitions (#183);
        // 7 = FR-TXT-004 title revealFraction / presets (#186);
        // 8 = FR-COL-002 curves (#189; renumbered after #186 claimed 7).
        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 8)
        XCTAssertGreaterThanOrEqual(AjarProjectCodec.currentSchemaMinor, 2)
        XCTAssertTrue(ClipEffectKind.allCases.contains(.gaussianBlur))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.boxBlur))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.zoomBlur))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.sharpen))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.glow))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.lut))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.vignette))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.mirror))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.mosaic))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.colorAdjust))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.posterize))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.invert))
        XCTAssertTrue(ClipEffectKind.allCases.contains(.curves))
        // placeholder + batch1 (5) + lut + batch2 (6) + curves = 14
        XCTAssertEqual(ClipEffectKind.allCases.count, 14)
    }

    func testFRFX002StaticAnimationParityCoversLibraryKinds() throws {
        let fixture = try makeEditFixture(seed: 6_130)
        let nodeID = try editUUID(6_130_100)
        let stack = ClipEffectStack(
            nodes: [
                ClipEffectNode(
                    id: nodeID,
                    definition: .boxBlur(ClipBoxBlurParameters(radius: RationalValue(3)))
                )
            ]
        )
        let good = try fx002Project(stack: stack, animation: .constant(stack), fixture: fixture)
        XCTAssertTrue(good.validate().isValid)

        let mismatched = AnimatableClipEffectStack(
            nodes: [
                AnimatableClipEffectNode(
                    id: nodeID,
                    definition: .boxBlur(
                        AnimatableClipBoxBlurSettings(radius: .constant(RationalValue(7)))
                    )
                )
            ]
        )
        let bad = try fx002Project(stack: stack, animation: mismatched, fixture: fixture)
        guard case .invalid(let errors) = bad.validate() else {
            return XCTFail("expected invalid project for static/animation parity mismatch")
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
