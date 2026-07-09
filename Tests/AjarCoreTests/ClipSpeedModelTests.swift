// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class ClipSpeedModelTests: XCTestCase {
    func testFRSPD001ClipSpeedDefaultsToNormalAndMapsSourceTime() throws {
        let fixture = try makeEditFixture(seed: 4_200)
        let clip = try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)

        XCTAssertEqual(clip.speed, .one)
        XCTAssertFalse(clip.reverse)
        XCTAssertFalse(clip.freezeFrame)
        XCTAssertEqual(try clip.sourceTime(at: try editTime(3)), try editTime(3))
    }

    func testFRSPD001TimelineDurationIsSourceDurationDividedBySpeed() throws {
        let sourceDuration = try editTime(24)
        let doubleSpeed = RationalValue(2)
        let halfSpeed = try RationalValue(numerator: 1, denominator: 2)

        XCTAssertEqual(
            try Clip.timelineDuration(forSourceDuration: sourceDuration, speed: doubleSpeed),
            try editTime(12)
        )
        XCTAssertEqual(
            try Clip.timelineDuration(forSourceDuration: sourceDuration, speed: halfSpeed),
            try editTime(48)
        )
    }

    func testFRSPD001SourceTimeMappingUsesConstantSpeed() throws {
        let mediaID = try editUUID(4_210_001)
        let clip = try makeEditClip(
            id: try editUUID(4_210_002),
            mediaID: mediaID,
            startFrame: 10,
            durationFrames: 16,
            speed: RationalValue(2)
        )

        XCTAssertEqual(clip.timelineRange.duration, try editTime(8))
        XCTAssertEqual(try clip.sourceTime(at: try editTime(12)), try editTime(4))

        let halfSpeedClip = try makeEditClip(
            id: try editUUID(4_210_003),
            mediaID: mediaID,
            startFrame: 10,
            durationFrames: 16,
            speed: try RationalValue(numerator: 1, denominator: 2)
        )

        XCTAssertEqual(halfSpeedClip.timelineRange.duration, try editTime(32))
        XCTAssertEqual(try halfSpeedClip.sourceTime(at: try editTime(14)), try editTime(2))
    }

    func testFRSPD003ReverseMapsSourceTimeFromRangeEndAndComposesWithSpeed() throws {
        let mediaID = try editUUID(4_215_001)
        let reversedClip = try makeEditClip(
            id: try editUUID(4_215_002),
            mediaID: mediaID,
            startFrame: 10,
            durationFrames: 16,
            reverse: true
        )
        let doubleSpeedReversedClip = try makeEditClip(
            id: try editUUID(4_215_003),
            mediaID: mediaID,
            startFrame: 10,
            durationFrames: 16,
            speed: RationalValue(2),
            reverse: true
        )

        XCTAssertEqual(try reversedClip.sourceTime(at: try editTime(10)), try editTime(16))
        XCTAssertEqual(try reversedClip.sourceTime(at: try editTime(14)), try editTime(12))
        XCTAssertEqual(
            try doubleSpeedReversedClip.sourceTime(at: try editTime(12)),
            try editTime(12)
        )
    }

    func testFRSPD003FreezeFrameMapsEveryTimeToSourceRangeStart() throws {
        let mediaID = try editUUID(4_216_001)
        let frozenClip = try makeEditClip(
            id: try editUUID(4_216_002),
            mediaID: mediaID,
            startFrame: 10,
            durationFrames: 16,
            speed: RationalValue(2),
            reverse: true,
            freezeFrame: true
        )

        XCTAssertEqual(try frozenClip.sourceTime(at: try editTime(10)), try editTime(0))
        XCTAssertEqual(try frozenClip.sourceTime(at: try editTime(12)), try editTime(0))
        XCTAssertEqual(try frozenClip.sourceTime(at: try editTime(17)), try editTime(0))
    }

    func testFRSPD001SetClipSpeedIsUndoableAndAdjustsTimelineDuration() throws {
        let fixture = try makeEditFixture(seed: 4_220)
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                speed: RationalValue(2)
            )
        )
        let editedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(editedClip.speed, RationalValue(2))
        XCTAssertEqual(editedClip.sourceRange.duration, try editTime(10))
        XCTAssertEqual(editedClip.timelineRange.duration, try editTime(5))
        XCTAssertEqual(try editedClip.sourceTime(at: try editTime(2)), try editTime(4))
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRSPD001ZeroAndNegativeSpeedsReturnTypedEditErrors() throws {
        let fixture = try makeEditFixture(seed: 4_230)
        let invalidSpeeds = [
            RationalValue.zero,
            RationalValue(-1)
        ]

        for speed in invalidSpeeds {
            XCTAssertThrowsError(
                try apply(
                    .setClipSpeed(
                        sequenceID: fixture.sequenceID,
                        trackID: fixture.videoTrackID,
                        clipID: fixture.clipID,
                        speed: speed
                    ),
                    to: fixture.project
                )
            ) { error in
                XCTAssertEqual(
                    error as? EditReducerError,
                    .invalidEdit(
                        .invalidClipSpeed(
                            clipID: fixture.clipID,
                            error: .nonPositiveSpeed(speed)
                        )
                    )
                )
            }
        }
    }

    func testFRSPD001ProjectValidationRejectsInvalidStoredSpeed() throws {
        let fixture = try makeEditFixture(seed: 4_240)
        let invalidClip = Clip(
            id: try editUUID(4_240_100),
            source: .media(id: fixture.mediaID),
            sourceRange: try editRange(startFrame: 0, durationFrames: 10),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .video,
            name: "Invalid speed clip",
            speed: RationalValue.zero
        )
        let invalidSpeedProject = try replacingVideoItems([.clip(invalidClip)], in: fixture)

        guard case .invalid(let invalidSpeedErrors) = invalidSpeedProject.validate() else {
            return XCTFail("Expected invalid speed project")
        }
        XCTAssertTrue(
            invalidSpeedErrors.contains(
                .invalidClipSpeed(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: invalidClip.id,
                    error: .nonPositiveSpeed(.zero)
                )
            )
        )
    }

    func testFRSPD001FRSPD003ProjectCodecRoundTripsRemapAndLegacyDefaultsToNormal() throws {
        let fixture = try makeEditFixture(seed: 4_250)
        let speed = try RationalValue(numerator: 3, denominator: 2)
        let retimedClip = try makeEditClip(
            id: fixture.clipID,
            mediaID: fixture.mediaID,
            startFrame: 0,
            durationFrames: 12,
            speed: speed,
            reverse: true,
            freezeFrame: true
        )
        let retimedProject = try replacingVideoItems([.clip(retimedClip)], in: fixture)
        let package = try AjarProjectCodec.encodeNewDocument(retimedProject)
        let loaded = try speedEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let loadedClip = try requiredClip(fixture.clipID, in: loaded, fixture: fixture)

        XCTAssertEqual(loadedClip.speed, speed)
        XCTAssertTrue(loadedClip.reverse)
        XCTAssertTrue(loadedClip.freezeFrame)
        XCTAssertEqual(loadedClip.timelineRange.duration, try editTime(8))

        let legacyPackage = try AjarProjectCodec.encodeNewDocument(fixture.project)
        let legacyProjectJSON = try projectJSONWithoutClipSpeed(legacyPackage.projectJSON)
        let legacyLoaded = try speedEditableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: legacyPackage.mediaJSON
            )
        )
        let legacyClip = try requiredClip(fixture.clipID, in: legacyLoaded, fixture: fixture)

        XCTAssertEqual(legacyClip.speed, RationalValue.one)
        XCTAssertFalse(legacyClip.reverse)
        XCTAssertFalse(legacyClip.freezeFrame)
    }
}

private func speedEditableProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        XCTFail("Expected editable project")
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

private func projectJSONWithoutClipSpeed(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    let stripped = try stripSpeed(from: object)
    return try JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
}

private func stripSpeed(from value: Any) throws -> Any {
    if var dictionary = value as? [String: Any] {
        dictionary.removeValue(forKey: "speed")
        dictionary.removeValue(forKey: "reverse")
        dictionary.removeValue(forKey: "freezeFrame")
        for (key, nested) in dictionary {
            dictionary[key] = try stripSpeed(from: nested)
        }
        return dictionary
    }
    if let array = value as? [Any] {
        return try array.map { try stripSpeed(from: $0) }
    }
    return value
}
