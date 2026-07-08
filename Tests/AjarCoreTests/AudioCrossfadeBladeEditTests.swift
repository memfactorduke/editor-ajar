// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-AUD-002 / ADR-0015 §8 blade row: the leading crossfade record stays on the left
/// half, the trailing record moves to the right half with the partner mirror
/// re-pointed, the new cut gets no automatic crossfade, blading inside an active
/// transition region is rejected typed, and non-crossfade clip attributes are
/// preserved on both halves — including reversed clips, whose redistributed pair still
/// clamps against the reversed tail handle past `sourceRange.start` (FR-SPD-003).
final class AudioCrossfadeBladeEditTests: XCTestCase {
    private var sequenceID = UUID()
    private var trackID = UUID()
    private var outgoingID = UUID()
    private var incomingID = UUID()
    private var bladeRightID = UUID()

    override func setUpWithError() throws {
        sequenceID = try CrossfadeFixtureID.sequence()
        trackID = try CrossfadeFixtureID.track()
        outgoingID = try CrossfadeFixtureID.outgoingClip()
        incomingID = try CrossfadeFixtureID.incomingClip()
        bladeRightID = try editUUID(900_010)
    }

    // MARK: - Redistribution and mirror updates

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

    // MARK: - Blade attribute preservation and retime limits

    func testFRAUD002BladePreservesAttributesOnBothHalves() throws {
        let fixture = try makeEditFixture(seed: 973)
        let transform = ClipTransform(
            position: CanvasPoint(x: RationalValue(10), y: RationalValue(20))
        )
        let effects = ClipEffects(
            colorCorrection: ClipColorCorrection(
                saturation: try RationalValue(numerator: 1, denominator: 2)
            )
        )
        let audioMix = ClipAudioMix(
            gain: .constant(RationalValue(2)),
            pan: .constant(try RationalValue(numerator: 1, denominator: 4)),
            fadeIn: ClipAudioFade(duration: try editTime(2), curve: .easeIn),
            fadeOut: ClipAudioFade(duration: try editTime(3), curve: .easeOut)
        )
        let attributedClip = try makeEditClip(
            id: fixture.clipID,
            mediaID: fixture.mediaID,
            startFrame: 0,
            transform: transform,
            effects: effects,
            audioMix: audioMix
        )
        let project = try replacingVideoItems([.clip(attributedClip)], in: fixture)
        let command = EditCommand.bladeClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.clipID,
            atTime: try editTime(5),
            rightClipID: bladeRightID
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let track = try projectTrack(fixture.videoTrackID, in: edited)
        let left = try XCTUnwrap(clip(fixture.clipID, in: track))
        let right = try XCTUnwrap(clip(bladeRightID, in: track))
        for half in [left, right] {
            XCTAssertEqual(half.transform, transform)
            XCTAssertEqual(half.effects, effects)
            XCTAssertEqual(half.audioMix.gain, audioMix.gain)
            XCTAssertEqual(half.audioMix.pan, audioMix.pan)
        }
        // Edge metadata splits by edge: fade-in stays on the left half, fade-out moves
        // to the right half — never both on one edge of the new cut.
        XCTAssertEqual(left.audioMix.fadeIn, audioMix.fadeIn)
        XCTAssertEqual(left.audioMix.fadeOut, .none)
        XCTAssertEqual(right.audioMix.fadeIn, .none)
        XCTAssertEqual(right.audioMix.fadeOut, audioMix.fadeOut)
    }

    func testFRSPD003BladeReversedClipRedistributesPairAndKeepsReversedTailHandle() throws {
        // Reversed outgoing clip on [0, 10) with source [3, 13) and a 3-frame trailing
        // pair — exactly the reversed tail handle `sourceRange.start` = 3 that keeps
        // reading backward past the source start (ADR-0015 §3). Blading at 5 gives the
        // left half the source TAIL [8, 13) and the right half [3, 8): the right half's
        // source start is unchanged, so the redistributed pair keeps its full duration.
        let fixture = try makeAdjacentPairFixture(
            outgoingSourceStartFrame: 3,
            reverse: true,
            outgoingMix: try outgoingCrossfadeMix(partner: incomingID, durationFrames: 3),
            incomingMix: try incomingCrossfadeMix(partner: outgoingID, durationFrames: 3)
        )
        let command = EditCommand.bladeClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            atTime: try editTime(5),
            rightClipID: bladeRightID
        )

        let edited = try assertUndoRedoIdentity(project: fixture.project, command: command)

        let left = try trackClip(outgoingID, in: edited)
        let right = try trackClip(bladeRightID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertEqual(left.sourceRange, try editRange(startFrame: 8, durationFrames: 5))
        XCTAssertEqual(right.sourceRange, try editRange(startFrame: 3, durationFrames: 5))
        XCTAssertNil(left.audioMix.trailingCrossfade)
        XCTAssertEqual(
            right.audioMix.trailingCrossfade,
            ClipAudioCrossfade(
                partnerClipID: incomingID,
                duration: try editTime(3),
                curve: .linear
            )
        )
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.partnerClipID, bladeRightID)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRSPD003BladeReversedClipNearTheCutClampsPairToRightHalfDuration() throws {
        // Blading at 8 leaves a 2-frame reversed right half, shorter than the 3-frame
        // pair; the §7/§8 clamp shortens both records to 2 while the reversed tail handle
        // (still `sourceRange.start` = 3 on the right half) stays sufficient.
        let fixture = try makeAdjacentPairFixture(
            outgoingSourceStartFrame: 3,
            reverse: true,
            outgoingMix: try outgoingCrossfadeMix(partner: incomingID, durationFrames: 3),
            incomingMix: try incomingCrossfadeMix(partner: outgoingID, durationFrames: 3)
        )
        let command = EditCommand.bladeClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            atTime: try editTime(8),
            rightClipID: bladeRightID
        )

        let edited = try assertUndoRedoIdentity(project: fixture.project, command: command)

        let right = try trackClip(bladeRightID, in: edited)
        let incoming = try trackClip(incomingID, in: edited)
        XCTAssertEqual(right.sourceRange, try editRange(startFrame: 3, durationFrames: 2))
        XCTAssertEqual(right.audioMix.trailingCrossfade?.duration, try editTime(2))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(2))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.partnerClipID, bladeRightID)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002BladeFreezeFrameKeepsTheSameHeldFrameOnBothHalves() throws {
        var freezeSpec = CrossfadeClipSpec()
        freezeSpec.freezeFrame = true
        let fixture = try makeAdjacentPairFixture(
            outgoingSourceStartFrame: 6,
            outgoingSpec: freezeSpec
        )
        let command = EditCommand.bladeClip(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            atTime: try editTime(5),
            rightClipID: bladeRightID
        )

        let edited = try assertUndoRedoIdentity(project: fixture.project, command: command)

        let left = try trackClip(outgoingID, in: edited)
        let right = try trackClip(bladeRightID, in: edited)
        XCTAssertTrue(left.freezeFrame)
        XCTAssertTrue(right.freezeFrame)
        // Both halves hold the frame at the original source start.
        XCTAssertEqual(left.sourceRange.start, try editTime(6))
        XCTAssertEqual(right.sourceRange.start, try editTime(6))
    }
}
