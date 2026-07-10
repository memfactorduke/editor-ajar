// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore
@testable import AjarRender

/// FR-TXT-004 typewriter revealFraction rasterization (CPU path; no Metal required).
final class TitleRevealRasterizerTests: XCTestCase {
    func testFRTXT004RevealedTextUsesGraphemeClusters() {
        XCTAssertEqual(TitleTextRasterizer.revealedText("HELLO", fraction: .zero), "")
        XCTAssertEqual(TitleTextRasterizer.revealedText("HELLO", fraction: .one), "HELLO")
        let half = (try? RationalValue(numerator: 1, denominator: 2)) ?? .zero
        XCTAssertEqual(TitleTextRasterizer.revealedText("HELLO", fraction: half), "HE")
        // Family emoji is one extended grapheme cluster.
        let family = "👨‍👩‍👧‍👦XY"
        XCTAssertEqual(TitleTextRasterizer.revealedText(family, fraction: half), "👨‍👩‍👧‍👦")
    }

    func testFRTXT004RasterizePixelsHonorsPartialReveal() throws {
        let boxID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000D186"))
        let full = TitleSource(
            boxes: [
                TitleTextBox(
                    id: boxID,
                    text: "TYPEWRITER",
                    origin: CanvasPoint(x: RationalValue(4), y: RationalValue(4)),
                    width: RationalValue(152),
                    height: RationalValue(40),
                    style: TitleTextStyle(
                        fontFamily: TitleSource.deterministicFontFamily,
                        fontSize: RationalValue(24),
                        fontWeight: .bold,
                        color: ClipRGBColor(red: .one, green: .one, blue: .one),
                        alignment: .left
                    )
                )
            ],
            revealFraction: .constant(.one)
        )
        let half = TitleSource(
            boxes: full.boxes,
            revealFraction: .constant(try RationalValue(numerator: 1, denominator: 2))
        )
        let none = TitleSource(
            boxes: full.boxes,
            revealFraction: .constant(.zero)
        )
        let width = 160
        let height = 48
        let fullPixels = try TitleTextRasterizer.rasterizePixels(
            title: full,
            width: width,
            height: height
        ).pixels
        let halfPixels = try TitleTextRasterizer.rasterizePixels(
            title: half,
            width: width,
            height: height
        ).pixels
        let nonePixels = try TitleTextRasterizer.rasterizePixels(
            title: none,
            width: width,
            height: height
        ).pixels
        XCTAssertNotEqual(fullPixels, halfPixels)
        XCTAssertNotEqual(halfPixels, nonePixels)
        // Zero reveal is fully transparent.
        XCTAssertTrue(nonePixels.allSatisfy { $0 == 0 })
        // Full reveal has non-zero coverage.
        XCTAssertTrue(fullPixels.contains { $0 != 0 })
    }
}
