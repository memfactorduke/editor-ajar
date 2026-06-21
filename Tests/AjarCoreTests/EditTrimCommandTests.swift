// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class EditReducerTrimEditTests: XCTestCase {
    func testFRTL004BladeSplitsClipWithContiguousTimelineAndSourceRanges() throws {
        let fixture = try makeEditFixture(seed: 300)
        let rightClipID = try editUUID(300_001)

        let edited = try apply(
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                atTime: try editTime(4),
                rightClipID: rightClipID
            ),
            to: fixture.project
        )
        let leftClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let rightClip = try requiredClip(rightClipID, in: edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        try assertRange(leftClip.timelineRange, startFrame: 0, durationFrames: 4)
        try assertRange(leftClip.sourceRange, startFrame: 0, durationFrames: 4)
        try assertRange(rightClip.timelineRange, startFrame: 4, durationFrames: 6)
        try assertRange(rightClip.sourceRange, startFrame: 4, durationFrames: 6)
    }

    func testFRTL005RippleDeleteClosesGapByShiftingLaterItemsLeftExactly() throws {
        let fixture = try makeEditFixture(seed: 310)
        let laterClipID = try editUUID(310_001)
        let laterClip = try makeEditClip(
            id: laterClipID,
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 5
        )
        let project = try applyingAddClip(laterClip, fixture: fixture)

        let edited = try apply(
            .rippleDeleteClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            ),
            to: project
        )
        let track = try projectTrack(edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertNil(clip(fixture.clipID, in: track))
        try assertClipRange(
            laterClipID,
            in: edited,
            fixture: fixture,
            startFrame: 0,
            durationFrames: 5
        )
    }

    func testFRTL005LiftLeavesGapWithRemovedClipDuration() throws {
        let fixture = try makeEditFixture(seed: 320)
        let laterClipID = try editUUID(320_001)
        let laterClip = try makeEditClip(
            id: laterClipID,
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 5
        )
        let project = try applyingAddClip(laterClip, fixture: fixture)

        let edited = try apply(
            .liftClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID
            ),
            to: project
        )
        let track = try projectTrack(edited, fixture: fixture)
        let liftedGap = try firstGap(in: track)

        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertNil(clip(fixture.clipID, in: track))
        try assertRange(liftedGap, startFrame: 0, durationFrames: 10)
        try assertClipRange(
            laterClipID,
            in: edited,
            fixture: fixture,
            startFrame: 10,
            durationFrames: 5
        )
    }

    func testFRTL004SlipChangesSourceRangeWithoutMovingTimelinePlacement() throws {
        let fixture = try makeEditFixture(seed: 330)
        let sourceRange = try editRange(startFrame: 6, durationFrames: 10)

        let edited = try apply(
            .slipClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                sourceRange: sourceRange
            ),
            to: fixture.project
        )
        let slippedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertEqual(slippedClip.sourceRange, sourceRange)
        try assertRange(slippedClip.timelineRange, startFrame: 0, durationFrames: 10)
    }

    func testFRTL004RollMovesSharedEditPointKeepingTotalDurationConstant() throws {
        let fixture = try makeEditFixture(seed: 340)
        let rightClipID = try editUUID(340_001)
        let rightClip = try makeEditClip(
            id: rightClipID,
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 10
        )
        let project = try applyingAddClip(rightClip, fixture: fixture)

        let edited = try apply(
            .rollEdit(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                leftClipID: fixture.clipID,
                rightClipID: rightClipID,
                editTime: try editTime(12)
            ),
            to: project
        )
        let leftClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let rolledRightClip = try requiredClip(rightClipID, in: edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        try assertRange(leftClip.timelineRange, startFrame: 0, durationFrames: 12)
        try assertRange(leftClip.sourceRange, startFrame: 0, durationFrames: 12)
        try assertRange(rolledRightClip.timelineRange, startFrame: 12, durationFrames: 8)
        try assertRange(rolledRightClip.sourceRange, startFrame: 2, durationFrames: 8)
    }

    func testFRTL004SlideMovesClipAndAdjustsNeighborsKeepingOuterSpan() throws {
        let fixture = try makeEditFixture(seed: 350)
        let targetClipID = try editUUID(350_001)
        let nextClipID = try editUUID(350_002)
        let targetClip = try makeEditClip(
            id: targetClipID,
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 5
        )
        let nextClip = try makeEditClip(
            id: nextClipID,
            mediaID: fixture.mediaID,
            startFrame: 15,
            durationFrames: 10
        )
        let project = try replacingVideoItems(
            [
                .clip(try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)),
                .clip(targetClip),
                .clip(nextClip)
            ],
            in: fixture
        )

        let edited = try apply(
            .slideClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: targetClipID,
                timelineRange: try editRange(startFrame: 12, durationFrames: 5)
            ),
            to: project
        )
        let previousClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let slidClip = try requiredClip(targetClipID, in: edited, fixture: fixture)
        let adjustedNextClip = try requiredClip(nextClipID, in: edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        try assertRange(previousClip.timelineRange, startFrame: 0, durationFrames: 12)
        try assertRange(slidClip.timelineRange, startFrame: 12, durationFrames: 5)
        try assertRange(adjustedNextClip.timelineRange, startFrame: 17, durationFrames: 8)
        try assertRange(adjustedNextClip.sourceRange, startFrame: 2, durationFrames: 8)
    }

    func testFRTL004RippleTrimShiftsLaterItemsByTrimDelta() throws {
        let fixture = try makeEditFixture(seed: 360)
        let laterClipID = try editUUID(360_001)
        let laterClip = try makeEditClip(
            id: laterClipID,
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 5
        )
        let project = try applyingAddClip(laterClip, fixture: fixture)

        let edited = try apply(
            .rippleTrimClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                sourceRange: try editRange(startFrame: 0, durationFrames: 6),
                timelineRange: try editRange(startFrame: 0, durationFrames: 6)
            ),
            to: project
        )

        XCTAssertEqual(edited.validate(), .valid)
        try assertClipRange(
            fixture.clipID,
            in: edited,
            fixture: fixture,
            startFrame: 0,
            durationFrames: 6
        )
        try assertClipRange(
            laterClipID,
            in: edited,
            fixture: fixture,
            startFrame: 6,
            durationFrames: 5
        )
    }

    func testFRTL004ADR0008SlipDurationMismatchReturnsTypedError() throws {
        let fixture = try makeEditFixture(seed: 370)
        let sourceRange = try editRange(startFrame: 0, durationFrames: 9)
        let expectedError = EditReducerError.invalidEdit(
            .durationMismatch(
                clipID: fixture.clipID,
                sourceDuration: try editTime(9),
                timelineDuration: try editTime(10)
            )
        )

        XCTAssertThrowsError(
            try apply(
                .slipClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    sourceRange: sourceRange
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(error as? EditReducerError, expectedError)
        }
    }
}

private func firstGap(in track: Track) throws -> TimeRange {
    for item in track.items {
        if case .gap(let range) = item {
            return range
        }
    }
    return try XCTUnwrap(nil)
}
