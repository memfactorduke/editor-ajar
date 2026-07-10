// SPDX-License-Identifier: GPL-3.0-or-later

import AjarRender
import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-002 CPU-pixel checks. Golden fixtures remain the cross-machine visual contract.
final class TitleTextStylingRasterizerTests: XCTestCase {
    func testFRTXT002StrokeExpandsRenderedGlyphPixels() throws {
        let base = try pixels(style: testStyle())
        let stroked = try pixels(
            style: testStyle(
                stroke: TitleStrokeStyle(
                    width: RationalValue(4),
                    color: black,
                    join: .round
                )
            )
        )

        XCTAssertGreaterThan(alphaPixelCount(stroked), alphaPixelCount(base))
        XCTAssertTrue(
            hasPixel(stroked) { blue, green, red, alpha in
                alpha > 128 && blue < 100 && green < 100 && red < 100
            }
        )
    }

    func testFRTXT002DropShadowAddsOffsetBlurPixels() throws {
        let base = try pixels(style: testStyle())
        let shadowed = try pixels(
            style: testStyle(
                dropShadow: TitleDropShadowStyle(
                    offsetX: RationalValue(6),
                    offsetY: RationalValue(5),
                    blurRadius: RationalValue(3),
                    color: black,
                    opacity: .one
                )
            )
        )

        XCTAssertGreaterThan(alphaPixelCount(shadowed), alphaPixelCount(base))
        XCTAssertNotEqual(alphaBounds(shadowed), alphaBounds(base))
    }

    func testFRTXT002BackgroundBoxFillsPaddedRunBounds() throws {
        let base = try pixels(style: testStyle())
        let boxed = try pixels(
            style: testStyle(),
            backgroundBox: TitleBackgroundBoxStyle(
                padding: RationalValue(6),
                cornerRadius: RationalValue(5),
                fillColor: ClipRGBColor(red: .zero, green: .zero, blue: .one),
                opacity: .one
            )
        )

        XCTAssertGreaterThan(alphaPixelCount(boxed), alphaPixelCount(base))
        XCTAssertTrue(
            hasPixel(boxed) { blue, green, red, alpha in
                alpha > 200 && Int(blue) > Int(green) + 100 && Int(blue) > Int(red) + 100
            })
    }

    func testFRTXT002LinearGradientClipsBothEndpointColorsToGlyphs() throws {
        let gradient = try pixels(
            style: testStyle(
                gradientFill: TitleLinearGradientFill(
                    startColor: ClipRGBColor(red: .one, green: .zero, blue: .zero),
                    endColor: ClipRGBColor(red: .zero, green: .zero, blue: .one),
                    angleDegrees: .zero
                )
            )
        )

        XCTAssertTrue(
            hasPixel(gradient) { blue, _, red, alpha in
                alpha > 128 && Int(red) > Int(blue) + 24
            })
        XCTAssertTrue(
            hasPixel(gradient) { blue, _, red, alpha in
                alpha > 128 && Int(blue) > Int(red) + 24
            })
    }

    func testFRTXT002CombinedStylingRasterizationIsDeterministic() throws {
        let style = testStyle(
            stroke: TitleStrokeStyle(width: RationalValue(2), color: black, join: .bevel),
            dropShadow: TitleDropShadowStyle(
                offsetX: RationalValue(4),
                offsetY: RationalValue(3),
                blurRadius: RationalValue(2),
                color: black,
                opacity: .one
            ),
            gradientFill: TitleLinearGradientFill(
                startColor: ClipRGBColor(red: .one, green: .one, blue: .zero),
                endColor: ClipRGBColor(red: .one, green: .zero, blue: .zero),
                angleDegrees: RationalValue(30)
            )
        )
        let background = TitleBackgroundBoxStyle(
            padding: RationalValue(5),
            cornerRadius: RationalValue(4),
            fillColor: ClipRGBColor(red: .zero, green: .zero, blue: .one),
            opacity: .one
        )

        let first = try pixels(style: style, backgroundBox: background)
        let second = try pixels(style: style, backgroundBox: background)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(alphaPixelCount(first), 0)
    }

    func testFRTXT002ColorEmojiRetainsNativePixelsUnderPathStyling() throws {
        let plain = try pixels(text: "🎬", style: testStyle())
        let styled = try pixels(
            text: "🎬",
            style: testStyle(
                stroke: TitleStrokeStyle(width: RationalValue(4), color: black),
                gradientFill: TitleLinearGradientFill(
                    startColor: ClipRGBColor(red: .one, green: .zero, blue: .zero),
                    endColor: ClipRGBColor(red: .zero, green: .zero, blue: .one)
                )
            )
        )

        XCTAssertEqual(styled, plain)
    }

    private let black = ClipRGBColor(red: .zero, green: .zero, blue: .zero)

    private func testStyle(
        stroke: TitleStrokeStyle? = nil,
        dropShadow: TitleDropShadowStyle? = nil,
        gradientFill: TitleLinearGradientFill? = nil
    ) -> TitleTextStyle {
        TitleTextStyle(
            fontFamily: TitleSource.deterministicFontFamily,
            fontSize: RationalValue(30),
            fontWeight: .bold,
            color: ClipRGBColor(red: .one, green: .one, blue: .one),
            alignment: .left,
            stroke: stroke,
            dropShadow: dropShadow,
            gradientFill: gradientFill
        )
    }

    private func pixels(
        text: String = "STYLE",
        style: TitleTextStyle,
        backgroundBox: TitleBackgroundBoxStyle? = nil
    ) throws -> [UInt8] {
        let title = TitleSource(boxes: [
            TitleTextBox(
                id: try XCTUnwrap(
                    UUID(uuidString: "00000000-0000-0000-0000-000000009200")
                ),
                text: text,
                origin: CanvasPoint(x: RationalValue(12), y: RationalValue(8)),
                width: RationalValue(136),
                height: RationalValue(48),
                style: style,
                backgroundBox: backgroundBox
            )
        ])
        return try TitleTextRasterizer.rasterizePixels(
            title: title,
            width: 160,
            height: 64
        ).pixels
    }

    private func alphaPixelCount(_ pixels: [UInt8]) -> Int {
        stride(from: 3, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            if pixels[index] > 0 {
                count += 1
            }
        }
    }

    private func alphaBounds(_ pixels: [UInt8]) -> CGRect? {
        var bounds: CGRect?
        for pixelIndex in 0..<(pixels.count / 4) where pixels[pixelIndex * 4 + 3] > 0 {
            let point = CGRect(
                x: pixelIndex % 160,
                y: pixelIndex / 160,
                width: 1,
                height: 1
            )
            bounds = bounds.map { $0.union(point) } ?? point
        }
        return bounds
    }

    private func hasPixel(
        _ pixels: [UInt8],
        matching predicate: (_ blue: UInt8, _ green: UInt8, _ red: UInt8, _ alpha: UInt8) -> Bool
    ) -> Bool {
        for index in stride(from: 0, to: pixels.count, by: 4)
        where predicate(pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3]) {
            return true
        }
        return false
    }
}
