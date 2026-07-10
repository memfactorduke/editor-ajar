// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-FX-001 / ADR-0015 §8 edit-command interaction matrix for video transitions.
final class VideoTransitionEditMatrixTests: XCTestCase {
    private var sequenceID = UUID()
    private var trackID = UUID()
    private var outgoingID = UUID()
    private var incomingID = UUID()

    override func setUpWithError() throws {
        sequenceID = try VideoTransitionFixtureID.sequence()
        trackID = try VideoTransitionFixtureID.track()
        outgoingID = try VideoTransitionFixtureID.outgoingClip()
        incomingID = try VideoTransitionFixtureID.incomingClip()
    }

    func testFRFX001RippleTrimPreservesAndClampsPair() throws {
        let project = try makeVideoTransitionPairProject()
        let command = EditCommand.rippleTrimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 0, durationFrames: 3),
            timelineRange: try editRange(startFrame: 0, durationFrames: 3)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertEqual(outgoing.trailingTransition?.duration, try editTime(3))
        XCTAssertEqual(incoming.leadingTransition?.duration, try editTime(3))
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
    }

    func testFRFX001RippleTrimClampToZeroRemovesPair() throws {
        // Source [226, 236) + 4-frame transition; extend trim to exhaust handle.
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.sourceStartFrame = 226
        outgoingSpec.trailingTransition = try makeTrailingTransition(partner: incomingID)
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.leadingTransition = try makeLeadingTransition(partner: outgoingID)
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let command = EditCommand.rippleTrimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 226, durationFrames: 14),
            timelineRange: try editRange(startFrame: 0, durationFrames: 14)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertNil(outgoing.trailingTransition)
        XCTAssertNil(incoming.leadingTransition)
    }

    func testFRFX001RollPreservesPair() throws {
        let project = try makeVideoTransitionPairProject()
        let command = EditCommand.rollEdit(
            sequenceID: sequenceID,
            trackID: trackID,
            leftClipID: outgoingID,
            rightClipID: incomingID,
            editTime: try editTime(12)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        XCTAssertEqual(outgoing.trailingTransition?.duration, try editTime(4))
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
    }

    func testFRFX001LiftClearsPair() throws {
        let project = try makeVideoTransitionPairProject()
        let command = EditCommand.liftClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertNil(incoming.leadingTransition)
    }

    func testFRFX001RippleDeleteClearsPair() throws {
        let project = try makeVideoTransitionPairProject()
        let command = EditCommand.rippleDeleteClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        // Incoming may shift left; its leading transition should be cleared.
        let sequence = try XCTUnwrap(edited.sequences.first)
        let track = try XCTUnwrap(sequence.videoTracks.first)
        for item in track.items {
            if case .clip(let clip) = item {
                XCTAssertNil(clip.leadingTransition)
                XCTAssertNil(clip.trailingTransition)
            }
        }
    }

    func testFRFX001BladeInsideTransitionRegionIsRejected() throws {
        let project = try makeVideoTransitionPairProject(durationFrames: 4)
        // Incoming starts at 10; region is [10, 14). Blade at 12 is inside.
        let command = EditCommand.bladeClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID,
            atTime: try editTime(12),
            rightClipID: try VideoTransitionFixtureID.extraClip()
        )
        XCTAssertThrowsError(try EditReducer.apply(command, to: project)) { error in
            guard case EditReducerError.invalidEdit(let editError) = error else {
                return XCTFail("expected invalidEdit")
            }
            if case .bladeInsideVideoTransitionRegion = editError {
                return
            }
            XCTFail("expected bladeInsideVideoTransitionRegion, got \(editError)")
        }
    }

    func testFRFX001BladeOutsideRegionRedistributes() throws {
        let project = try makeVideoTransitionPairProject(durationFrames: 4)
        // Blade outgoing at frame 5 — outside any leading region on outgoing.
        let rightID = try VideoTransitionFixtureID.extraClip()
        let command = EditCommand.bladeClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            atTime: try editTime(5),
            rightClipID: rightID
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let left = try videoTransitionTrackClip(outgoingID, in: edited)
        let right = try videoTransitionTrackClip(rightID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        // Leading stays on left (nil here); trailing moves to right half.
        XCTAssertNil(left.trailingTransition)
        XCTAssertEqual(right.trailingTransition?.partnerClipID, incomingID)
        XCTAssertEqual(incoming.leadingTransition?.partnerClipID, rightID)
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
    }

    func testFRFX001SlipClampsTailHandle() throws {
        let project = try makeVideoTransitionPairProject()
        // Slip outgoing to source [228, 238) → 2-frame handle.
        let command = EditCommand.slipClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 228, durationFrames: 10)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertEqual(outgoing.trailingTransition?.duration, try editTime(2))
        XCTAssertEqual(incoming.leadingTransition?.duration, try editTime(2))
    }

    // MARK: - Slide

    func testFRFX001SlidePreservesPairsAtBothMovingCuts() throws {
        let extraID = try VideoTransitionFixtureID.extraClip()
        let project = try makeTripleTransitionProject(extraID: extraID)
        let command = EditCommand.slideClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID,
            timelineRange: try editRange(startFrame: 12, durationFrames: 10)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let first = try videoTransitionTrackClip(outgoingID, in: edited)
        let middle = try videoTransitionTrackClip(incomingID, in: edited)
        let last = try videoTransitionTrackClip(extraID, in: edited)
        try assertRange(first.timelineRange, startFrame: 0, durationFrames: 12)
        try assertRange(middle.timelineRange, startFrame: 12, durationFrames: 10)
        try assertRange(last.timelineRange, startFrame: 22, durationFrames: 8)
        XCTAssertEqual(first.trailingTransition?.duration, try editTime(4))
        XCTAssertEqual(middle.leadingTransition?.duration, try editTime(4))
        XCTAssertEqual(middle.trailingTransition?.duration, try editTime(4))
        XCTAssertEqual(last.leadingTransition?.duration, try editTime(4))
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
    }

    func testFRFX001SlideClampsEachPairIndependently() throws {
        // Sliding right to [17, 27) shrinks the last clip to 3 frames: second pair clamps
        // to 3 while the first pair keeps its full 4 frames.
        let extraID = try VideoTransitionFixtureID.extraClip()
        let project = try makeTripleTransitionProject(extraID: extraID)
        let command = EditCommand.slideClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID,
            timelineRange: try editRange(startFrame: 17, durationFrames: 10)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let first = try videoTransitionTrackClip(outgoingID, in: edited)
        let middle = try videoTransitionTrackClip(incomingID, in: edited)
        let last = try videoTransitionTrackClip(extraID, in: edited)
        XCTAssertEqual(first.trailingTransition?.duration, try editTime(4))
        XCTAssertEqual(middle.leadingTransition?.duration, try editTime(4))
        XCTAssertEqual(middle.trailingTransition?.duration, try editTime(3))
        XCTAssertEqual(last.leadingTransition?.duration, try editTime(3))
    }

    // MARK: - Trim (in place)

    func testFRFX001TrimPreservingAdjacencyClampsThePair() throws {
        let project = try makeVideoTransitionPairProject()
        let command = EditCommand.trimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID,
            sourceRange: try editRange(startFrame: 0, durationFrames: 3),
            timelineRange: try editRange(startFrame: 10, durationFrames: 3)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertEqual(outgoing.trailingTransition?.duration, try editTime(3))
        XCTAssertEqual(incoming.leadingTransition?.duration, try editTime(3))
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
    }

    func testFRFX001TrimBreakingAdjacencyRemovesThePair() throws {
        let project = try makeVideoTransitionPairProject()
        let command = EditCommand.trimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 0, durationFrames: 8),
            timelineRange: try editRange(startFrame: 0, durationFrames: 8)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertNil(outgoing.trailingTransition)
        XCTAssertNil(incoming.leadingTransition)
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
    }

    // MARK: - Move

    func testFRFX001MoveBreakingTheCutRemovesPairAndMirror() throws {
        let project = try makeVideoTransitionPairProject()
        let command = EditCommand.moveClip(
            sequenceID: sequenceID,
            sourceTrackID: trackID,
            clipID: outgoingID,
            destinationTrackID: trackID,
            timelineRange: try editRange(startFrame: 30, durationFrames: 10)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let moved = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertNil(moved.trailingTransition)
        XCTAssertNil(incoming.leadingTransition)
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
    }

    // MARK: - Set speed

    func testFRFX001SetClipSpeedClampsPairToTheRetimedDuration() throws {
        // Doubling the outgoing clip's speed halves it to 5 frames and ripples the
        // partner into abutment, so an 8-frame pair clamps to 5 on both records.
        let project = try makePairTransitionProject(durationFrames: 8)
        let command = EditCommand.setClipSpeed(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            speed: RationalValue(2)
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        try assertRange(outgoing.timelineRange, startFrame: 0, durationFrames: 5)
        try assertRange(incoming.timelineRange, startFrame: 5, durationFrames: 10)
        XCTAssertEqual(outgoing.trailingTransition?.duration, try editTime(5))
        XCTAssertEqual(incoming.leadingTransition?.duration, try editTime(5))
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
    }
}

// MARK: - Fixtures

extension VideoTransitionEditMatrixTests {
    private func makePairTransitionProject(durationFrames: Int64) throws -> Project {
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.trailingTransition = try makeTrailingTransition(
            partner: incomingID,
            durationFrames: durationFrames
        )
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.leadingTransition = try makeLeadingTransition(
            partner: outgoingID,
            durationFrames: durationFrames
        )
        return try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
    }

    /// Three abutting clips on `[0, 10)`, `[10, 20)`, `[20, 30)` with valid 4-frame pairs
    /// at both cuts.
    private func makeTripleTransitionProject(extraID: UUID) throws -> Project {
        var firstSpec = VideoTransitionClipSpec()
        firstSpec.trailingTransition = try makeTrailingTransition(partner: incomingID)
        var middleSpec = VideoTransitionClipSpec()
        middleSpec.timelineStartFrame = 10
        middleSpec.leadingTransition = try makeLeadingTransition(partner: outgoingID)
        middleSpec.trailingTransition = try makeTrailingTransition(partner: extraID)
        var lastSpec = VideoTransitionClipSpec()
        lastSpec.timelineStartFrame = 20
        lastSpec.leadingTransition = try makeLeadingTransition(partner: incomingID)
        return try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: firstSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: middleSpec)),
            .clip(try makeVideoTransitionClip(id: extraID, spec: lastSpec))
        ])
    }
}
