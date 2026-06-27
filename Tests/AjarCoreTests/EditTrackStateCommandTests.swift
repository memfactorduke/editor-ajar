// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCore

final class EditTrackStateCommandTests: XCTestCase {
    func testFRTL001SetTrackStateTogglesVideoFlagsWithoutChangingItems() throws {
        let fixture = try makeEditFixture(seed: 330)
        let edited = try apply(
            .setTrackState(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                state: TrackStatePatch(enabled: false, locked: true, hidden: true)
            ),
            to: fixture.project
        )

        let track = try projectTrack(edited, fixture: fixture)
        XCTAssertFalse(track.enabled)
        XCTAssertTrue(track.locked)
        XCTAssertFalse(track.muted)
        XCTAssertFalse(track.solo)
        XCTAssertTrue(track.hidden)
        XCTAssertEqual(track.items, try projectTrack(fixture.project, fixture: fixture).items)
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testFRTL001SetTrackStateTogglesAudioMuteSoloAndUndoRedoRoundTrips() throws {
        let fixture = try makeEditFixture(seed: 331)
        let command = EditCommand.setTrackState(
            sequenceID: fixture.sequenceID,
            trackID: fixture.audioTrackID,
            state: TrackStatePatch(locked: true, muted: true, solo: true)
        )
        var history = EditHistory(project: fixture.project)
        let edited = try history.apply(command)

        let audioTrack = try track(fixture.audioTrackID, in: edited)
        XCTAssertTrue(audioTrack.locked)
        XCTAssertTrue(audioTrack.muted)
        XCTAssertTrue(audioTrack.solo)
        XCTAssertFalse(audioTrack.hidden)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRCOMP006SetTrackCompositingRoutesThroughUndoableHistory() throws {
        let fixture = try makeEditFixture(seed: 333)
        let opacity = Animatable.constant(try RationalValue(numerator: 3, denominator: 4))
        let command = EditCommand.setTrackCompositing(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            compositing: TrackCompositingPatch(opacity: opacity, blendMode: .colorDodge)
        )
        var history = EditHistory(project: fixture.project)
        let edited = try history.apply(command)
        let track = try projectTrack(edited, fixture: fixture)

        XCTAssertEqual(track.opacity, opacity)
        XCTAssertEqual(track.blendMode, .colorDodge)
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRCOMP006InvalidTrackOpacityReturnsTypedValidationError() throws {
        let fixture = try makeEditFixture(seed: 334)
        let invalidOpacity = Animatable.constant(RationalValue(2))

        XCTAssertThrowsError(
            try apply(
                .setTrackCompositing(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    compositing: TrackCompositingPatch(opacity: invalidOpacity)
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .validationFailed([
                    .invalidTrackOpacity(
                        sequenceID: fixture.sequenceID,
                        trackID: fixture.videoTrackID,
                        value: RationalValue(2)
                    )
                ])
            )
        }
    }

    func testNFRSTAB003SetTrackStateReturnsTypedMissingTrackError() throws {
        let fixture = try makeEditFixture(seed: 332)
        let missingTrackID = try editUUID(332_999)

        XCTAssertThrowsError(
            try apply(
                .setTrackState(
                    sequenceID: fixture.sequenceID,
                    trackID: missingTrackID,
                    state: TrackStatePatch(enabled: false)
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .trackNotFound(sequenceID: fixture.sequenceID, trackID: missingTrackID)
            )
        }
    }

    private func track(_ trackID: UUID, in project: Project) throws -> Track {
        let sequence = try XCTUnwrap(project.sequences.first)
        return try XCTUnwrap(
            (sequence.videoTracks + sequence.audioTracks).first { $0.id == trackID }
        )
    }
}
