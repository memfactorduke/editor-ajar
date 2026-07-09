// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarRender

/// Metal-free lock: MSL struct text and Swift pack order share `MetalEffectUniformLayout`.
final class MetalEffectUniformLayoutTests: XCTestCase {
    func testFRFX002UniformLayoutsMSLFieldOrderMatchesPackOrder() {
        for layout in MetalEffectUniformLayout.all {
            let mslNames = mslFieldNames(in: layout.mslStructDeclaration)
            XCTAssertEqual(
                mslNames,
                layout.fieldNamesInPackOrder,
                "\(layout.mslTypeName): MSL declaration field order must match pack order"
            )
        }
    }

    func testFRFX002ShaderSourceEmbedsGeneratedUniformStructsOnly() {
        let source = MetalClipEffectStackShaders.source
        for layout in MetalEffectUniformLayout.all {
            // Exact generated declaration must appear (single source of truth).
            XCTAssertTrue(
                source.contains(layout.mslStructDeclaration),
                "shader must embed generated \(layout.mslTypeName)"
            )
            // No second hand-written copy with a different body.
            let marker = "struct \(layout.mslTypeName)"
            let occurrences = source.components(separatedBy: marker).count - 1
            XCTAssertEqual(occurrences, 1, "\(layout.mslTypeName) must appear once")
        }
    }

    func testFRFX002SharpenPackWritesAmountThenRadiusPx() {
        let bytes = MetalEffectUniformLayout.packSharpen(amount: 0.5, radiusPx: 1.0)
        XCTAssertEqual(bytes.count, MetalEffectUniformLayout.sharpen.byteCount)
        XCTAssertEqual(MetalEffectUniformLayout.sharpen.fieldNamesInPackOrder, [
            "amount",
            "radiusPx",
            "padding0",
            "padding1"
        ])
        let amount = readFloat(bytes, at: MetalEffectUniformLayout.sharpen.fieldByteOffsets[0])
        let radius = readFloat(bytes, at: MetalEffectUniformLayout.sharpen.fieldByteOffsets[1])
        XCTAssertEqual(amount, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(radius, 1.0, accuracy: 0.000_1)
    }

    func testFRFX002AllLayoutsHaveStableNonZeroStride() {
        for layout in MetalEffectUniformLayout.all {
            XCTAssertGreaterThan(layout.byteCount, 0, layout.mslTypeName)
            XCTAssertEqual(layout.fieldByteOffsets.count, layout.fields.count)
        }
        XCTAssertEqual(MetalEffectUniformLayout.all.count, 5)
    }

    // MARK: - Helpers

    /// Parses `float` / `float2` / `float3` / `float4` member names from generated MSL, in order.
    private func mslFieldNames(in declaration: String) -> [String] {
        let pattern = #"\b(?:float4|float3|float2|float)\s+(\w+)\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(declaration.startIndex..., in: declaration)
        return regex.matches(in: declaration, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                let nameRange = Range(match.range(at: 1), in: declaration)
            else {
                return nil
            }
            return String(declaration[nameRange])
        }
    }

    private func readFloat(_ bytes: [UInt8], at offset: Int) -> Float {
        precondition(offset + 4 <= bytes.count)
        return bytes.withUnsafeBytes { raw in
            raw.load(fromByteOffset: offset, as: Float.self)
        }
    }
}
