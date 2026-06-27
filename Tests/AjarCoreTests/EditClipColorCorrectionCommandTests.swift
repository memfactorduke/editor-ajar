// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditClipColorCorrectionCommandTests: XCTestCase {
    func testFRCOL001ColorCorrectionRoutesThroughUndoableHistoryAndClear() throws {
        let fixture = try makeEditFixture(seed: 1_135)
        let correction = try makeColorCorrection(
            exposure: try RationalValue(numerator: 1, denominator: 2),
            saturation: try RationalValue(numerator: 3, denominator: 2)
        )
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            .setClipColorCorrection(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                correction: correction
            )
        )
        let cleared = try history.apply(
            .clearClipColorCorrection(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            )
        )
        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let clearedClip = try requiredClip(fixture.clipID, in: cleared, fixture: fixture)

        XCTAssertEqual(editedClip.effects.colorCorrection, correction)
        XCTAssertEqual(clearedClip.effects.colorCorrection, .identity)
        XCTAssertEqual(history.undo(), edited)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
        XCTAssertEqual(try history.redo(), cleared)
    }

    func testFRCOL001InvalidColorCorrectionSettingsReturnTypedErrors() throws {
        let fixture = try makeEditFixture(seed: 1_136)
        let highContrast = RationalValue(5)
        let zeroGamma = RationalValue.zero
        let lowTemperature = RationalValue(-2)
        let invalidCases: [(ClipColorCorrection, ClipEffectsValidationError)] = [
            (
                ClipColorCorrection(contrast: highContrast),
                .colorCorrectionParameterOutOfRange(
                    parameter: .contrast,
                    value: highContrast,
                    minimum: RationalValue(0),
                    maximum: RationalValue(4)
                )
            ),
            (
                ClipColorCorrection(
                    gamma: ClipColorChannels(red: zeroGamma, green: .one, blue: .one)
                ),
                .colorCorrectionChannelOutOfRange(
                    group: .gamma,
                    channel: .red,
                    value: zeroGamma,
                    minimum: RationalValue.approximating(0.01),
                    maximum: RationalValue(4)
                )
            ),
            (
                ClipColorCorrection(temperature: lowTemperature),
                .colorCorrectionParameterOutOfRange(
                    parameter: .temperature,
                    value: lowTemperature,
                    minimum: RationalValue(-1),
                    maximum: RationalValue(1)
                )
            )
        ]

        for (correction, expectedError) in invalidCases {
            try assertColorCorrectionThrows(
                correction,
                expectedError: expectedError,
                fixture: fixture
            )
        }
    }

    func testFRCOL001ProjectValidationRejectsInvalidStoredColorCorrection() throws {
        let fixture = try makeEditFixture(seed: 1_137)
        let invalidExposure = RationalValue(11)
        let invalidClip = try makeEditClip(
            id: try editUUID(1_137_100),
            mediaID: fixture.mediaID,
            startFrame: 20,
            effects: ClipEffects(
                colorCorrection: ClipColorCorrection(exposure: invalidExposure)
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
                    error: .colorCorrectionParameterOutOfRange(
                        parameter: .exposure,
                        value: invalidExposure,
                        minimum: RationalValue(-10),
                        maximum: RationalValue(10)
                    )
                )
            )
        )
    }

    private func assertColorCorrectionThrows(
        _ correction: ClipColorCorrection,
        expectedError: ClipEffectsValidationError,
        fixture: EditFixture
    ) throws {
        XCTAssertThrowsError(
            try apply(
                .setClipColorCorrection(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    correction: correction
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

private func makeColorCorrection(
    exposure: RationalValue = .zero,
    saturation: RationalValue = .one
) throws -> ClipColorCorrection {
    ClipColorCorrection(
        lift: ClipColorChannels(
            red: try RationalValue(numerator: 1, denominator: 10),
            green: .zero,
            blue: try RationalValue(numerator: -1, denominator: 10)
        ),
        gamma: ClipColorChannels(
            red: .one,
            green: try RationalValue(numerator: 11, denominator: 10),
            blue: .one
        ),
        gain: ClipColorChannels(red: .one, green: .one, blue: .one),
        exposure: exposure,
        saturation: saturation,
        temperature: try RationalValue(numerator: 1, denominator: 5),
        tint: try RationalValue(numerator: -1, denominator: 5),
        vibrance: try RationalValue(numerator: 1, denominator: 4)
    )
}
