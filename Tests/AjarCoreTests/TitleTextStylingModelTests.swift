// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-002 Codable defaults and typed validation-range coverage.
final class TitleTextStylingModelTests: XCTestCase {
    func testFRTXT002LegacyDefaultsDisableAdvancedStylingAndBumpSchemaMinor() {
        XCTAssertNil(TitleTextStyle.default.stroke)
        XCTAssertNil(TitleTextStyle.default.dropShadow)
        XCTAssertNil(TitleTextStyle.default.gradientFill)
        // Title styling claimed minor 4; later additive kinds advance past it (batch 2 = 5,
        // FR-FX-001 transitions = 6).
        XCTAssertGreaterThanOrEqual(AjarProjectCodec.currentSchemaMinor, 4)
        XCTAssertEqual(AjarProjectCodec.currentSchemaMinor, 6)
    }

    func testFRTXT002SparseNestedStylePayloadsDecodeStableDefaults() throws {
        let styleJSON = Data(
            #"{"stroke":{},"dropShadow":{},"gradientFill":{}}"#.utf8
        )
        let style = try JSONDecoder().decode(TitleTextStyle.self, from: styleJSON)
        XCTAssertEqual(style.stroke, TitleStrokeStyle())
        XCTAssertEqual(style.dropShadow, TitleDropShadowStyle())
        XCTAssertEqual(style.gradientFill, TitleLinearGradientFill())

        let boxJSON = Data(
            #"{"id":"00000000-0000-0000-0000-00000000A005","backgroundBox":{}}"#.utf8
        )
        let box = try JSONDecoder().decode(TitleTextBox.self, from: boxJSON)
        XCTAssertEqual(box.backgroundBox, TitleBackgroundBoxStyle())
        XCTAssertNil(TitleSource(boxes: [box]).validate())
    }

    func testFRTXT002ValidationRejectsStrokeWidth() throws {
        let invalid = try source(
            style: TitleTextStyle(
                stroke: TitleStrokeStyle(width: RationalValue(101))
            )
        )
        XCTAssertEqual(
            invalid.validate(),
            .strokeWidthOutOfRange(
                value: RationalValue(101),
                minimum: TitleSource.minimumStrokeWidth,
                maximum: TitleSource.maximumStrokeWidth
            )
        )
    }

    func testFRTXT002ValidationRejectsShadowOffsetAndBlur() throws {
        let badOffset = try source(
            style: TitleTextStyle(
                dropShadow: TitleDropShadowStyle(offsetY: RationalValue(1_001))
            )
        )
        XCTAssertEqual(
            badOffset.validate(),
            .dropShadowOffsetOutOfRange(
                axis: .y,
                value: RationalValue(1_001),
                minimum: TitleSource.minimumDropShadowOffset,
                maximum: TitleSource.maximumDropShadowOffset
            )
        )

        let badBlur = try source(
            style: TitleTextStyle(
                dropShadow: TitleDropShadowStyle(blurRadius: RationalValue(501))
            )
        )
        XCTAssertEqual(
            badBlur.validate(),
            .dropShadowBlurRadiusOutOfRange(
                value: RationalValue(501),
                minimum: .zero,
                maximum: TitleSource.maximumDropShadowBlurRadius
            )
        )
    }

    func testFRTXT002ValidationRejectsShadowOpacity() throws {
        let invalid = try source(
            style: TitleTextStyle(
                dropShadow: TitleDropShadowStyle(opacity: RationalValue(2))
            )
        )
        XCTAssertEqual(
            invalid.validate(),
            .styleOpacityOutOfRange(component: .dropShadow, value: RationalValue(2))
        )
    }

    func testFRTXT002ValidationRejectsBackgroundGeometry() throws {
        let badPadding = try source(
            backgroundBox: TitleBackgroundBoxStyle(padding: RationalValue(-1))
        )
        XCTAssertEqual(
            badPadding.validate(),
            .backgroundPaddingOutOfRange(
                value: RationalValue(-1),
                minimum: .zero,
                maximum: TitleSource.maximumBackgroundPadding
            )
        )

        let badRadius = try source(
            backgroundBox: TitleBackgroundBoxStyle(cornerRadius: RationalValue(501))
        )
        XCTAssertEqual(
            badRadius.validate(),
            .backgroundCornerRadiusOutOfRange(
                value: RationalValue(501),
                minimum: .zero,
                maximum: TitleSource.maximumBackgroundCornerRadius
            )
        )
    }

    func testFRTXT002ValidationRejectsBackgroundOpacity() throws {
        let invalid = try source(
            backgroundBox: TitleBackgroundBoxStyle(opacity: RationalValue(-1))
        )
        XCTAssertEqual(
            invalid.validate(),
            .styleOpacityOutOfRange(component: .backgroundBox, value: RationalValue(-1))
        )
    }

    func testFRTXT002ValidationRejectsGradientAngleAndColor() throws {
        let badAngle = try source(
            style: TitleTextStyle(
                gradientFill: TitleLinearGradientFill(angleDegrees: RationalValue(361))
            )
        )
        XCTAssertEqual(
            badAngle.validate(),
            .gradientAngleOutOfRange(
                value: RationalValue(361),
                minimum: TitleSource.minimumGradientAngle,
                maximum: TitleSource.maximumGradientAngle
            )
        )

        let badColor = try source(
            style: TitleTextStyle(
                gradientFill: TitleLinearGradientFill(
                    startColor: ClipRGBColor(red: RationalValue(2), green: .zero, blue: .zero)
                )
            )
        )
        XCTAssertEqual(
            badColor.validate(),
            .colorChannelOutOfRange(channel: .red, value: RationalValue(2))
        )
    }

    func testFRTXT002ValidationRejectsEveryNestedStyleColor() throws {
        let invalidColor = ClipRGBColor(red: RationalValue(2), green: .zero, blue: .zero)
        let expected = TitleSourceValidationError.colorChannelOutOfRange(
            channel: .red,
            value: RationalValue(2)
        )

        let badStroke = try source(
            style: TitleTextStyle(stroke: TitleStrokeStyle(color: invalidColor))
        )
        XCTAssertEqual(badStroke.validate(), expected)

        let badShadow = try source(
            style: TitleTextStyle(dropShadow: TitleDropShadowStyle(color: invalidColor))
        )
        XCTAssertEqual(badShadow.validate(), expected)

        let badBackground = try source(
            backgroundBox: TitleBackgroundBoxStyle(fillColor: invalidColor)
        )
        XCTAssertEqual(badBackground.validate(), expected)
    }

    private func source(
        style: TitleTextStyle = .default,
        backgroundBox: TitleBackgroundBoxStyle? = nil
    ) throws -> TitleSource {
        let box = TitleTextBox(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000A006")),
            text: "Hi",
            origin: .zero,
            width: RationalValue(100),
            height: RationalValue(40),
            style: style,
            backgroundBox: backgroundBox
        )
        return TitleSource(boxes: [box])
    }
}
