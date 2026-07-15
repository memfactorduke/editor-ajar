// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Mid-clip insert split behavior (FR-TL-003 / ADR-0008).
///
/// The app clamps the playhead to the last *displayable* frame (`durationFrames - 1`), so
/// scrub-to-end + insert always lands inside the last clip. Without a mid-clip split the
/// new clip overlaps and project validation refuses the edit — the #236 acceptance path.
final class InsertClipMidClipTests: XCTestCase {
    func testFRTL003InsertMidClipSplitsAndRipplesRightHalf() throws {
        let fixture = try makeEditFixture(seed: 231)
        // Fixture clip occupies [0, 10). Insert at frame 9 (last displayable frame).
        let insertClipID = try editUUID(231_001)
        let insertClip = try makeEditClip(
            id: insertClipID,
            mediaID: fixture.mediaID,
            startFrame: 9,
            durationFrames: 5
        )

        let command = EditCommand.insertClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: insertClip
        )
        let edited = try apply(command, to: fixture.project)

        XCTAssertEqual(edited.validate(), .valid)
        let track = try projectTrack(edited, fixture: fixture)
        let clips = track.items.compactMap { item -> Clip? in
            if case .clip(let clip) = item { return clip }
            return nil
        }
        XCTAssertEqual(clips.count, 3, "mid-clip insert should leave left + inserted + right")

        try assertClipRange(
            fixture.clipID,
            in: edited,
            fixture: fixture,
            startFrame: 0,
            durationFrames: 9
        )
        try assertClipRange(
            insertClipID,
            in: edited,
            fixture: fixture,
            startFrame: 9,
            durationFrames: 5
        )
        let right = try XCTUnwrap(
            clips.first { $0.id != fixture.clipID && $0.id != insertClipID }
        )
        XCTAssertEqual(right.timelineRange.start, try editTime(14))
        XCTAssertEqual(right.timelineRange.duration, try editTime(1))
        XCTAssertEqual(
            try apply(command, to: fixture.project),
            edited,
            "the implicit split ID must be stable when edit history replays insertClip"
        )
    }

    /// Insert whose timeline range would previously have overlapped an existing clip now
    /// splits that clip at the insert point. ADR-0008 non-overlap is preserved.
    func testFRTL003InsertIntoOccupiedRangeSplitsRatherThanOverlapping() throws {
        let fixture = try makeEditFixture(seed: 290)
        let insertClipID = try editUUID(290_001)
        // Fixture clip is [0, 10); insert at frame 5 for 4 frames.
        let insertClip = try makeEditClip(
            id: insertClipID,
            mediaID: fixture.mediaID,
            startFrame: 5,
            durationFrames: 4
        )

        let edited = try apply(
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: insertClip
            ),
            to: fixture.project
        )

        XCTAssertEqual(edited.validate(), .valid)
        try assertClipRange(
            fixture.clipID,
            in: edited,
            fixture: fixture,
            startFrame: 0,
            durationFrames: 5
        )
        try assertClipRange(
            insertClipID,
            in: edited,
            fixture: fixture,
            startFrame: 5,
            durationFrames: 4
        )
        let track = try projectTrack(edited, fixture: fixture)
        let right = try XCTUnwrap(
            track.items.compactMap { item -> Clip? in
                guard case .clip(let clip) = item else { return nil }
                return clip.id == fixture.clipID || clip.id == insertClipID ? nil : clip
            }.first
        )
        // Right half of original [5, 10) rippled by 4 → [9, 14).
        XCTAssertEqual(right.timelineRange.start, try editTime(9))
        XCTAssertEqual(right.timelineRange.duration, try editTime(5))
    }
}
