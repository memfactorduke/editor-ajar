// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditClipLumaKeyCommandTests: XCTestCase {
    func testFRCOMP005LumaKeyRoutesThroughUndoableHistoryAndClear() throws {
        let fixture = try makeEditFixture(seed: 1_167)
        let settings = try makeLumaKeySettings(invert: true)
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            .setClipLumaKey(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                settings: settings
            )
        )
        let cleared = try history.apply(
            .clearClipLumaKey(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            )
        )
        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let clearedClip = try requiredClip(fixture.clipID, in: cleared, fixture: fixture)

        XCTAssertEqual(editedClip.effects.lumaKey, settings)
        XCTAssertEqual(clearedClip.effects.lumaKey, .disabled)
        XCTAssertEqual(history.undo(), edited)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
        XCTAssertEqual(try history.redo(), cleared)
    }

    func testFRCOMP005InvalidLumaKeySettingsReturnTypedErrors() throws {
        let fixture = try makeEditFixture(seed: 1_168)
        let lowNegative = RationalValue(-1)
        let highTooLarge = RationalValue(2)
        let softnessTooLarge = RationalValue(2)
        let invertedOrderLow = try RationalValue(numerator: 3, denominator: 4)
        let invertedOrderHigh = try RationalValue(numerator: 1, denominator: 4)
        let invalidCases: [(ClipLumaKeySettings, ClipEffectsValidationError)] = [
            (
                try makeLumaKeySettings(lowThreshold: lowNegative),
                .lumaKeyParameterOutOfRange(
                    parameter: .lowThreshold,
                    value: lowNegative,
                    minimum: .zero,
                    maximum: .one
                )
            ),
            (
                try makeLumaKeySettings(highThreshold: highTooLarge),
                .lumaKeyParameterOutOfRange(
                    parameter: .highThreshold,
                    value: highTooLarge,
                    minimum: .zero,
                    maximum: .one
                )
            ),
            (
                try makeLumaKeySettings(softness: softnessTooLarge),
                .lumaKeyParameterOutOfRange(
                    parameter: .softness,
                    value: softnessTooLarge,
                    minimum: .zero,
                    maximum: .one
                )
            ),
            (
                try makeLumaKeySettings(
                    lowThreshold: invertedOrderLow,
                    highThreshold: invertedOrderHigh
                ),
                .lumaKeyThresholdOrderInvalid(
                    lowThreshold: invertedOrderLow,
                    highThreshold: invertedOrderHigh
                )
            )
        ]

        for (settings, expectedError) in invalidCases {
            try assertLumaKeyThrows(settings, expectedError: expectedError, fixture: fixture)
        }
    }

    func testFRCOMP005ProjectValidationRejectsInvalidStoredLumaKey() throws {
        let fixture = try makeEditFixture(seed: 1_169)
        let invalidHighThreshold = RationalValue(2)
        let invalidClip = try makeEditClip(
            id: try editUUID(1_169_100),
            mediaID: fixture.mediaID,
            startFrame: 20,
            effects: ClipEffects(
                lumaKey: try makeLumaKeySettings(highThreshold: invalidHighThreshold)
            )
        )
        let project = try replacingVideoItems([.clip(invalidClip)], in: fixture)

        guard case .invalid(let errors) = project.validate() else {
            XCTFail("Expected invalid project")
            return
        }

        XCTAssertTrue(
            errors.contains(
                .invalidClipEffects(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: invalidClip.id,
                    error: .lumaKeyParameterOutOfRange(
                        parameter: .highThreshold,
                        value: invalidHighThreshold,
                        minimum: .zero,
                        maximum: .one
                    )
                )
            )
        )
    }

    private func assertLumaKeyThrows(
        _ settings: ClipLumaKeySettings,
        expectedError: ClipEffectsValidationError,
        fixture: EditFixture
    ) throws {
        XCTAssertThrowsError(
            try apply(
                .setClipLumaKey(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    settings: settings
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.invalidClipEffects(clipID: fixture.clipID, error: expectedError))
            )
        }
    }
}

private func makeLumaKeySettings(
    lowThreshold: RationalValue? = nil,
    highThreshold: RationalValue? = nil,
    softness: RationalValue? = nil,
    invert: Bool = false
) throws -> ClipLumaKeySettings {
    let defaultLowThreshold = try RationalValue(numerator: 1, denominator: 4)
    let defaultHighThreshold = try RationalValue(numerator: 3, denominator: 4)
    let defaultSoftness = try RationalValue(numerator: 1, denominator: 10)

    return ClipLumaKeySettings(
        enabled: true,
        lowThreshold: lowThreshold ?? defaultLowThreshold,
        highThreshold: highThreshold ?? defaultHighThreshold,
        softness: softness ?? defaultSoftness,
        invert: invert
    )
}
