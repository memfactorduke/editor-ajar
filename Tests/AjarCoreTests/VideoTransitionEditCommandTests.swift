// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-FX-001 create/remove/adjust transition commands (undoable, typed errors).
final class VideoTransitionEditCommandTests: XCTestCase {
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

    func testFRFX001CreateWritesOwningRecordAndMirror() throws {
        let project = try adjacentPairWithoutTransition()
        let command = EditCommand.setClipVideoTransition(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            duration: try editTime(4),
            kind: .crossDissolve
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertEqual(outgoing.trailingTransition?.partnerClipID, incomingID)
        XCTAssertEqual(incoming.leadingTransition?.partnerClipID, outgoingID)
        XCTAssertEqual(outgoing.trailingTransition?.duration, try editTime(4))
        XCTAssertEqual(incoming.leadingTransition?.duration, try editTime(4))
        XCTAssertEqual(outgoing.trailingTransition?.kind, .crossDissolve)
        XCTAssertTrue(projectVideoTransitionErrors(in: edited).isEmpty)
        // Sequence duration unchanged.
        XCTAssertEqual(
            try sequenceDuration(edited),
            try sequenceDuration(project)
        )
    }

    func testFRFX001CreateClampsDurationToHandle() throws {
        // Source starts at 230 → end 240 with media 240 → 0 handle for any positive D.
        // Clamp-to-zero is a typed rejection.
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.sourceStartFrame = 230
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let command = EditCommand.setClipVideoTransition(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            duration: try editTime(4),
            kind: .wipe,
            direction: .topLeft
        )
        XCTAssertThrowsError(try EditReducer.apply(command, to: project)) { error in
            guard case EditReducerError.invalidEdit(let editError) = error else {
                return XCTFail("expected invalidEdit, got \(error)")
            }
            if case .invalidClipVideoTransition(_, let transitionError) = editError {
                if case .transitionExceedsSourceHandle = transitionError {
                    return
                }
            }
            XCTFail("expected transitionExceedsSourceHandle, got \(editError)")
        }
    }

    func testFRFX001CreateClampsToAvailableHandle() throws {
        // Source [226, 236) → 4-frame handle before media end 240; request 8 → clamp to 4.
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.sourceStartFrame = 226
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let command = EditCommand.setClipVideoTransition(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            duration: try editTime(8),
            kind: .push,
            direction: .right
        )
        let edited = try EditReducer.apply(command, to: project)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        XCTAssertEqual(outgoing.trailingTransition?.duration, try editTime(4))
    }

    func testFRFX001RemoveClearsBothRecords() throws {
        let project = try makeVideoTransitionPairProject()
        let command = EditCommand.removeClipVideoTransition(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        let incoming = try videoTransitionTrackClip(incomingID, in: edited)
        XCTAssertNil(outgoing.trailingTransition)
        XCTAssertNil(incoming.leadingTransition)
        XCTAssertEqual(try sequenceDuration(edited), try sequenceDuration(project))
    }

    func testFRFX001AdjustKindKeepsDuration() throws {
        let project = try makeVideoTransitionPairProject(kind: .crossDissolve)
        let command = EditCommand.setClipVideoTransition(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            duration: try editTime(4),
            kind: .zoom
        )
        let edited = try assertUndoRedoIdentity(project: project, command: command)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        XCTAssertEqual(outgoing.trailingTransition?.kind, .zoom)
        XCTAssertEqual(outgoing.trailingTransition?.duration, try editTime(4))
    }

    func testFRFX001RequiresAdjacentClips() throws {
        var outgoingSpec = VideoTransitionClipSpec()
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec))
        ])
        let command = EditCommand.setClipVideoTransition(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            duration: try editTime(4),
            kind: .fade
        )
        XCTAssertThrowsError(try EditReducer.apply(command, to: project)) { error in
            guard case EditReducerError.invalidEdit(let editError) = error else {
                return XCTFail("expected invalidEdit")
            }
            if case .videoTransitionRequiresAdjacentClips = editError {
                return
            }
            XCTFail("expected videoTransitionRequiresAdjacentClips, got \(editError)")
        }
    }

    func testFRFX001IndependentOfAudioCrossfade() throws {
        // Video transition alone; no audio records created.
        let project = try adjacentPairWithoutTransition()
        let command = EditCommand.setClipVideoTransition(
            sequenceID: sequenceID,
            trackID: trackID,
            clipID: outgoingID,
            duration: try editTime(4),
            kind: .crossDissolve
        )
        let edited = try EditReducer.apply(command, to: project)
        let outgoing = try videoTransitionTrackClip(outgoingID, in: edited)
        XCTAssertNotNil(outgoing.trailingTransition)
        XCTAssertNil(outgoing.audioMix.trailingCrossfade)
        XCTAssertNil(outgoing.audioMix.leadingCrossfade)
    }

    private func adjacentPairWithoutTransition() throws -> Project {
        var outgoingSpec = VideoTransitionClipSpec()
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        return try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
    }

    private func sequenceDuration(_ project: Project) throws -> RationalTime {
        let track = try XCTUnwrap(project.sequences.first?.videoTracks.first)
        var end = RationalTime.zero
        for item in track.items {
            let itemEnd = try item.timelineRange.end()
            if itemEnd > end {
                end = itemEnd
            }
        }
        return end
    }
}
