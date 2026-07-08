// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-AUD-002 / ADR-0015 crossfade create/remove edit commands: one command writes the
/// owning trailing record plus the non-rendering mirror (§5), clamps the duration to the
/// available tail handle (§3/§7), auto-selects the curve (§4), and clears same-edge fades
/// (§6) — all in a single undoable, deterministic step.
final class AudioCrossfadeEditCommandTests: XCTestCase {
    // MARK: - Create

    func testFRAUD002CreateCrossfadeWritesOwningRecordAndMirror() throws {
        let fixture = try makeAdjacentPairFixture()
        let command = try createCommand(durationFrames: 4)

        let edited = try assertUndoRedoIdentity(project: fixture.project, command: command)

        let outgoing = try trackClip(fixture.outgoingID, in: edited)
        let incoming = try trackClip(fixture.incomingID, in: edited)
        XCTAssertEqual(
            outgoing.audioMix.trailingCrossfade,
            ClipAudioCrossfade(
                partnerClipID: fixture.incomingID,
                duration: try editTime(4),
                curve: .equalPower
            )
        )
        XCTAssertEqual(
            incoming.audioMix.leadingCrossfade,
            ClipAudioCrossfade(
                partnerClipID: fixture.outgoingID,
                duration: try editTime(4),
                curve: .equalPower
            )
        )
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002CreateCrossfadeAutoSelectsLinearForBladeSplitSignature() throws {
        // Same media, outgoing sourceRange.end == incoming sourceRange.start, identical
        // speed/reverse — the ADR-0015 §4 correlated blade-split signature.
        let fixture = try makeAdjacentPairFixture(incomingSourceStartFrame: 10)

        let edited = try apply(try createCommand(durationFrames: 4), to: fixture.project)

        let outgoing = try trackClip(fixture.outgoingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.curve, .linear)
    }

    func testFRAUD002CreateCrossfadeAutoSelectsEqualPowerForNonContiguousMappings() throws {
        // Contiguous source ranges but different constant rates: the mapping is not the
        // blade-split signature, so the uncorrelated default applies.
        let contiguousButRetimed = try makeAdjacentPairFixture(
            incomingSourceStartFrame: 10,
            incomingSpeed: RationalValue(2)
        )

        let edited = try apply(
            try createCommand(durationFrames: 4),
            to: contiguousButRetimed.project
        )

        let outgoing = try trackClip(contiguousButRetimed.outgoingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.curve, .equalPower)
    }

    func testFRAUD002CreateCrossfadeExplicitCurveOverrideWins() throws {
        // Blade-split signature would auto-select linear; the stored curve is the truth.
        let fixture = try makeAdjacentPairFixture(incomingSourceStartFrame: 10)

        let edited = try apply(
            try createCommand(durationFrames: 4, curve: .equalPower),
            to: fixture.project
        )

        let outgoing = try trackClip(fixture.outgoingID, in: edited)
        let incoming = try trackClip(fixture.incomingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.curve, .equalPower)
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.curve, .equalPower)
    }

