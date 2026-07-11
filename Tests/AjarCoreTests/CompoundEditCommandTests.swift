// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// `EditCommand.transaction` groups several engine commands into one atomic, journal-persisted
/// undo step (FR-TL-004 / FR-TL-005 / FR-TL-009 / #240, schemaMinor 14 per ADR-0018).
final class CompoundEditCommandTests: XCTestCase {
    // MARK: - One gesture is one undo step, with undo symmetry

    func testIssue240TransactionAppliesAsSingleUndoStepWithUndoSymmetry() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_400)
        let transaction = try linkedBladeTransaction(fixture: fixture, cutFrame: 5)

        var history = EditHistory(project: fixture.project)
        XCTAssertEqual(history.undoCount, 0)

        let after = try history.apply(transaction)

        // A linked A/V blade splits both tracks, yet advances undo by exactly one step.
        XCTAssertEqual(history.undoCount, 1)
        let videoTrack = try projectTrack(
            fixture.videoTrackID, in: after, sequenceID: fixture.sequenceID
        )
        let audioTrack = try projectTrack(
            fixture.audioTrackID, in: after, sequenceID: fixture.sequenceID
        )
        XCTAssertEqual(videoTrack.items.count, 2)
        XCTAssertEqual(audioTrack.items.count, 2)

        // One undo returns the exact prior project.
        let undone = try XCTUnwrap(history.undo())
        XCTAssertEqual(undone, fixture.project)
        XCTAssertEqual(history.undoCount, 0)
    }

    // MARK: - Atomic refusal on a typed sub-command error

    func testIssue240TransactionRefusesAtomicallyWhenASubCommandThrows() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_401)
        let validBlade = EditCommand.bladeClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clipID: fixture.videoClipID,
            atTime: try editTime(5),
            rightClipID: try editUUID(7_401_101)
        )
        // Second sub-command references a clip that does not exist: a typed reducer error.
        let invalidBlade = EditCommand.bladeClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.audioTrackID,
            clipID: try editUUID(7_401_999),
            atTime: try editTime(5),
            rightClipID: try editUUID(7_401_102)
        )

        var history = EditHistory(project: fixture.project)
        XCTAssertThrowsError(
            try history.apply(.transaction([validBlade, invalidBlade]))
        )
        // The whole gesture is rolled back: no partial split, no undo entry.
        XCTAssertEqual(history.currentProject, fixture.project)
        XCTAssertEqual(history.undoCount, 0)
    }

    func testIssue240TransactionRefusesWhenResultOverlaps() throws {
        // Two moves that both target frame 0 overlap; central validation rejects the whole gesture.
        let fixture = try twoClipVideoFixture(seed: 7_402)
        let move = EditCommand.transaction([
            .moveClip(
                sequenceID: fixture.sequenceID,
                sourceTrackID: fixture.videoTrackID,
                clipID: fixture.firstClipID,
                destinationTrackID: fixture.videoTrackID,
                timelineRange: try editRange(startFrame: 0, durationFrames: 10),
                linkedClipEditMode: .unlinked
            ),
            .moveClip(
                sequenceID: fixture.sequenceID,
                sourceTrackID: fixture.videoTrackID,
                clipID: fixture.secondClipID,
                destinationTrackID: fixture.videoTrackID,
                timelineRange: try editRange(startFrame: 0, durationFrames: 10),
                linkedClipEditMode: .unlinked
            )
        ])

        var history = EditHistory(project: fixture.project)
        XCTAssertThrowsError(try history.apply(move))
        XCTAssertEqual(history.currentProject, fixture.project)
    }

    // MARK: - Deterministic replay and redo

    func testIssue240TransactionReplayIsDeterministicAndRedoReproducesResult() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_403)
        let transaction = try linkedBladeTransaction(fixture: fixture, cutFrame: 4)

        let firstApply = try apply(transaction, to: fixture.project)
        let secondApply = try apply(transaction, to: fixture.project)
        XCTAssertEqual(firstApply, secondApply)

        var history = EditHistory(project: fixture.project)
        let after = try history.apply(transaction)
        XCTAssertEqual(after, firstApply)
        _ = history.undo()
        let redone = try XCTUnwrap(try history.redo())
        XCTAssertEqual(redone, after)
    }

    // MARK: - Journal persistence and decode-walk (ADR-0018)

    func testIssue240TransactionJournalEntryRecoversToSameProject() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_404)
        let transaction = try linkedBladeTransaction(fixture: fixture, cutFrame: 5)
        let after = try apply(transaction, to: fixture.project)

        let snapshot = AjarAutosaveSnapshot(
            package: try AjarProjectCodec.encodeNewDocument(fixture.project),
            appliedCommandCount: 0
        )
        let journalData = try AjarAutosaveJournalCodec.encode([
            AjarAutosaveJournalEntry(sequenceNumber: 1, command: transaction)
        ])

        let recovered = try AjarAutosaveStore.recover(
            snapshot: snapshot,
            journalData: journalData
        )
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.appliedJournalEntryCount, 1)
        XCTAssertEqual(recovered.latestCommandCount, 1)
        XCTAssertEqual(recovered.project, after)
    }

    /// Decode-walk: the command round-trips through `Codable` unchanged, including nested commands.
    func testIssue240TransactionCommandRoundTripsThroughCodable() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_405)
        let transaction = try linkedBladeTransaction(fixture: fixture, cutFrame: 6)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transaction)
        let decoded = try JSONDecoder().decode(EditCommand.self, from: data)
        XCTAssertEqual(decoded, transaction)
    }

    /// Nested-legacy: a journal that mixes a pre-transaction plain command with a transaction
    /// recovers identically to sequential `EditHistory` application.
    func testIssue240MixedLegacyAndTransactionJournalRecoversConsistently() throws {
        let fixture = try makeLinkedEditFixture(seed: 7_406)
        let legacy = EditCommand.renameSequence(
            sequenceID: fixture.sequenceID, name: "Renamed"
        )
        let transaction = try linkedBladeTransaction(fixture: fixture, cutFrame: 5)

        var history = EditHistory(project: fixture.project)
        try history.apply(legacy)
        try history.apply(transaction)

        let snapshot = AjarAutosaveSnapshot(
            package: try AjarProjectCodec.encodeNewDocument(fixture.project),
            appliedCommandCount: 0
        )
        let journalData = try AjarAutosaveJournalCodec.encode([
            AjarAutosaveJournalEntry(sequenceNumber: 1, command: legacy),
            AjarAutosaveJournalEntry(sequenceNumber: 2, command: transaction)
        ])
        let recovered = try AjarAutosaveStore.recover(
            snapshot: snapshot,
            journalData: journalData
        )
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.appliedJournalEntryCount, 2)
        XCTAssertEqual(recovered.project, history.currentProject)
    }

    // MARK: - Undo-menu action name

    func testIssue240TransactionActionNameIsSharedNameOrGenericLabel() throws {
        let fixture = try twoClipVideoFixture(seed: 7_407)
        let uniform = EditCommand.transaction([
            .rippleDeleteClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.firstClipID
            ),
            .rippleDeleteClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.secondClipID
            )
        ])
        XCTAssertEqual(uniform.actionName, "Ripple Delete")

        let mixed = EditCommand.transaction([
            .liftClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.firstClipID
            ),
            .rippleDeleteClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.secondClipID
            )
        ])
        XCTAssertEqual(mixed.actionName, "Multiple Edits")
        XCTAssertEqual(EditCommand.transaction([]).actionName, "Multiple Edits")

        // FR-TXT-001 occupied-track insert: [addTrack, insertTitleClip] is one user gesture.
        let title = try makeSampleTitle(seed: 7_408)
        let titleInsertScaffold = EditCommand.transaction([
            .addTrack(
                sequenceID: fixture.sequenceID,
                track: Track(id: try editUUID(9_001), kind: .video, items: [])
            ),
            .insertTitleClip(
                sequenceID: fixture.sequenceID,
                trackID: try editUUID(9_002),
                clipID: try editUUID(9_003),
                title: title,
                timelineRange: try editRange(startFrame: 0, durationFrames: 12),
                name: "Title"
            )
        ])
        XCTAssertEqual(titleInsertScaffold.actionName, "Insert Title")
    }

    // MARK: - Fixtures

    private func linkedBladeTransaction(
        fixture: LinkedEditFixture,
        cutFrame: Int64
    ) throws -> EditCommand {
        .transaction([
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID,
                atTime: try editTime(cutFrame),
                rightClipID: try editUUID(Int(cutFrame) * 10 + 1)
            ),
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                atTime: try editTime(cutFrame),
                rightClipID: try editUUID(Int(cutFrame) * 10 + 2)
            )
        ])
    }

    private struct TwoClipVideoFixture {
        let project: Project
        let sequenceID: UUID
        let videoTrackID: UUID
        let firstClipID: UUID
        let secondClipID: UUID
    }

    private func twoClipVideoFixture(seed: Int) throws -> TwoClipVideoFixture {
        let base = seed * 1_000
        let mediaID = try editUUID(base + 1)
        let sequenceID = try editUUID(base + 2)
        let videoTrackID = try editUUID(base + 3)
        let firstClipID = try editUUID(base + 4)
        let secondClipID = try editUUID(base + 5)
        let media = try makeEditMediaRef(id: mediaID)
        let first = try makeEditClip(id: firstClipID, mediaID: mediaID, startFrame: 0)
        let second = try makeEditClip(id: secondClipID, mediaID: mediaID, startFrame: 10)
        let videoTrack = Track(
            id: videoTrackID, kind: .video, items: [.clip(first), .clip(second)]
        )
        let sequence = Sequence(
            id: sequenceID,
            name: "Two Clip Sequence",
            videoTracks: [videoTrack],
            audioTracks: [],
            markers: [],
            timebase: try FrameRate(frames: 24)
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: try FrameRate(frames: 24),
                resolution: PixelDimensions(width: 1_920, height: 1_080),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
        return TwoClipVideoFixture(
            project: project,
            sequenceID: sequenceID,
            videoTrackID: videoTrackID,
            firstClipID: firstClipID,
            secondClipID: secondClipID
        )
    }
}
