// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-TXT-001 title model validation, Codable defaults, and empty-text policy.
final class TitleSourceModelTests: XCTestCase {
    func testFRTXT001DefaultStyleUsesHelveticaDeterministicFont() {
        XCTAssertEqual(TitleTextStyle.default.fontFamily, TitleSource.deterministicFontFamily)
        XCTAssertEqual(TitleSource.deterministicFontFamily, "Helvetica")
    }

    func testFRTXT001EmptyTextIsAllowed() {
        let box = TitleTextBox(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            text: "",
            origin: .zero,
            width: RationalValue(100),
            height: RationalValue(40)
        )
        let title = TitleSource(boxes: [box])
        XCTAssertNil(title.validate())
    }

    func testFRTXT001ValidationRejectsEmptyFontFamilyAndOutOfRangeValues() {
        let boxID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
        let emptyFamily = TitleSource(boxes: [
            TitleTextBox(
                id: boxID,
                text: "Hi",
                origin: .zero,
                width: RationalValue(100),
                height: RationalValue(40),
                style: TitleTextStyle(fontFamily: "   ")
            )
        ])
        XCTAssertEqual(emptyFamily.validate(), .emptyFontFamily)

        let hugeFont = TitleSource(boxes: [
            TitleTextBox(
                id: boxID,
                text: "Hi",
                origin: .zero,
                width: RationalValue(100),
                height: RationalValue(40),
                style: TitleTextStyle(fontSize: RationalValue(2_000))
            )
        ])
        XCTAssertEqual(
            hugeFont.validate(),
            .fontSizeOutOfRange(
                value: RationalValue(2_000),
                minimum: TitleSource.minimumFontSize,
                maximum: TitleSource.maximumFontSize
            )
        )

        let badTracking = TitleSource(boxes: [
            TitleTextBox(
                id: boxID,
                text: "Hi",
                origin: .zero,
                width: RationalValue(100),
                height: RationalValue(40),
                style: TitleTextStyle(tracking: RationalValue(-500))
            )
        ])
        XCTAssertEqual(
            badTracking.validate(),
            .trackingOutOfRange(
                value: RationalValue(-500),
                minimum: TitleSource.minimumTracking,
                maximum: TitleSource.maximumTracking
            )
        )

        let zeroSize = TitleSource(boxes: [
            TitleTextBox(
                id: boxID,
                text: "Hi",
                origin: .zero,
                width: RationalValue.zero,
                height: RationalValue(40)
            )
        ])
        XCTAssertEqual(
            zeroSize.validate(),
            .nonPositiveBoxSize(width: .zero, height: RationalValue(40))
        )
    }

    func testFRTXT001DuplicateBoxIDsAreRejected() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!
        let title = TitleSource(boxes: [
            TitleTextBox(
                id: id, text: "A", origin: .zero, width: RationalValue(10),
                height: RationalValue(10)
            ),
            TitleTextBox(
                id: id, text: "B", origin: .zero, width: RationalValue(10),
                height: RationalValue(10)
            ),
        ])
        XCTAssertEqual(title.validate(), .duplicateTextBoxID(id))
    }

    func testFRTXT001StyleAndBoxDecodeDefaultsForAbsentKeys() throws {
        let styleJSON = Data(#"{"fontSize":{"numerator":24,"denominator":1}}"#.utf8)
        let style = try JSONDecoder().decode(TitleTextStyle.self, from: styleJSON)
        XCTAssertEqual(style.fontFamily, "Helvetica")
        XCTAssertEqual(style.fontSize, RationalValue(24))
        XCTAssertEqual(style.fontWeight, .regular)
        XCTAssertEqual(style.tracking, .zero)
        XCTAssertEqual(style.alignment, .left)

        let boxJSON = Data(
            """
            {
              "id":"00000000-0000-0000-0000-00000000A004",
              "text":"Hello"
            }
            """.utf8
        )
        let box = try JSONDecoder().decode(TitleTextBox.self, from: boxJSON)
        XCTAssertEqual(box.text, "Hello")
        XCTAssertEqual(box.origin, .zero)
        XCTAssertEqual(box.width, RationalValue(100))
        XCTAssertEqual(box.style.fontFamily, "Helvetica")

        let titleJSON = Data(#"{}"#.utf8)
        let title = try JSONDecoder().decode(TitleSource.self, from: titleJSON)
        XCTAssertEqual(title.boxes, [])
    }

    func testFRTXT001TitleSourceRoundTripsThroughCodable() throws {
        let title = try sampleTitle()
        let decoded = try JSONDecoder().decode(
            TitleSource.self,
            from: JSONEncoder().encode(title)
        )
        XCTAssertEqual(decoded, title)
    }

    func testFRTXT001ClipSourceTitleRoundTripsOnClip() throws {
        let title = try sampleTitle()
        let clip = Clip(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A010")!,
            source: .title(title),
            sourceRange: try TimeRange(
                start: .zero,
                duration: RationalTime(value: 24, timescale: 24)
            ),
            timelineRange: try TimeRange(
                start: .zero,
                duration: RationalTime(value: 24, timescale: 24)
            ),
            kind: .video,
            name: "Title"
        )
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(decoded, clip)
        guard case .title(let decodedTitle) = decoded.source else {
            return XCTFail("expected title source")
        }
        XCTAssertEqual(decodedTitle, title)
    }

    private func sampleTitle() throws -> TitleSource {
        TitleSource(boxes: [
            TitleTextBox(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000A020")!,
                text: "Hello",
                origin: CanvasPoint(x: RationalValue(10), y: RationalValue(20)),
                width: RationalValue(200),
                height: RationalValue(60),
                style: TitleTextStyle(
                    fontFamily: "Helvetica",
                    fontSize: RationalValue(32),
                    fontWeight: .bold,
                    color: ClipRGBColor(red: .one, green: .zero, blue: .zero),
                    tracking: RationalValue(1),
                    leading: RationalValue(2),
                    alignment: .center
                )
            ),
            TitleTextBox(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000A021")!,
                text: "World",
                origin: CanvasPoint(x: RationalValue(10), y: RationalValue(90)),
                width: RationalValue(200),
                height: RationalValue(40)
            ),
        ])
    }
}
