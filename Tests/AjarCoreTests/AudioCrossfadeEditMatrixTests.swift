// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-AUD-002 / ADR-0015 §8 edit-command interaction matrix (see
/// `AudioCrossfadeBladeEditTests` for the blade row): ripple trim / roll / slip / slide /
/// trim / set-speed preserve the pair with the duration clamped to the post-edit handle
/// and clip durations (clamp-to-zero removes the pair); lift, ripple delete, and
/// adjacency-breaking trims/moves remove pairs and clear mirrors with no automatic
/// crossfade. Every command keeps the project taxonomy-valid and is undo-exact.
final class AudioCrossfadeEditMatrixTests: XCTestCase {
    private var sequenceID = UUID()
    private var trackID = UUID()
    private var outgoingID = UUID()
    private var incomingID = UUID()
    private var extraID = UUID()

    override func setUpWithError() throws {
        sequenceID = try CrossfadeFixtureID.sequence()
        trackID = try CrossfadeFixtureID.track()
        outgoingID = try CrossfadeFixtureID.outgoingClip()
        incomingID = try CrossfadeFixtureID.incomingClip()
        extraID = try CrossfadeFixtureID.extraClip()
    }

    // MARK: - Ripple trim

    func testFRAUD002RippleTrimPreservesPairAndRipplesPartner() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.rippleTrimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 0, durationFrames: 8),
            timelineRange: try editRange(startFrame: 0, durationFrames: 8)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        try assertRange(incoming.timelineRange, startFrame: 8, durationFrames: 10)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(4))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(4))
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002RippleTrimClampsPairToPostTrimClipDuration() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.rippleTrimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 0, durationFrames: 3),
            timelineRange: try editRange(startFrame: 0, durationFrames: 3)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(3))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(3))
    }

    func testFRAUD002RippleTrimClampToZeroHandleRemovesThePair() throws {
        // Outgoing source [226, 236) leaves a 4-frame handle for the 4-frame pair;
        // extending the trim to the declared media end [226, 240) exhausts the handle,
        // which removes the pair rather than leaving an invalid record (§7/§8).
        let project = try makePairProject(outgoingSourceStartFrame: 226)
        let command = EditCommand.rippleTrimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 226, durationFrames: 14),
            timelineRange: try editRange(startFrame: 0, durationFrames: 14)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertNil(outgoing.audioMix.trailingCrossfade)
        XCTAssertNil(incoming.audioMix.leadingCrossfade)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    // MARK: - Roll

    func testFRAUD002RollPreservesPairAcrossTheMovedCut() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.rollEdit(
            sequenceID: sequenceID,
            trackID: trackID,
            leftClipID: outgoingID,
            rightClipID: incomingID,
            editTime: try editTime(12)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        try assertRange(outgoing.timelineRange, startFrame: 0, durationFrames: 12)
        try assertRange(incoming.timelineRange, startFrame: 12, durationFrames: 8)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(4))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(4))
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002RollClampsPairToTheShrunkenIncomingClip() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.rollEdit(
            sequenceID: sequenceID,
            trackID: trackID,
            leftClipID: outgoingID,
            rightClipID: incomingID,
            editTime: try editTime(17)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(3))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(3))
    }

    // MARK: - Slip

    func testFRAUD002SlipClampsPairToTheSlippedTailHandle() throws {
        // Slipping the outgoing clip to source [228, 238) leaves a 2-frame handle before
        // the declared 240-frame media end, so the 4-frame pair clamps to 2.
        let project = try makeCrossfadePairProject()
        let command = EditCommand.slipClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 228, durationFrames: 10)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(2))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(2))
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002SlipToZeroTailHandleRemovesThePair() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.slipClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 230, durationFrames: 10)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertNil(outgoing.audioMix.trailingCrossfade)
        XCTAssertNil(incoming.audioMix.leadingCrossfade)
    }

    func testFRAUD002SlipWithRemainingHandlePreservesThePairUnchanged() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.slipClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 100, durationFrames: 10)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(4))
    }

    // MARK: - Slide

    func testFRAUD002SlidePreservesPairsAtBothMovingCuts() throws {
        let project = try makeTripleProject()
        let command = EditCommand.slideClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID,
            timelineRange: try editRange(startFrame: 12, durationFrames: 10)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let first = try trackClip(outgoingID, in: edited)
        let middle = try trackClip(incomingID, in: edited)
        let last = try trackClip(extraID, in: edited)
        try assertRange(first.timelineRange, startFrame: 0, durationFrames: 12)
        try assertRange(middle.timelineRange, startFrame: 12, durationFrames: 10)
        try assertRange(last.timelineRange, startFrame: 22, durationFrames: 8)
        XCTAssertEqual(first.audioMix.trailingCrossfade?.duration, try editTime(4))
        XCTAssertEqual(middle.audioMix.leadingCrossfade?.duration, try editTime(4))
        XCTAssertEqual(middle.audioMix.trailingCrossfade?.duration, try editTime(4))
        XCTAssertEqual(last.audioMix.leadingCrossfade?.duration, try editTime(4))
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002SlideClampsEachPairIndependently() throws {
        // Sliding right to [17, 27) shrinks the last clip to 3 frames: the second pair
        // clamps to 3 while the first pair keeps its full 4 frames.
        let project = try makeTripleProject()
        let command = EditCommand.slideClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID,
            timelineRange: try editRange(startFrame: 17, durationFrames: 10)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let first = try trackClip(outgoingID, in: edited)
        let middle = try trackClip(incomingID, in: edited)
        let last = try trackClip(extraID, in: edited)
        XCTAssertEqual(first.audioMix.trailingCrossfade?.duration, try editTime(4))
        XCTAssertEqual(middle.audioMix.leadingCrossfade?.duration, try editTime(4))
        XCTAssertEqual(middle.audioMix.trailingCrossfade?.duration, try editTime(3))
        XCTAssertEqual(last.audioMix.leadingCrossfade?.duration, try editTime(3))
    }

    // MARK: - Lift

    func testFRAUD002LiftRemovesPairsAndClearsNeighborMirrors() throws {
        let project = try makeTripleProject()
        let command = EditCommand.liftClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let first = try trackClip(outgoingID, in: edited)
        let last = try trackClip(extraID, in: edited)
        XCTAssertNil(first.audioMix.trailingCrossfade)
        XCTAssertNil(last.audioMix.leadingCrossfade)
        let track = try projectTrack(trackID, in: edited, sequenceID: sequenceID)
        XCTAssertEqual(
            track.items[1],
            .gap(try editRange(startFrame: 10, durationFrames: 10))
        )
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    // MARK: - Ripple delete

    func testFRAUD002RippleDeleteRemovesPairsAndAddsNoAutomaticCrossfade() throws {
        let project = try makeTripleProject()
        let command = EditCommand.rippleDeleteClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let first = try trackClip(outgoingID, in: edited)
        let last = try trackClip(extraID, in: edited)
        // The neighbors abut again, but the new cut gets no automatic crossfade.
        try assertRange(first.timelineRange, startFrame: 0, durationFrames: 10)
        try assertRange(last.timelineRange, startFrame: 10, durationFrames: 10)
        XCTAssertNil(first.audioMix.trailingCrossfade)
        XCTAssertNil(first.audioMix.leadingCrossfade)
        XCTAssertNil(last.audioMix.leadingCrossfade)
        XCTAssertNil(last.audioMix.trailingCrossfade)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    // MARK: - Trim (in place)

    func testFRAUD002TrimPreservingAdjacencyClampsThePair() throws {
        // Trimming the incoming clip's end keeps the cut abutting, so the pair is
        // preserved with its duration clamped to the shrunken clip.
        let project = try makeCrossfadePairProject()
        let command = EditCommand.trimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID,
            sourceRange: try editRange(startFrame: 0, durationFrames: 3),
            timelineRange: try editRange(startFrame: 10, durationFrames: 3)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(3))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(3))
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002TrimBreakingAdjacencyRemovesThePair() throws {
        // Trimming the outgoing clip's end opens a gap before the partner: the pair is
        // removed and the mirror cleared rather than failing validation loudly.
        let project = try makeCrossfadePairProject()
        let command = EditCommand.trimClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            sourceRange: try editRange(startFrame: 0, durationFrames: 8),
            timelineRange: try editRange(startFrame: 0, durationFrames: 8)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertNil(outgoing.audioMix.trailingCrossfade)
        XCTAssertNil(incoming.audioMix.leadingCrossfade)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    // MARK: - Move

    func testFRAUD002MoveBreakingTheCutRemovesPairAndMirror() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.moveClip(
            sequenceID: sequenceID,
            sourceTrackID: trackID,
            clipID: outgoingID,
            destinationTrackID: trackID,
            timelineRange: try editRange(startFrame: 30, durationFrames: 10)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let moved = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertNil(moved.audioMix.trailingCrossfade)
        XCTAssertNil(incoming.audioMix.leadingCrossfade)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    // MARK: - Set speed

    func testFRAUD002SetClipSpeedClampsPairToTheRetimedDuration() throws {
        // Doubling the outgoing clip's speed halves it to 5 frames and ripples the
        // partner into abutment, so the 8-frame pair clamps to 5 on both records.
        let project = try makePairProject(durationFrames: 8)
        let command = EditCommand.setClipSpeed(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            speed: RationalValue(2)
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(outgoingID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        try assertRange(outgoing.timelineRange, startFrame: 0, durationFrames: 5)
        try assertRange(incoming.timelineRange, startFrame: 5, durationFrames: 10)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(5))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(5))
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

}

// MARK: - Fixtures

extension AudioCrossfadeEditMatrixTests {
    /// A valid pair like `makeCrossfadePairProject`, but with a caller-chosen outgoing
    /// source start and pair duration so tests can shape the tail handle and clamps.
    private func makePairProject(
        outgoingSourceStartFrame: Int64 = 0,
        durationFrames: Int64 = 4
    ) throws -> Project {
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.sourceStartFrame = outgoingSourceStartFrame
        outgoingSpec.audioMix = try outgoingCrossfadeMix(
            partner: incomingID,
            durationFrames: durationFrames
        )
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.audioMix = try incomingCrossfadeMix(
            partner: outgoingID,
            durationFrames: durationFrames
        )
        return try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])
    }

    /// Three abutting clips on `[0, 10)`, `[10, 20)`, `[20, 30)` with valid 4-frame pairs
    /// at both cuts, per the ADR-0015 §5 taxonomy.
    private func makeTripleProject() throws -> Project {
        var firstSpec = CrossfadeClipSpec()
        firstSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID)
        var middleSpec = CrossfadeClipSpec()
        middleSpec.timelineStartFrame = 10
        middleSpec.audioMix = ClipAudioMix(
            leadingCrossfade: ClipAudioCrossfade(
                partnerClipID: outgoingID,
                duration: try editTime(4),
                curve: .linear
            ),
            trailingCrossfade: ClipAudioCrossfade(
                partnerClipID: extraID,
                duration: try editTime(4),
                curve: .linear
            )
        )
        var lastSpec = CrossfadeClipSpec()
        lastSpec.timelineStartFrame = 20
        lastSpec.audioMix = try incomingCrossfadeMix(partner: incomingID)
        return try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: firstSpec)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: middleSpec)),
            .clip(try makeCrossfadeClip(id: extraID, spec: lastSpec))
        ])
    }
}
