// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class EditReducerCoreEditTests: XCTestCase {
    func testFRTL003InsertRipplesLaterItemsByExactDuration() throws {
        let fixture = try makeEditFixture(seed: 230)
        let laterClipID = try editUUID(230_001)
        let insertClipID = try editUUID(230_002)
        let laterClip = try makeEditClip(
            id: laterClipID,
            mediaID: fixture.mediaID,
            startFrame: 20,
            durationFrames: 5
        )
        let project = try applyingAddClip(laterClip, fixture: fixture)
        let insertClip = try makeEditClip(
            id: insertClipID,
            mediaID: fixture.mediaID,
            startFrame: 10,
            durationFrames: 7
        )

        let edited = try apply(
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: insertClip
            ),
            to: project
        )

        XCTAssertEqual(edited.validate(), .valid)
        try assertClipRange(
            fixture.clipID,
            in: edited,
            fixture: fixture,
            startFrame: 0,
            durationFrames: 10
        )
        try assertClipRange(
            insertClipID,
            in: edited,
            fixture: fixture,
            startFrame: 10,
            durationFrames: 7
        )
        try assertClipRange(
            laterClipID,
            in: edited,
            fixture: fixture,
            startFrame: 27,
            durationFrames: 5
        )
    }

    func testFRTL003OverwriteReplacesRangeWithoutMovingFollowingItems() throws {
        let fixture = try makeEditFixture(seed: 240)
        let laterClipID = try editUUID(240_001)
        let overwriteClipID = try editUUID(240_002)
        let laterClip = try makeEditClip(
            id: laterClipID,
            mediaID: fixture.mediaID,
            startFrame: 20,
            durationFrames: 5
        )
        let project = try applyingAddClip(laterClip, fixture: fixture)
        let overwriteClip = try makeEditClip(
            id: overwriteClipID,
            mediaID: fixture.mediaID,
            startFrame: 0,
            durationFrames: 8
        )

        let edited = try apply(
            .overwriteClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: overwriteClip
            ),
            to: project
        )
        let track = try projectTrack(edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertNil(clip(fixture.clipID, in: track))
        try assertClipRange(
            overwriteClipID,
            in: edited,
            fixture: fixture,
            startFrame: 0,
            durationFrames: 8
        )
        try assertClipRange(
            laterClipID,
            in: edited,
            fixture: fixture,
            startFrame: 20,
            durationFrames: 5
        )
    }

    func testFRTL003AppendPlacesClipAfterLastTrackItemExactly() throws {
        let fixture = try makeEditFixture(seed: 250)
        let appendClipID = try editUUID(250_001)
        let project = try replacingVideoItems(
            [
                .clip(try requiredClip(fixture.clipID, in: fixture.project, fixture: fixture)),
                .gap(try editRange(startFrame: 12, durationFrames: 3))
            ],
            in: fixture
        )
        let appendClip = try makeEditClip(
            id: appendClipID,
            mediaID: fixture.mediaID,
            startFrame: 100,
            durationFrames: 4
        )

        let edited = try apply(
            .appendClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: appendClip
            ),
            to: project
        )

        XCTAssertEqual(edited.validate(), .valid)
        try assertClipRange(
            appendClipID,
            in: edited,
            fixture: fixture,
            startFrame: 15,
            durationFrames: 4
        )
    }

    func testFRTL003ReplaceSwapsClipSourceKeepingTimelinePlacement() throws {
        let fixture = try makeEditFixture(seed: 260)
        let replacementMediaID = try editUUID(260_001)
        let replacementMedia = try makeEditMediaRef(id: replacementMediaID)
        let project = Project(
            schemaVersion: fixture.project.schemaVersion,
            settings: fixture.project.settings,
            mediaPool: fixture.project.mediaPool + [replacementMedia],
            sequences: fixture.project.sequences
        )
        let replacementSourceRange = try editRange(startFrame: 3, durationFrames: 5)

        let edited = try apply(
            .replaceClipSource(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.clipID,
                source: .media(id: replacementMediaID),
                sourceRange: replacementSourceRange
            ),
            to: project
        )
        let replacedClip = try requiredClip(fixture.clipID, in: edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertEqual(replacedClip.source, .media(id: replacementMediaID))
        XCTAssertEqual(replacedClip.sourceRange, replacementSourceRange)
        try assertRange(replacedClip.timelineRange, startFrame: 0, durationFrames: 10)
    }

    func testFRTL003ThreePointInsertUsesSourceInOutDurationAtTimelineTarget() throws {
        let fixture = try makeEditFixture(seed: 270)
        let laterClipID = try editUUID(270_001)
        let threePointClipID = try editUUID(270_002)
        let laterClip = try makeEditClip(
            id: laterClipID,
            mediaID: fixture.mediaID,
            startFrame: 20,
            durationFrames: 5
        )
        let project = try applyingAddClip(laterClip, fixture: fixture)
        let sourceRange = try editRange(startFrame: 3, durationFrames: 4)

        let edited = try apply(
            .threePointEdit(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: threePointClipID,
                source: .media(id: fixture.mediaID),
                sourceRange: sourceRange,
                timelineStart: try editTime(10),
                kind: .video,
                name: "Three-point insert",
                mode: .insert
            ),
            to: project
        )
        let threePointClip = try requiredClip(threePointClipID, in: edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertEqual(threePointClip.sourceRange, sourceRange)
        try assertRange(threePointClip.timelineRange, startFrame: 10, durationFrames: 4)
        try assertClipRange(
            laterClipID,
            in: edited,
            fixture: fixture,
            startFrame: 24,
            durationFrames: 5
        )
    }

    func testFRTL003ThreePointOverwriteUsesSourceRangeAndLeavesFollowingItemsUntouched() throws {
        let fixture = try makeEditFixture(seed: 280)
        let laterClipID = try editUUID(280_001)
        let threePointClipID = try editUUID(280_002)
        let laterClip = try makeEditClip(
            id: laterClipID,
            mediaID: fixture.mediaID,
            startFrame: 20,
            durationFrames: 5
        )
        let project = try applyingAddClip(laterClip, fixture: fixture)
        let sourceRange = try editRange(startFrame: 5, durationFrames: 8)

        let edited = try apply(
            .threePointEdit(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: threePointClipID,
                source: .media(id: fixture.mediaID),
                sourceRange: sourceRange,
                timelineStart: try editTime(0),
                kind: .video,
                name: "Three-point overwrite",
                mode: .overwrite
            ),
            to: project
        )
        let track = try projectTrack(edited, fixture: fixture)
        let threePointClip = try requiredClip(threePointClipID, in: edited, fixture: fixture)

        XCTAssertEqual(edited.validate(), .valid)
        XCTAssertNil(clip(fixture.clipID, in: track))
        XCTAssertEqual(threePointClip.sourceRange, sourceRange)
        try assertRange(threePointClip.timelineRange, startFrame: 0, durationFrames: 8)
        try assertClipRange(
            laterClipID,
            in: edited,
            fixture: fixture,
            startFrame: 20,
            durationFrames: 5
        )
    }

    func testFRTL003ADR0008InsertOverlapReturnsTypedValidationError() throws {
        let fixture = try makeEditFixture(seed: 290)
        let overlappingClip = try makeEditClip(
            id: try editUUID(290_001),
            mediaID: fixture.mediaID,
            startFrame: 5,
            durationFrames: 4
        )

        XCTAssertThrowsError(
            try apply(
                .insertClip(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clip: overlappingClip
                ),
                to: fixture.project
            )
        ) { error in
            guard case .validationFailed(let errors) = error as? EditReducerError else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }

            XCTAssertTrue(errors.containsItemsOverlap)
        }
    }
}

