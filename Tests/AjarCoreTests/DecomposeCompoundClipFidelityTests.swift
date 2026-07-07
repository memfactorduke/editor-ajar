// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class DecomposeCompoundClipFidelityTests: XCTestCase {
    func testFRCMP004DecomposeWindowsExpansionToCompoundSourceRange() throws {
        let fixture = try makeWindowedDecomposeFixture(seed: 1388, compoundSpeed: .one)

        let decomposed = try apply(
            .decomposeCompoundClip(
                sequenceID: fixture.parentSequenceID,
                trackID: fixture.trackID,
                clipID: fixture.compoundClipID
            ),
            to: fixture.project
        )

        let head = try requiredClip(
            fixture.headClipID,
            trackID: fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(head.timelineRange, startFrame: 20, durationFrames: 2)
        try assertRange(head.sourceRange, startFrame: 4, durationFrames: 2)
        let inside = try requiredClip(
            fixture.insideClipID,
            trackID: fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(inside.timelineRange, startFrame: 22, durationFrames: 2)
        try assertRange(inside.sourceRange, startFrame: 0, durationFrames: 2)
        let tail = try requiredClip(
            fixture.tailClipID,
            trackID: fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(tail.timelineRange, startFrame: 24, durationFrames: 2)
        try assertRange(tail.sourceRange, startFrame: 0, durationFrames: 2)
        let track = try projectTrack(
            fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        XCTAssertNil(clip(fixture.outsideClipID, in: track))
        XCTAssertEqual(decomposed.validate(), .valid)
    }

    func testFRCMP004DecomposeWindowsSpeedCompoundExpansionExactly() throws {
        let fixture = try makeWindowedDecomposeFixture(seed: 1389, compoundSpeed: RationalValue(2))

        let decomposed = try apply(
            .decomposeCompoundClip(
                sequenceID: fixture.parentSequenceID,
                trackID: fixture.trackID,
                clipID: fixture.compoundClipID
            ),
            to: fixture.project
        )

        let head = try requiredClip(
            fixture.headClipID,
            trackID: fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(head.timelineRange, startFrame: 20, durationFrames: 1)
        try assertRange(head.sourceRange, startFrame: 4, durationFrames: 2)
        let inside = try requiredClip(
            fixture.insideClipID,
            trackID: fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(inside.timelineRange, startFrame: 21, durationFrames: 1)
        let tail = try requiredClip(
            fixture.tailClipID,
            trackID: fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(tail.timelineRange, startFrame: 22, durationFrames: 1)
        try assertRange(tail.sourceRange, startFrame: 0, durationFrames: 2)
        XCTAssertEqual(head.speed, RationalValue(2))
        XCTAssertEqual(inside.speed, RationalValue(2))
        XCTAssertEqual(tail.speed, RationalValue(2))
        XCTAssertEqual(decomposed.validate(), .valid)
    }

    func testFRCMP004DecomposeRestoresWindowedClipAnchoredMarkers() throws {
        let fixture = try makeWindowedDecomposeFixture(seed: 1390, compoundSpeed: .one)

        let decomposed = try apply(
            .decomposeCompoundClip(
                sequenceID: fixture.parentSequenceID,
                trackID: fixture.trackID,
                clipID: fixture.compoundClipID
            ),
            to: fixture.project
        )

        let parentSequence = try requiredDecomposeSequence(
            fixture.parentSequenceID,
            in: decomposed
        )
        XCTAssertEqual(
            parentSequence.markers,
            [
                Marker(id: fixture.parentMarkerID, time: try editTime(2), name: "parent timeline"),
                Marker(
                    id: fixture.windowMarkerID,
                    time: try editTime(21),
                    name: "inside window",
                    color: .red,
                    note: "restore me",
                    anchor: .clip(trackID: fixture.trackID, clipID: fixture.headClipID)
                )
            ]
        )
        let targetSequence = try requiredDecomposeSequence(
            fixture.targetSequenceID,
            in: decomposed
        )
        XCTAssertEqual(
            targetSequence.markers,
            try requiredDecomposeSequence(fixture.targetSequenceID, in: fixture.project).markers
        )
        XCTAssertEqual(decomposed.validate(), .valid)
    }

    func testFRCMP004DecomposeTrimsReverseAndFreezeInnerClipsExactly() throws {
        let fixture = try makeRemappedInnerDecomposeFixture(seed: 1391)

        let decomposed = try apply(
            .decomposeCompoundClip(
                sequenceID: fixture.parentSequenceID,
                trackID: fixture.trackID,
                clipID: fixture.compoundClipID
            ),
            to: fixture.project
        )

        let reverseClip = try requiredClip(
            fixture.reverseClipID,
            trackID: fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(reverseClip.timelineRange, startFrame: 30, durationFrames: 6)
        try assertRange(reverseClip.sourceRange, startFrame: 0, durationFrames: 6)
        XCTAssertTrue(reverseClip.reverse)
        let freezeClip = try requiredClip(
            fixture.freezeClipID,
            trackID: fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(freezeClip.timelineRange, startFrame: 36, durationFrames: 2)
        try assertRange(freezeClip.sourceRange, startFrame: 3, durationFrames: 2)
        XCTAssertTrue(freezeClip.freezeFrame)
        XCTAssertEqual(decomposed.validate(), .valid)
    }

    func testFRCMP004DecomposeRejectsNonIdentityCompoundAttributesWithTypedError() throws {
        for scenario in DecomposeAttributeScenario.allCases {
            let fixture = try makeAttributeDecomposeFixture(seed: 1392, scenario: scenario)

            XCTAssertThrowsError(
                try apply(
                    .decomposeCompoundClip(
                        sequenceID: fixture.parentSequenceID,
                        trackID: fixture.trackID,
                        clipID: fixture.compoundClipID
                    ),
                    to: fixture.project
                ),
                "expected \(scenario) to be rejected"
            ) { error in
                XCTAssertEqual(
                    error as? EditReducerError,
                    .invalidEdit(
                        .compoundDecomposeUnsupportedAttribute(
                            clipID: fixture.compoundClipID,
                            attribute: scenario.expectedAttribute
                        )
                    )
                )
            }
        }
    }

    func testFRCMP004DecomposeRejectsCompoundDurationMismatchWithTypedError() throws {
        let fixture = try makeMismatchedDurationDecomposeFixture(seed: 1393)
        let expectedSourceDuration = try editTime(10)
        let expectedTimelineDuration = try editTime(8)

        XCTAssertThrowsError(
            try apply(
                .decomposeCompoundClip(
                    sequenceID: fixture.parentSequenceID,
                    trackID: fixture.trackID,
                    clipID: fixture.compoundClipID
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .durationMismatch(
                        clipID: fixture.compoundClipID,
                        sourceDuration: expectedSourceDuration,
                        timelineDuration: expectedTimelineDuration
                    )
                )
            )
        }
    }

    func testFRCMP004MakeThenDecomposeRoundTripsClipsAttributesAndMarkers() throws {
        let fixture = try makeRichRoundTripFixture(seed: 1394)
        var history = EditHistory(project: fixture.project)
        let made = try history.apply(
            .makeCompoundClip(
                sequenceID: fixture.sequenceID,
                compoundSequenceID: fixture.compoundSequenceID,
                compoundClipID: fixture.compoundClipID,
                selectedClips: fixture.selection,
                name: "FR-CMP-004 rich round trip compound"
            )
        )

        let decomposed = try history.apply(
            .decomposeCompoundClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.destinationTrackID,
                clipID: fixture.compoundClipID
            )
        )

        XCTAssertEqual(
            try requiredDecomposeSequence(fixture.sequenceID, in: decomposed),
            try requiredDecomposeSequence(fixture.sequenceID, in: fixture.project)
        )
        XCTAssertNotNil(decomposed.sequences.first { $0.id == fixture.compoundSequenceID })
        XCTAssertEqual(decomposed.validate(), .valid)
        XCTAssertEqual(history.undo(), made)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), made)
        XCTAssertEqual(try history.redo(), decomposed)
    }
}