    func testFRAUD002CreateCrossfadeClampsDurationToTailHandle() throws {
        // Media is 240 frames; outgoing source [224, 234) leaves a 6-frame tail handle,
        // so the requested 8 frames clamp to 6 on both records (ADR-0015 §3/§7).
        let fixture = try makeAdjacentPairFixture(outgoingSourceStartFrame: 224)

        let edited = try apply(try createCommand(durationFrames: 8), to: fixture.project)

        let outgoing = try trackClip(fixture.outgoingID, in: edited)
        let incoming = try trackClip(fixture.incomingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(6))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(6))
    }

    func testFRAUD002CreateCrossfadeClampsDurationToClipDurations() throws {
        let fixture = try makeAdjacentPairFixture()

        let edited = try apply(try createCommand(durationFrames: 15), to: fixture.project)

        let outgoing = try trackClip(fixture.outgoingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(10))
    }

    func testFRAUD002CreateCrossfadeWithZeroTailHandleFailsTyped() throws {
        // Outgoing source [230, 240) exhausts the declared media: clamping to zero is a
        // typed rejection, never a silent no-op (ADR-0015 §7).
        let fixture = try makeAdjacentPairFixture(outgoingSourceStartFrame: 230)

        XCTAssertThrowsError(
            try apply(try createCommand(durationFrames: 4), to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .invalidClipAudioCrossfade(
                        clipID: fixture.outgoingID,
                        error: .crossfadeExceedsSourceHandle(
                            edge: .trailingCrossfade,
                            clipID: fixture.outgoingID,
                            mediaID: fixture.mediaID
                        )
                    )
                )
            )
        }
    }

    func testFRAUD002CreateCrossfadeClearsSameEdgeFadesInTheSameUndoableCommand() throws {
        // ADR-0015 §6: the command clears the outgoing fade-out and incoming fade-in, so
        // crossfadeConflictsWithFade is unreachable through this command, and one undo
        // restores both fades and removes both records.
        let fadeOut = ClipAudioFade(duration: try editTime(3), curve: .easeOut)
        let fadeIn = ClipAudioFade(duration: try editTime(2), curve: .easeIn)
        let fixture = try makeAdjacentPairFixture(
            outgoingMix: ClipAudioMix(fadeOut: fadeOut),
            incomingMix: ClipAudioMix(fadeIn: fadeIn)
        )
        let command = try createCommand(durationFrames: 4)

        var history = EditHistory(project: fixture.project)
        let edited = try history.apply(command)

        let outgoing = try trackClip(fixture.outgoingID, in: edited)
        let incoming = try trackClip(fixture.incomingID, in: edited)
        XCTAssertEqual(outgoing.audioMix.fadeOut, .none)
        XCTAssertEqual(incoming.audioMix.fadeIn, .none)
        XCTAssertNotNil(outgoing.audioMix.trailingCrossfade)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)

        let undone = try XCTUnwrap(history.undo())
        XCTAssertEqual(undone, fixture.project)
        let restoredOutgoing = try trackClip(fixture.outgoingID, in: undone)
        let restoredIncoming = try trackClip(fixture.incomingID, in: undone)
        XCTAssertEqual(restoredOutgoing.audioMix.fadeOut, fadeOut)
        XCTAssertEqual(restoredIncoming.audioMix.fadeIn, fadeIn)
        XCTAssertNil(restoredOutgoing.audioMix.trailingCrossfade)
        XCTAssertEqual(try history.redo(), edited)
    }

    func testFRAUD002CreateCrossfadeUpdatesAnExistingPair() throws {
        let project = try makeCrossfadePairProject()

        let edited = try assertUndoRedoIdentity(
            project: project,
            command: try createCommand(durationFrames: 6, curve: .equalPower)
        )

        let outgoing = try trackClip(CrossfadeFixtureID.outgoingClip(), in: edited)
        let incoming = try trackClip(CrossfadeFixtureID.incomingClip(), in: edited)
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.duration, try editTime(6))
        XCTAssertEqual(outgoing.audioMix.trailingCrossfade?.curve, .equalPower)
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.duration, try editTime(6))
        XCTAssertEqual(incoming.audioMix.leadingCrossfade?.curve, .equalPower)
    }

    func testFRAUD002CreateCrossfadeRequiresAbuttingNextClip() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 12
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: CrossfadeClipSpec())),
            .gap(try editRange(startFrame: 10, durationFrames: 2)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertThrowsError(
            try apply(try createCommand(durationFrames: 4), to: project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.crossfadeRequiresAdjacentClips(clipID: outgoingID))
            )
        }

        // The last clip on the track has no next clip at all.
        XCTAssertThrowsError(
            try apply(
                .setClipAudioCrossfade(
                    sequenceID: try CrossfadeFixtureID.sequence(),
                    trackID: try CrossfadeFixtureID.track(),
                    clipID: incomingID,
                    duration: try editTime(4)
                ),
                to: project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.crossfadeRequiresAdjacentClips(clipID: incomingID))
            )
        }
    }

    func testFRAUD002CreateCrossfadeRequiresAudioTrack() throws {
        let fixture = try makeEditFixture(seed: 971)

        XCTAssertThrowsError(
            try apply(
                .setClipAudioCrossfade(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.clipID,
                    duration: try editTime(4)
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.crossfadeRequiresAudioTrack(clipID: fixture.clipID))
            )
        }
    }

    func testFRAUD002CreateCrossfadeRejectsTimeRemapClips() throws {
        // ADR-0015 §2: extrapolating a keyframed curve past its out-point is ambiguous.
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.timeRemap = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(0)),
            TimeRemapKeyframe(time: try editTime(10), sourceTime: try editTime(10))
        ])
        let fixture = try makeAdjacentPairFixture(outgoingSpec: outgoingSpec)

        XCTAssertThrowsError(
            try apply(try createCommand(durationFrames: 4), to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .invalidClipAudioCrossfade(
                        clipID: fixture.outgoingID,
                        error: .crossfadeUnsupportedWithTimeRemap(
                            edge: .trailingCrossfade,
                            clipID: fixture.outgoingID
                        )
                    )
                )
            )
        }
    }

    func testFRAUD002CreateCrossfadeRejectsFadeToSilenceCurves() throws {
        let fixture = try makeAdjacentPairFixture()

        XCTAssertThrowsError(
            try apply(try createCommand(durationFrames: 4, curve: .easeInOut), to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .invalidClipAudioCrossfade(
                        clipID: fixture.outgoingID,
                        error: .crossfadeCurveUnsupported(
                            edge: .trailingCrossfade,
                            clipID: fixture.outgoingID,
                            curve: .easeInOut
                        )
                    )
                )
            )
        }
    }

    func testFRAUD002CreateCrossfadeRejectsNonPositiveDuration() throws {
        let fixture = try makeAdjacentPairFixture()

        XCTAssertThrowsError(
            try apply(try createCommand(durationFrames: 0), to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.nonPositiveDuration(clipID: fixture.outgoingID))
            )
        }
    }

    // MARK: - Remove

    func testFRAUD002RemoveCrossfadeDeletesBothRecordsAtomically() throws {
        let project = try makeCrossfadePairProject()
        let command = EditCommand.removeClipAudioCrossfade(
            sequenceID: try CrossfadeFixtureID.sequence(),
            trackID: try CrossfadeFixtureID.track(),
            clipID: try CrossfadeFixtureID.outgoingClip()
        )

        let edited = try assertUndoRedoIdentity(project: project, command: command)

        let outgoing = try trackClip(CrossfadeFixtureID.outgoingClip(), in: edited)
        let incoming = try trackClip(CrossfadeFixtureID.incomingClip(), in: edited)
        XCTAssertNil(outgoing.audioMix.trailingCrossfade)
        XCTAssertNil(incoming.audioMix.leadingCrossfade)
        XCTAssertTrue(projectCrossfadeErrors(in: edited).isEmpty)
    }

    func testFRAUD002RemoveCrossfadeWithoutPairFailsTyped() throws {
        let fixture = try makeAdjacentPairFixture()

        XCTAssertThrowsError(
            try apply(
                .removeClipAudioCrossfade(
                    sequenceID: try CrossfadeFixtureID.sequence(),
                    trackID: try CrossfadeFixtureID.track(),
                    clipID: fixture.outgoingID
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.crossfadeNotFound(clipID: fixture.outgoingID))
            )
        }
    }
}

