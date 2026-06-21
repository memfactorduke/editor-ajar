// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditClipEffectsCommandTests: XCTestCase {
    func testFRCOMP001ChromaKeySettingsHaveDisabledDefaults() throws {
        let fixture = try makeEditFixture(seed: 1_100)
        let clip = try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)

        XCTAssertEqual(clip.effects, .none)
        XCTAssertEqual(clip.effects.chromaKey, .disabled)
    }

    func testFRCOMP001SetClipChromaKeyRoutesThroughUndoableHistory() throws {
        let fixture = try makeEditFixture(seed: 1_110)
        let settings = try makeChromaKeySettings()
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            .setClipChromaKey(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                settings: settings
            )
        )
        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(editedClip.effects.chromaKey, settings)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRCOMP001InvalidChromaKeySettingsReturnTypedErrors() throws {
        let fixture = try makeEditFixture(seed: 1_120)
        let lowTolerance = try RationalValue(numerator: -1, denominator: 10)
        let highSoftness = try RationalValue(numerator: 11, denominator: 10)
        let highSpill = try RationalValue(numerator: 3, denominator: 2)
        let highRed = try RationalValue(numerator: 2, denominator: 1)
        let invalidCases: [(ClipChromaKeySettings, ClipEffectsValidationError)] = [
            (
                try makeChromaKeySettings(tolerance: lowTolerance),
                .chromaKeyToleranceOutOfRange(lowTolerance)
            ),
            (
                try makeChromaKeySettings(edgeSoftness: highSoftness),
                .chromaKeyEdgeSoftnessOutOfRange(highSoftness)
            ),
            (
                try makeChromaKeySettings(spillSuppression: highSpill),
                .chromaKeySpillSuppressionOutOfRange(highSpill)
            ),
            (
                try makeChromaKeySettings(
                    keyColor: ClipRGBColor(red: highRed, green: .one, blue: .zero)
                ),
                .colorChannelOutOfRange(channel: .red, value: highRed)
            )
        ]

        for (settings, expectedError) in invalidCases {
            XCTAssertThrowsError(
                try apply(
                    .setClipChromaKey(
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
                    .invalidEdit(
                        .invalidClipEffects(clipID: fixture.clipID, error: expectedError)
                    )
                )
            }
        }
    }

    func testFRCOMP001ProjectValidationRejectsInvalidStoredChromaKey() throws {
        let fixture = try makeEditFixture(seed: 1_130)
        let highTolerance = try RationalValue(numerator: 5, denominator: 4)
        let invalidClip = try makeEditClip(
            id: try editUUID(1_130_100),
            mediaID: fixture.mediaID,
            startFrame: 20,
            effects: ClipEffects(
                chromaKey: try makeChromaKeySettings(tolerance: highTolerance)
            )
        )
        let project = try replacingVideoItems(
            [.clip(invalidClip)],
            in: fixture
        )

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
                    error: .chromaKeyToleranceOutOfRange(highTolerance)
                )
            )
        )
    }
}

private func makeChromaKeySettings(
    keyColor: ClipRGBColor = .green,
    tolerance: RationalValue? = nil,
    edgeSoftness: RationalValue? = nil,
    spillSuppression: RationalValue? = nil
) throws -> ClipChromaKeySettings {
    let resolvedTolerance = try tolerance ?? RationalValue(numerator: 1, denominator: 4)
    let resolvedEdgeSoftness = try edgeSoftness ?? RationalValue(numerator: 1, denominator: 10)
    let resolvedSpillSuppression = try spillSuppression
        ?? RationalValue(numerator: 1, denominator: 2)

    return ClipChromaKeySettings(
        enabled: true,
        keyColor: keyColor,
        tolerance: resolvedTolerance,
        edgeSoftness: resolvedEdgeSoftness,
        spillSuppression: resolvedSpillSuppression
    )
}
