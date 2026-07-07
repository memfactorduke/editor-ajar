// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-SPD-002 edit-layer coverage: retime conflicts surface as typed errors instead of
/// silently composing, and decompose rejects curves it cannot rebase exactly.
final class ClipTimeRemapEditTests: XCTestCase {
    func testFRSPD002SetClipSpeedOnRemappedClipFailsWithTypedConflict() throws {
        let fixture = try makeEditFixture(seed: 4_370)
        let remapClip = try makeRemapClip(
            clipSeed: 4_370_005,
            curve: try rampCurve(),
            sourceDurationFrames: 36,
            mediaID: fixture.mediaID
        )
        let remapProject = try replacingVideoItems([.clip(remapClip)], in: fixture)

        XCTAssertThrowsError(
            try apply(
                .setClipSpeed(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: remapClip.id,
                    speed: RationalValue(2)
                ),
                to: remapProject
            )
        ) { error in
            guard case .validationFailed(let errors)? = error as? EditReducerError else {
                return XCTFail("Expected validationFailed, got \(error)")
            }
            XCTAssertTrue(
                errors.contains { validationError in
                    if case .invalidClipTimeRemap(_, _, remapClip.id, let remapError) =
                        validationError,
                        case .conflictingRetime = remapError {
                        return true
                    }
                    return false
                },
                "expected conflictingRetime in \(errors)"
            )
        }
    }

    func testFRSPD002DecomposeRejectsCompoundClipWithTimeRemap() throws {
        let curve = try rampCurve()
        let compoundClip = Clip(
            id: try editUUID(4_371),
            source: .sequence(id: try editUUID(4_372)),
            sourceRange: try editRange(startFrame: 0, durationFrames: 36),
            timelineRange: try TimeRange(start: editTime(0), duration: curve.duration),
            kind: .video,
            name: "FR-SPD-002 compound clip",
            timeRemap: curve
        )

        XCTAssertThrowsError(
            try EditReducer.validateDecomposableCompoundAttributes(compoundClip)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .compoundDecomposeUnsupportedAttribute(
                        clipID: compoundClip.id,
                        attribute: .timeRemap
                    )
                )
            )
        }
    }

    func testFRSPD002DecomposeRejectsNestedClipWithTimeRemap() throws {
        let compoundClip = Clip(
            id: try editUUID(4_373),
            source: .sequence(id: try editUUID(4_374)),
            sourceRange: try editRange(startFrame: 0, durationFrames: 24),
            timelineRange: try editRange(startFrame: 0, durationFrames: 24),
            kind: .video,
            name: "FR-SPD-002 compound host"
        )
        let nestedClip = try makeRemapClip(
            clipSeed: 4_375,
            curve: try rampCurve(),
            sourceDurationFrames: 36
        )
        let nestedTrack = Track(
            id: try editUUID(4_376),
            kind: .video,
            items: [.clip(nestedClip)]
        )

        XCTAssertThrowsError(
            try EditReducer.decomposedClips(from: nestedTrack, compoundClip: compoundClip)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .compoundDecomposeUnsupportedAttribute(
                        clipID: nestedClip.id,
                        attribute: .timeRemap
                    )
                )
            )
        }
    }
}
