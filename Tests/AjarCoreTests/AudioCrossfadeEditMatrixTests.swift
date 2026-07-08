// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-AUD-002 / ADR-0015 §8 edit-command interaction matrix: blade redistributes and
/// mirror-updates; ripple trim / roll / slip / slide preserve the pair with the duration
/// clamped to the post-edit handle and clip durations (clamp-to-zero removes the pair);
/// lift and ripple delete remove pairs and clear mirrors with no automatic crossfade.
/// Every command keeps the project taxonomy-valid and is undo-exact.
final class AudioCrossfadeEditMatrixTests: XCTestCase {
    private var sequenceID = UUID()
    private var trackID = UUID()
    private var outgoingID = UUID()
    private var incomingID = UUID()
    private var extraID = UUID()
    private var bladeRightID = UUID()

    override func setUpWithError() throws {
        sequenceID = try CrossfadeFixtureID.sequence()
        trackID = try CrossfadeFixtureID.track()
        outgoingID = try CrossfadeFixtureID.outgoingClip()
        incomingID = try CrossfadeFixtureID.incomingClip()
        extraID = try CrossfadeFixtureID.extraClip()
        bladeRightID = try editUUID(900_010)
    }

    // MARK: - Blade

    func testFRAUD002BladeMovesTrailingRecordToRightHalfAndMirrorUpdates() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.bladeClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            atTime: try editTime(5),
            rightClipID: bladeRightID
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let left = try trackClip(outgoingID, in: edited)
        let right = try trackClip(bladeRightID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertNil(left.audioMix.trailingCrossfade)
        XCTAssertNil(left.audioMix.leadingCrossfade)
        XCTAssertEqual(
            right.audioMix.trailingCrossfade,
            ClipAudioCrossfade(
                partnerClipID: incomingID,
                duration: try editTime(4),
                curve: .linear
            )
        )
        // The new cut between the halves gets no automatic crossfade.
        XCTAssertNil(right.audioMix.leadingCrossfade)
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.partnerClipID, bladeRightID)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002BladeNearTheCutClampsTheRedistributedPair() throws {
        // The right half is only 2 frames long, shorter than the 4-frame pair, so both
        // records clamp to 2 frames per the §7/§8 clamp rule.
        let project = try makeCrossfadePairProject()
        let command = EditCommand.bladeClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            atTime: try editTime(8),
            rightClipID: bladeRightID
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let right = try trackClip(bladeRightID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertEqual(right.audioMix.trailingCrossfade?.duration, try editTime(2))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(2))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.partnerClipID, bladeRightID)
    }

    func testFRAUD002BladeInsideTransitionRegionIsRejectedTyped() throws {
        // The pair's region is [10, 14) inside the incoming clip; ADR-0015 does not define
        // blading inside it, so the edit is rejected with a typed error.
        let project = try makeCrossfadePairProject()
        let bladeTime = try editTime(12)

        XCTAssertThrowsError(
            try apply(
                .bladeClip(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: incomingID,
                    atTime: bladeTime,
                    rightClipID: bladeRightID
                ),
                to: project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .bladeInsideCrossfadeRegion(clipID: incomingID, atTime: bladeTime)
                )
            )
        }
    }

    func testFRAUD002BladeAtTransitionRegionEndKeepsLeadingRecordOnLeftHalf() throws {
        // The region [10, 14) is half-open, so blading exactly at 14 is allowed; the
        // leading record stays on the left half per the §8 blade row.
        let project = try makeCrossfadePairProject()
        let command = EditCommand.bladeClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: incomingID,
            atTime: try editTime(14),
            rightClipID: bladeRightID
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let leftHalf = try trackClip(incomingID, in: edited)
        let rightHalf = try trackClip(bladeRightID, in: edited)
        let outgoing = try trackClip(outgoingID, in: edited)
        XCTAssertEqual(leftHalf.audioMix.leadingCrossfade?.partnerClipID, outgoingID)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.partnerClipID, incomingID)
        XCTAssertNil(rightHalf.audioMix.leadingCrossfade)
        XCTAssertNil(rightHalf.audioMix.trailingCrossfade)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
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
}

// MARK: - Fixtures

extension AudioCrossfadeEditMatrixTests {
    /// A valid pair like `makeCrossfadePairProject`, but with a caller-chosen outgoing
    /// source start so tests can shape the remaining tail handle.
    private func makePairProject(outgoingSourceStartFrame: Int64) throws -> Project {
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.sourceStartFrame = outgoingSourceStartFrame
        outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID)
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID)
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
