// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

/// FR-FX-002 / NFR-QUAL-001: scalar extraction used by `applySharpen` must yield the fixture
/// floats (amount 0.5, radius 1.0). A wrong doubleValue would make the GPU early-out identity.
final class ClipSharpenParameterScalarTests: XCTestCase {
    func testFRFX002NFRQUAL001SharpenFixtureScalarsExtractAsHalfAndOne() throws {
        let parameters = ClipSharpenParameters(
            amount: try RationalValue(numerator: 1, denominator: 2),
            radius: .one
        )
        // Exact conversion `applySharpen` performs before encodeSharpen.
        let amount = Float(parameters.amount.doubleValue)
        let radius = Float(parameters.radius.doubleValue)
        XCTAssertEqual(amount, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(radius, 1.0, accuracy: 0.000_001)
        XCTAssertGreaterThan(amount, 0.001, "applySharpen guard would skip encode")
        XCTAssertGreaterThan(radius, 0.001, "shader early-out would identity")
    }

    func testFRFX002NFRQUAL001SharpenAnimatableEvaluationYieldsSameScalars() throws {
        let staticParameters = ClipSharpenParameters(
            amount: try RationalValue(numerator: 1, denominator: 2),
            radius: .one
        )
        let animated = AnimatableClipSharpenSettings.constant(staticParameters)
        let evaluated = animated.value(at: .zero)
        XCTAssertEqual(evaluated, staticParameters)
        XCTAssertEqual(Float(evaluated.amount.doubleValue), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(Float(evaluated.radius.doubleValue), 1.0, accuracy: 0.000_001)

        // Stack animation path used by RenderGraphBuilder (constant → value(at:)).
        let nodeID = try UUID.fromFidelity(8_001)
        let stack = ClipEffectStack(
            nodes: [
                ClipEffectNode(
                    id: nodeID,
                    definition: .sharpen(staticParameters)
                )
            ]
        )
        let evaluatedStack = AnimatableClipEffectStack.constant(stack).value(at: .zero)
        XCTAssertEqual(evaluatedStack.nodes.count, 1)
        guard case .sharpen(let parameters) = evaluatedStack.nodes[0].definition else {
            return XCTFail("expected sharpen definition after animation evaluation")
        }
        XCTAssertEqual(parameters, staticParameters)
        XCTAssertEqual(Float(parameters.amount.doubleValue), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(Float(parameters.radius.doubleValue), 1.0, accuracy: 0.000_001)
    }

    func testFRFX002NFRQUAL001DefinitionConstantThenValuePreservesSharpenScalars() throws {
        let definition = ClipEffectDefinition.sharpen(
            ClipSharpenParameters(
                amount: try RationalValue(numerator: 1, denominator: 2),
                radius: RationalValue(1)
            )
        )
        let resolved = AnimatableClipEffectDefinition.constant(definition).value(at: .zero)
        XCTAssertEqual(resolved, definition)
        guard case .sharpen(let parameters) = resolved else {
            return XCTFail("expected sharpen")
        }
        XCTAssertEqual(Float(parameters.amount.doubleValue), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(Float(parameters.radius.doubleValue), 1.0, accuracy: 0.000_001)
    }
}

private extension UUID {
    static func fromFidelity(_ value: Int) throws -> UUID {
        let string = String(format: "00000000-0000-0000-0000-%012d", value)
        guard let uuid = UUID(uuidString: string) else {
            throw NSError(domain: "ClipSharpenParameterScalarTests", code: 1)
        }
        return uuid
    }
}
