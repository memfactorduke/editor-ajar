// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditClipTransformCommandTests: XCTestCase {
    func testFRXFORM001To005ClipTransformHasIdentityDefaults() throws {
        let fixture = try makeEditFixture(seed: 900)
        let clip = try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)

        XCTAssertEqual(clip.transform, .identity)
    }

    func testFRXFORM001To005SetClipTransformRoutesThroughUndoableHistory() throws {
        let fixture = try makeEditFixture(seed: 910)
        let transform = try makeNonIdentityClipTransform()
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            .setClipTransform(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                transform: transform
            )
        )
        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(editedClip.transform, transform)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRXFORM004InvalidOpacityReturnsTypedErrorProperty() throws {
        let fixture = try makeEditFixture(seed: 920)
        let opacities = [
            try RationalValue(numerator: -1, denominator: 10),
            try RationalValue(numerator: 11, denominator: 10),
            try RationalValue(numerator: 3, denominator: 2)
        ]

        for opacity in opacities {
            let transform = ClipTransform(opacity: opacity)

            XCTAssertThrowsError(
                try apply(
                    .setClipTransform(
                        sequenceID: fixture.sequenceID,
                        trackID: fixture.videoTrackID,
                        clipID: fixture.clipID,
                        transform: transform
                    ),
                    to: fixture.project
                )
            ) { error in
                XCTAssertEqual(
                    error as? EditReducerError,
                    .invalidEdit(
                        .invalidClipTransform(
                            clipID: fixture.clipID,
                            error: .opacityOutOfRange(opacity)
                        )
                    )
                )
            }
        }
    }

    func testFRXFORM005InvalidCropInsetsReturnTypedErrorsProperty() throws {
        let fixture = try makeEditFixture(seed: 930)
        let frame = fixture.project.settings.resolution
        let negativeCases: [(ClipCropEdge, ClipCropInsets)] = [
            (.left, ClipCropInsets(left: -1, top: 0, right: 0, bottom: 0)),
            (.top, ClipCropInsets(left: 0, top: -1, right: 0, bottom: 0)),
            (.right, ClipCropInsets(left: 0, top: 0, right: -1, bottom: 0)),
            (.bottom, ClipCropInsets(left: 0, top: 0, right: 0, bottom: -1))
        ]

        for (edge, crop) in negativeCases {
            try assertInvalidTransform(
                ClipTransform(crop: crop),
                in: fixture,
                expected: .negativeCropInset(edge: edge, value: -1)
            )
        }

        let overWidth = ClipCropInsets(left: Int64(frame.width), top: 0, right: 1, bottom: 0)
        let overHeight = ClipCropInsets(left: 0, top: Int64(frame.height), right: 0, bottom: 1)

        try assertInvalidTransform(
            ClipTransform(crop: overWidth),
            in: fixture,
            expected: .cropExceedsFrame(crop: overWidth, frame: frame)
        )
        try assertInvalidTransform(
            ClipTransform(crop: overHeight),
            in: fixture,
            expected: .cropExceedsFrame(crop: overHeight, frame: frame)
        )
    }

    func testFRXFORM001To005ProjectValidationRejectsInvalidStoredTransform() throws {
        let fixture = try makeEditFixture(seed: 940)
        let opacity = try RationalValue(numerator: 4, denominator: 3)
        let invalidClip = try makeEditClip(
            id: try editUUID(940_100),
            mediaID: fixture.mediaID,
            startFrame: 20,
            transform: ClipTransform(opacity: opacity)
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
                .invalidClipTransform(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: invalidClip.id,
                    error: .opacityOutOfRange(opacity)
                )
            )
        )
    }
}

private func assertInvalidTransform(
    _ transform: ClipTransform,
    in fixture: EditFixture,
    expected: ClipTransformValidationError,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertThrowsError(
        try apply(
            .setClipTransform(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                transform: transform
            ),
            to: fixture.project
        ),
        file: file,
        line: line
    ) { error in
        XCTAssertEqual(
            error as? EditReducerError,
            .invalidEdit(
                .invalidClipTransform(clipID: fixture.clipID, error: expected)
            ),
            file: file,
            line: line
        )
    }
}

func makeNonIdentityClipTransform() throws -> ClipTransform {
    ClipTransform(
        position: CanvasPoint(
            x: try RationalValue(numerator: 11, denominator: 2),
            y: RationalValue(-3)
        ),
        scale: ClipScale(
            x: try RationalValue(numerator: 3, denominator: 2),
            y: try RationalValue(numerator: 4, denominator: 5)
        ),
        anchorPoint: CanvasPoint(x: RationalValue(960), y: RationalValue(540)),
        rotation: ClipRotation(
            degrees: try RationalValue(numerator: 45, denominator: 1),
            revolutions: 2
        ),
        opacity: try RationalValue(numerator: 3, denominator: 4),
        blendMode: .overlay,
        crop: ClipCropInsets(left: 10, top: 20, right: 30, bottom: 40),
        flip: ClipFlip(horizontal: true, vertical: false)
    )
}
