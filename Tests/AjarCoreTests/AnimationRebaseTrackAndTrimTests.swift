// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Track-automation compound rebase and trim-exclusion regressions for issue #198.
final class AnimationRebaseTrackAndTrimTests: XCTestCase {
    // MARK: - Track-level automation on make-compound / decompose

    func testMakeCompoundRebasesTrackAutomationIntoInnerTimebase() throws {
        let fixture = try makeEditFixture(seed: 19_850)
        // Clip at [10, 20); track opacity keyframes at absolute parent times 12 and 16.
        let project = try projectWithTrackAutomation(
            fixture: fixture,
            clipStartFrame: 10,
            opacityKeyframes: [
                (frame: 12, value: .one),
                (frame: 16, value: try RationalValue(numerator: 1, denominator: 2))
            ]
        )

        let compoundSequenceID = try editUUID(19_850_901)
        let compoundClipID = try editUUID(19_850_902)
        let compounded = try apply(
            .makeCompoundClip(
                sequenceID: fixture.sequenceID,
                compoundSequenceID: compoundSequenceID,
                compoundClipID: compoundClipID,
                selectedClips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: fixture.clipID)
                ],
                name: "Track automation compound"
            ),
            to: project
        )

        let nestedSequence = try XCTUnwrap(
            compounded.sequences.first { $0.id == compoundSequenceID }
        )
        let nestedTrack = try XCTUnwrap(nestedSequence.videoTracks.first)
        // Nested timebase starts at 0: parent times 12/16 → nested 2/6 (selectionStart=10).
        XCTAssertEqual(
            nestedTrack.opacity.keyframes.map(\.time),
            [try editTime(2), try editTime(6)]
        )
        // Evaluate at nested offset 4 (= parent-relative offset from selection start).
        XCTAssertEqual(
            nestedTrack.opacity.value(at: try editTime(4)),
            project.sequences[0].videoTracks[0].opacity.value(at: try editTime(14))
        )
        XCTAssertEqual(compounded.validate(), .valid)
    }

    func testDecomposeRejectsKeyframedNestedTrackAutomation() throws {
        let fixture = try makeEditFixture(seed: 19_851)
        let compoundSequenceID = try editUUID(19_851_901)
        let compoundClipID = try editUUID(19_851_902)
        let project = try projectWithKeyframedNestedTrackAutomation(
            fixture: fixture,
            compoundSequenceID: compoundSequenceID,
            compoundClipID: compoundClipID,
            nestedTrackID: try editUUID(19_851_903),
            nestedClipID: try editUUID(19_851_904)
        )

        XCTAssertThrowsError(
            try apply(
                .decomposeCompoundClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: compoundClipID
                ),
                to: project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .compoundDecomposeUnsupportedAttribute(
                        clipID: compoundClipID,
                        attribute: .trackAutomation
                    )
                )
            )
        }
    }

    func testDecomposeAllowsConstantNestedTrackAutomationRoundTrip() throws {
        let fixture = try makeEditFixture(seed: 19_852)
        let half = try RationalValue(numerator: 1, denominator: 2)
        let project = try projectWithConstantTrackOpacity(fixture: fixture, opacity: half)

        let compoundSequenceID = try editUUID(19_852_901)
        let compoundClipID = try editUUID(19_852_902)
        let compounded = try apply(
            .makeCompoundClip(
                sequenceID: fixture.sequenceID,
                compoundSequenceID: compoundSequenceID,
                compoundClipID: compoundClipID,
                selectedClips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: fixture.clipID)
                ],
                name: "Constant track automation"
            ),
            to: project
        )
        let nestedSequence = try XCTUnwrap(
            compounded.sequences.first { $0.id == compoundSequenceID }
        )
        // Nested track inherits constant opacity (no keyframes to shift).
        XCTAssertEqual(nestedSequence.videoTracks[0].opacity, .constant(half))
        XCTAssertTrue(nestedSequence.videoTracks[0].opacity.keyframes.isEmpty)

        let expanded = try apply(
            .decomposeCompoundClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: compoundClipID
            ),
            to: compounded
        )
        let afterTrack = try projectTrack(
            fixture.videoTrackID,
            in: expanded,
            sequenceID: fixture.sequenceID
        )
        // Parent retained its constant opacity; expand is allowed.
        XCTAssertEqual(afterTrack.opacity, .constant(half))
        XCTAssertEqual(expanded.validate(), .valid)
    }

    // MARK: - Trim / slip / roll must NOT rebase absolute keyframe times

    func testTrimDoesNotShiftAbsoluteKeyframeTimes() throws {
        let fixture = try makeEditFixture(seed: 19_860)
        let project = try projectWithAnimatedClip(
            fixture: fixture,
            families: .transform,
            startFrame: 0
        )
        let before = try requiredClip(fixture.clipID, in: project, fixture: fixture)
        let beforeTimes = before.transformAnimation.opacity.keyframes.map(\.time)

        // Head-trim: timeline [0,10) → [2,10), source advances by 2 frames.
        let edited = try apply(
            .trimClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                sourceRange: try editRange(startFrame: 2, durationFrames: 8),
                timelineRange: try editRange(startFrame: 2, durationFrames: 8),
                linkedClipEditMode: .unlinked
            ),
            to: project
        )
        let after = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        // Absolute keyframe times must stay put (edge trim, not body move).
        XCTAssertEqual(after.transformAnimation.opacity.keyframes.map(\.time), beforeTimes)
        XCTAssertEqual(after.timelineRange.start, try editTime(2))
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testSlipDoesNotShiftAbsoluteKeyframeTimes() throws {
        let fixture = try makeEditFixture(seed: 19_861)
        let project = try projectWithAnimatedClip(
            fixture: fixture,
            families: .transform,
            startFrame: 0
        )
        let before = try requiredClip(fixture.clipID, in: project, fixture: fixture)
        let beforeTimes = before.transformAnimation.opacity.keyframes.map(\.time)

        // Slip shifts source only; timeline placement is fixed.
        let edited = try apply(
            .slipClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                sourceRange: try editRange(startFrame: 2, durationFrames: 10),
                linkedClipEditMode: .unlinked
            ),
            to: project
        )
        let after = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        XCTAssertEqual(after.transformAnimation.opacity.keyframes.map(\.time), beforeTimes)
        XCTAssertEqual(after.timelineRange, before.timelineRange)
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testRollDoesNotShiftAbsoluteKeyframeTimes() throws {
        let fixture = try makeEditFixture(seed: 19_862)
        let leftID = fixture.clipID
        let rightID = try editUUID(19_862_050)
        let left = try makeFullyAnimatedClip(
            id: leftID,
            mediaID: fixture.mediaID,
            startFrame: 0,
            families: .transform
        )
        // Right neighbor [10, 20) with its own keyframes at absolute 12 and 16.
        let right = try makeFullyAnimatedClip(
            id: rightID,
            mediaID: fixture.mediaID,
            startFrame: 10,
            families: .transform
        )
        let project = try replacingVideoItems([.clip(left), .clip(right)], in: fixture)
        let beforeLeft = try requiredClip(leftID, in: project, fixture: fixture)
        let beforeRight = try requiredClip(
            rightID,
            trackID: fixture.videoTrackID,
            in: project,
            sequenceID: fixture.sequenceID
        )
        let leftTimes = beforeLeft.transformAnimation.opacity.keyframes.map(\.time)
        let rightTimes = beforeRight.transformAnimation.opacity.keyframes.map(\.time)

        // Roll the cut from frame 10 to frame 8: left shortens, right start moves earlier.
        let edited = try apply(
            .rollEdit(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                leftClipID: leftID,
                rightClipID: rightID,
                editTime: try editTime(8)
            ),
            to: project
        )
        let afterLeft = try requiredClip(leftID, in: edited, fixture: fixture)
        let afterRight = try requiredClip(
            rightID,
            trackID: fixture.videoTrackID,
            in: edited,
            sequenceID: fixture.sequenceID
        )
        XCTAssertEqual(afterLeft.transformAnimation.opacity.keyframes.map(\.time), leftTimes)
        XCTAssertEqual(afterRight.transformAnimation.opacity.keyframes.map(\.time), rightTimes)
        XCTAssertEqual(afterRight.timelineRange.start, try editTime(8))
        XCTAssertEqual(edited.validate(), .valid)
    }
}