private func applyingAddClip(_ clip: Clip, fixture: EditFixture) throws -> Project {
    try apply(
        .addClip(sequenceID: fixture.sequenceID, trackID: fixture.videoTrackID, clip: clip),
        to: fixture.project
    )
}

private func projectTrack(_ project: Project, fixture: EditFixture) throws -> Track {
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })
    return try XCTUnwrap(sequence.videoTracks.first { $0.id == fixture.videoTrackID })
}

private func clip(_ clipID: UUID, in track: Track) -> Clip? {
    for item in track.items {
        if case .clip(let clip) = item, clip.id == clipID {
            return clip
        }
    }
    return nil
}

private func requiredClip(
    _ clipID: UUID,
    in project: Project,
    fixture: EditFixture
) throws -> Clip {
    try XCTUnwrap(clip(clipID, in: try projectTrack(project, fixture: fixture)))
}

private func replacingVideoItems(
    _ items: [TimelineItem],
    in fixture: EditFixture
) throws -> Project {
    let project = fixture.project
    let sequence = try XCTUnwrap(project.sequences.first { $0.id == fixture.sequenceID })
    let videoTracks = sequence.videoTracks.map { track in
        if track.id == fixture.videoTrackID {
            return Track(
                id: track.id,
                kind: track.kind,
                items: items,
                enabled: track.enabled,
                locked: track.locked,
                muted: track.muted,
                solo: track.solo,
                hidden: track.hidden
            )
        }
        return track
    }
    let replacementSequence = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: videoTracks,
        audioTracks: sequence.audioTracks,
        markers: sequence.markers,
        timebase: sequence.timebase
    )

    return Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: project.sequences.map { $0.id == sequence.id ? replacementSequence : $0 }
    )
}

private func assertClipRange(
    _ clipID: UUID,
    in project: Project,
    fixture: EditFixture,
    startFrame: Int64,
    durationFrames: Int64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let foundClip = try requiredClip(clipID, in: project, fixture: fixture)
    try assertRange(
        foundClip.timelineRange,
        startFrame: startFrame,
        durationFrames: durationFrames,
        file: file,
        line: line
    )
}

private func assertRange(
    _ range: TimeRange,
    startFrame: Int64,
    durationFrames: Int64,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(range.start, try editTime(startFrame), file: file, line: line)
    XCTAssertEqual(range.duration, try editTime(durationFrames), file: file, line: line)
}

private extension Array where Element == ProjectValidationError {
    var containsItemsOverlap: Bool {
        for error in self {
            if case .itemsOverlap = error {
                return true
            }
        }
        return false
    }
}