// MARK: - Fixtures

struct AdjacentPairFixture {
    let project: Project
    let outgoingID: UUID
    let incomingID: UUID
    let mediaID: UUID
}

/// Two abutting audio clips — outgoing on `[0, 10)`, incoming on `[10, 20)` — over the
/// shared 240-frame crossfade fixture media, with no crossfade records yet.
func makeAdjacentPairFixture(
    outgoingSourceStartFrame: Int64 = 0,
    incomingSourceStartFrame: Int64 = 0,
    incomingSpeed: RationalValue = .one,
    outgoingMix: ClipAudioMix = .identity,
    incomingMix: ClipAudioMix = .identity,
    outgoingSpec explicitOutgoingSpec: CrossfadeClipSpec? = nil
) throws -> AdjacentPairFixture {
    let outgoingID = try CrossfadeFixtureID.outgoingClip()
    let incomingID = try CrossfadeFixtureID.incomingClip()
    var outgoingSpec = explicitOutgoingSpec ?? CrossfadeClipSpec()
    outgoingSpec.sourceStartFrame = outgoingSourceStartFrame
    outgoingSpec.audioMix = outgoingMix
    var incomingSpec = CrossfadeClipSpec()
    incomingSpec.timelineStartFrame = 10
    incomingSpec.sourceStartFrame = incomingSourceStartFrame
    incomingSpec.speed = incomingSpeed
    incomingSpec.audioMix = incomingMix
    let project = try makeCrossfadeProject(items: [
        .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
        .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
    ])
    return AdjacentPairFixture(
        project: project,
        outgoingID: outgoingID,
        incomingID: incomingID,
        mediaID: try CrossfadeFixtureID.media()
    )
}

/// Crossfade-create command addressed at the fixture outgoing clip.
func createCommand(
    durationFrames: Int64,
    curve: ClipAudioFadeCurve? = nil
) throws -> EditCommand {
    .setClipAudioCrossfade(
        sequenceID: try CrossfadeFixtureID.sequence(),
        trackID: try CrossfadeFixtureID.track(),
        clipID: try CrossfadeFixtureID.outgoingClip(),
        duration: try editTime(durationFrames),
        curve: curve
    )
}

/// Fetches a clip from the shared crossfade fixture track.
func trackClip(_ clipID: @autoclosure () throws -> UUID, in project: Project) throws -> Clip {
    try XCTUnwrap(
        clip(
            try clipID(),
            in: try projectTrack(
                CrossfadeFixtureID.track(),
                in: project,
                sequenceID: CrossfadeFixtureID.sequence()
            )
        )
    )
}

/// Applies `command` through `EditHistory` and asserts undo restores the exact before
/// project and redo replays to the exact after project (FR-TL-012 determinism).
@discardableResult
func assertUndoRedoIdentity(
    project: Project,
    command: EditCommand,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Project {
    var history = EditHistory(project: project)
    let after = try history.apply(command)
    XCTAssertEqual(history.undo(), project, "undo must restore the exact prior project",
        file: file, line: line)
    XCTAssertEqual(try history.redo(), after, "redo must replay to the exact after project",
        file: file, line: line)
    return after
}
