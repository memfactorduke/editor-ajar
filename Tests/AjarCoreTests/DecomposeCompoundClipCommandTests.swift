// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class DecomposeCompoundClipCommandTests: XCTestCase {
    func testFRCMP004DecomposeInsertedCompoundRoutesThroughUndoableHistory() throws {
        let fixture = try makeCompoundInsertFixture(seed: 1380)
        var history = EditHistory(project: fixture.project)
        let inserted = try history.apply(
            .insertCompoundClip(
                sequenceID: fixture.outerSequenceID,
                trackID: fixture.outerTrackID,
                clipID: fixture.compoundClipID,
                targetSequenceID: fixture.innerSequenceID,
                timelineStart: try editTime(5),
                kind: .video,
                name: "FR-CMP-004 inserted compound"
            )
        )

        let decomposed = try history.apply(
            .decomposeCompoundClip(
                sequenceID: fixture.outerSequenceID,
                trackID: fixture.outerTrackID,
                clipID: fixture.compoundClipID
            )
        )

        XCTAssertNil(
            clip(
                fixture.compoundClipID,
                in: try projectTrack(
                    fixture.outerTrackID,
                    in: decomposed,
                    sequenceID: fixture.outerSequenceID
                )
            )
        )
        let expanded = try requiredClip(
            fixture.innerClipID,
            trackID: fixture.innerTrackID,
            in: decomposed,
            sequenceID: fixture.outerSequenceID
        )
        XCTAssertEqual(expanded.source, .media(id: try editUUID(1_380_001)))
        try assertRange(expanded.timelineRange, startFrame: 5, durationFrames: 12)
        XCTAssertEqual(decomposed.validate(), .valid)
        XCTAssertEqual(history.undo(), inserted)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), inserted)
        XCTAssertEqual(try history.redo(), decomposed)
    }

    func testFRCMP004MakeThenDecomposeRestoresParentClipLayoutAndLeavesNestedSequence() throws {
        let fixture = try makeEditFixture(seed: 1381)
        let compoundSequenceID = try editUUID(1_381_028)
        let compoundClipID = try editUUID(1_381_029)
        var history = EditHistory(project: fixture.project)
        let made = try history.apply(
            .makeCompoundClip(
                sequenceID: fixture.sequenceID,
                compoundSequenceID: compoundSequenceID,
                compoundClipID: compoundClipID,
                selectedClips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: fixture.clipID)
                ],
                name: "FR-CMP-004 round trip"
            )
        )

        let decomposed = try history.apply(
            .decomposeCompoundClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: compoundClipID
            )
        )

        XCTAssertEqual(
            try requiredDecomposeSequence(fixture.sequenceID, in: decomposed),
            try requiredDecomposeSequence(fixture.sequenceID, in: fixture.project)
        )
        XCTAssertNotNil(decomposed.sequences.first { $0.id == compoundSequenceID })
        XCTAssertEqual(decomposed.validate(), .valid)
        XCTAssertEqual(history.undo(), made)
        XCTAssertEqual(history.undo(), fixture.project)
    }

    func testFRCMP004DecomposeMapsTwoXAndHalfSpeedCompoundTimingExactly() throws {
        for scenario in try speedDecomposeScenarios() {
            let fixture = try makeSpeedAwareDecomposeFixture(
                seed: scenario.seed,
                compoundSpeed: scenario.speed,
                compoundTimelineDurationFrames: scenario.compoundDuration
            )
            let decomposed = try apply(
                .decomposeCompoundClip(
                    sequenceID: fixture.parentSequenceID,
                    trackID: fixture.trackID,
                    clipID: fixture.compoundClipID
                ),
                to: fixture.project
            )

            let first = try requiredClip(
                fixture.firstClipID,
                trackID: fixture.trackID,
                in: decomposed,
                sequenceID: fixture.parentSequenceID
            )
            let second = try requiredClip(
                fixture.secondClipID,
                trackID: fixture.trackID,
                in: decomposed,
                sequenceID: fixture.parentSequenceID
            )
            try assertRange(
                first.timelineRange,
                startFrame: scenario.expectedFirstStart,
                durationFrames: scenario.expectedFirstDuration
            )
            try assertRange(
                second.timelineRange,
                startFrame: scenario.expectedSecondStart,
                durationFrames: scenario.expectedSecondDuration
            )
            XCTAssertEqual(first.speed, scenario.speed)
            XCTAssertEqual(second.speed, scenario.speed)
            XCTAssertEqual(decomposed.validate(), .valid)
        }
    }

    func testFRCMP004EmptyCompoundSequenceRemovesCompoundWithoutCrashing() throws {
        let fixture = try makeEmptyDecomposeFixture(seed: 1384)
        var history = EditHistory(project: fixture.project)

        let decomposed = try history.apply(
            .decomposeCompoundClip(
                sequenceID: fixture.parentSequenceID,
                trackID: fixture.trackID,
                clipID: fixture.compoundClipID
            )
        )

        let track = try projectTrack(
            fixture.trackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        XCTAssertTrue(track.items.isEmpty)
        XCTAssertNotNil(decomposed.sequences.first { $0.id == fixture.targetSequenceID })
        XCTAssertEqual(decomposed.validate(), .valid)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), decomposed)
    }

    func testFRCMP004DecomposeExpandsMultiTrackTargetIntoParentTracks() throws {
        let fixture = try makeMultiTrackDecomposeFixture(seed: 1387)

        let decomposed = try apply(
            .decomposeCompoundClip(
                sequenceID: fixture.parentSequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.compoundClipID
            ),
            to: fixture.project
        )

        let videoClip = try requiredClip(
            fixture.videoClipID,
            trackID: fixture.videoTrackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        let audioClip = try requiredClip(
            fixture.audioClipID,
            trackID: fixture.audioTrackID,
            in: decomposed,
            sequenceID: fixture.parentSequenceID
        )
        try assertRange(videoClip.timelineRange, startFrame: 12, durationFrames: 8)
        try assertRange(audioClip.timelineRange, startFrame: 14, durationFrames: 6)
        XCTAssertEqual(videoClip.kind, .video)
        XCTAssertEqual(audioClip.kind, .audio)
        XCTAssertEqual(decomposed.validate(), .valid)
    }

    func testFRCMP004DecomposeRejectsNonCompoundClipWithTypedError() throws {
        let fixture = try makeEditFixture(seed: 1385)

        XCTAssertThrowsError(
            try apply(
                .decomposeCompoundClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.decomposeRequiresCompoundClip(clipID: fixture.clipID))
            )
        }
    }

    func testFRCMP004DecomposeRejectsExpandedClipOverlapWithTypedError() throws {
        let fixture = try makeOverlapDecomposeFixture(seed: 1386)
        let expectedRange = try editRange(startFrame: 0, durationFrames: 10)

        XCTAssertThrowsError(
            try apply(
                .decomposeCompoundClip(
                    sequenceID: fixture.parentSequenceID,
                    trackID: fixture.compoundTrackID,
                    clipID: fixture.compoundClipID
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .compoundDecomposeWouldOverlap(
                        sequenceID: fixture.parentSequenceID,
                        trackID: fixture.targetTrackID,
                        clipID: fixture.innerClipID,
                        timelineRange: expectedRange
                    )
                )
            )
        }
    }
}
