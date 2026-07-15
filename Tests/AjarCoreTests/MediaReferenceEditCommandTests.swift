// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class MediaReferenceEditCommandTests: XCTestCase {
    func testFRMED001ImportBatchAppendsInOrderAndUndoRemovesWholeBatch() throws {
        let fixture = try makeEditFixture(seed: 23_400)
        let metadata = try XCTUnwrap(fixture.project.mediaPool.first?.metadata)
        let first = MediaRef(
            id: try editUUID(23_400_901),
            sourceURL: URL(fileURLWithPath: "/import/first.mov"),
            bookmark: Data([0x23, 0x40, 0x01]),
            contentHash: ContentHash.sha256(data: Data("first import".utf8)),
            metadata: metadata
        )
        let second = MediaRef(
            id: try editUUID(23_400_902),
            sourceURL: URL(fileURLWithPath: "/import/second.wav"),
            bookmark: Data([0x23, 0x40, 0x02]),
            contentHash: ContentHash.sha256(data: Data("second import".utf8)),
            metadata: metadata
        )
        let command = EditCommand.addMediaReferences([first, second])
        var history = EditHistory(project: fixture.project)

        let imported = try history.apply(command)

        XCTAssertEqual(imported.mediaPool.suffix(2), [first, second])
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(command.actionName, "Import Media")
        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), imported)

        let roundTripped = try JSONDecoder().decode(
            EditCommand.self,
            from: JSONEncoder().encode(command)
        )
        XCTAssertEqual(roundTripped, command)
    }

    func testFRMED001ImportBatchRejectsExistingAndRepeatedIDsWithTypedError() throws {
        let fixture = try makeEditFixture(seed: 23_401)
        let existing = try XCTUnwrap(fixture.project.mediaPool.first)
        let newID = try editUUID(23_401_901)
        let imported = MediaRef(
            id: newID,
            sourceURL: URL(fileURLWithPath: "/import/new.mov"),
            contentHash: ContentHash.sha256(data: Data("new import".utf8)),
            metadata: existing.metadata
        )

        XCTAssertThrowsError(
            try apply(.addMediaReferences([existing]), to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .duplicateImportedMediaReferenceID(existing.id)
            )
        }
        XCTAssertThrowsError(
            try apply(.addMediaReferences([imported, imported]), to: fixture.project)
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .duplicateImportedMediaReferenceID(newID)
            )
        }
    }

    func testFRMED007RelinkReferenceRewriteIsUndoableAndRedoIsDeterministic() throws {
        let fixture = try makeEditFixture(seed: 21_800)
        let original = try XCTUnwrap(fixture.project.mediaPool.first)
        let replacementHash = ContentHash.sha256(data: Data("relinked bytes".utf8))
        let replacement = original.relinked(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/relinked/interview.mov"),
                contentHash: replacementHash,
                bookmark: Data([0x21, 0x80])
            )
        )
        let command = EditCommand.updateMediaReferences(
            kind: .relink,
            replacements: [replacement]
        )
        var history = EditHistory(project: fixture.project)

        let edited = try history.apply(command)
        XCTAssertEqual(edited.mediaPool.first, replacement)
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(command.actionName, "Relink Media")

        XCTAssertEqual(history.undo(), fixture.project)
        XCTAssertEqual(try history.redo(), edited)
        XCTAssertEqual(history.currentProject.mediaPool.first?.id, original.id)
    }

    func testFRMED008BatchReferenceRewritePreservesManifestOrder() throws {
        let fixture = try makeEditFixture(seed: 21_801)
        let original = try XCTUnwrap(fixture.project.mediaPool.first)
        let second = MediaRef(
            id: try editUUID(21_801_900),
            sourceURL: URL(fileURLWithPath: "/original/second.mov"),
            contentHash: ContentHash.sha256(data: Data("second".utf8)),
            metadata: original.metadata
        )
        let project = Project(
            schemaVersion: fixture.project.schemaVersion,
            settings: fixture.project.settings,
            mediaPool: [original, second],
            sequences: fixture.project.sequences
        )
        let firstReplacement = original.relinked(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/package/media/first.mov"),
                contentHash: original.contentHash
            )
        )
        let secondReplacement = second.relinked(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/package/media/second.mov"),
                contentHash: second.contentHash
            )
        )

        let edited = try apply(
            .updateMediaReferences(
                kind: .consolidate,
                replacements: [secondReplacement, firstReplacement]
            ),
            to: project
        )

        XCTAssertEqual(edited.mediaPool.map(\.id), [original.id, second.id])
        XCTAssertEqual(edited.mediaPool, [firstReplacement, secondReplacement])
    }

    func testFRMED007ReferenceRewriteRejectsMissingAndDuplicateIDsWithTypedErrors() throws {
        let fixture = try makeEditFixture(seed: 21_802)
        let original = try XCTUnwrap(fixture.project.mediaPool.first)
        let missing = MediaRef(
            id: try editUUID(21_802_999),
            sourceURL: original.sourceURL,
            bookmark: original.bookmark,
            contentHash: original.contentHash,
            metadata: original.metadata,
            availability: original.availability
        )

        XCTAssertThrowsError(
            try apply(
                .updateMediaReferences(kind: .relink, replacements: [missing]),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(error as? EditReducerError, .mediaReferenceNotFound(missing.id))
        }
        XCTAssertThrowsError(
            try apply(
                .updateMediaReferences(
                    kind: .batchRelink,
                    replacements: [original, original]
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .duplicateMediaReferenceReplacement(original.id)
            )
        }
    }

    func testFRMED007MediaReferenceCommandRoundTripsForRecoveryJournal() throws {
        let fixture = try makeEditFixture(seed: 21_803)
        let media = try XCTUnwrap(fixture.project.mediaPool.first)
        let replacement = media.relinked(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/recovery/relinked.mov"),
                contentHash: media.contentHash,
                bookmark: Data([0x21, 0x83])
            )
        )
        let command = EditCommand.updateMediaReferences(
            kind: .batchRelink,
            replacements: [replacement]
        )

        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(EditCommand.self, from: encoded)

        XCTAssertEqual(decoded, command)
        XCTAssertEqual(try apply(decoded, to: fixture.project).mediaPool.first, replacement)
    }

    func testFRMED007ResolutionMergePreservesConcurrentTimelineEditAndUndoReplay() throws {
        let fixture = try makeEditFixture(seed: 21_804)
        let original = try XCTUnwrap(fixture.project.mediaPool.first)
        let resolved = original.withAvailability(.offline)
        var history = EditHistory(project: fixture.project)
        let sequence = try XCTUnwrap(fixture.project.sequences.first)
        let marker = Marker(id: try editUUID(21_804_901), time: .zero, name: "Concurrent")

        let edited = try history.apply(.addMarker(sequenceID: sequence.id, marker: marker))
        let merged = try history.reconcileMediaReferences(
            expected: [original],
            resolved: [resolved]
        )

        XCTAssertEqual(merged.sequences, edited.sequences)
        XCTAssertEqual(merged.mediaPool, [resolved])
        XCTAssertEqual(history.undo()?.mediaPool, [resolved])
        XCTAssertEqual(try history.redo()?.mediaPool, [resolved])
        XCTAssertEqual(history.currentProject.sequences, edited.sequences)
    }

    func testFRMED007ResolutionMergeDoesNotOverwriteConcurrentRelink() throws {
        let fixture = try makeEditFixture(seed: 21_805)
        let original = try XCTUnwrap(fixture.project.mediaPool.first)
        let resolvedOldReference = original.withAvailability(.offline)
        let relinked = original.relinked(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/new/interview.mov"),
                contentHash: original.contentHash,
                bookmark: Data([0x21, 0x85])
            )
        )
        var history = EditHistory(project: fixture.project)

        _ = try history.apply(
            .updateMediaReferences(kind: .relink, replacements: [relinked])
        )
        let merged = try history.reconcileMediaReferences(
            expected: [original],
            resolved: [resolvedOldReference]
        )

        XCTAssertEqual(merged.mediaPool, [relinked])
        XCTAssertEqual(history.undo()?.mediaPool, [resolvedOldReference])
        XCTAssertEqual(try history.redo()?.mediaPool, [relinked])
    }

    func testFRMED007BookmarkResolutionWinsAvailabilityOnlyDecodeRace() throws {
        let fixture = try makeEditFixture(seed: 21_806)
        let original = try XCTUnwrap(fixture.project.mediaPool.first)
        let runtimeOffline = original.withAvailability(.offline)
        let bookmarkResolved = original.relinked(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/bookmark/resolved.mov"),
                contentHash: original.contentHash,
                bookmark: Data([0x21, 0x86])
            )
        )
        var history = EditHistory(project: fixture.project)

        _ = try history.reconcileMediaReferences(
            expected: [original],
            resolved: [runtimeOffline]
        )
        let merged = try history.reconcileMediaReferences(
            expected: [original],
            resolved: [bookmarkResolved]
        )

        XCTAssertEqual(merged.mediaPool, [bookmarkResolved])
        XCTAssertEqual(merged.mediaPool.first?.availability, .available)
    }
}

extension MediaReferenceEditCommandTests {
    func testFRMED008SaveAsMediaRebaseKeepsMidClipInsertUndoRedoCoherent() throws {
        let fixture = try makeEditFixture(seed: 21_807)
        let original = try XCTUnwrap(fixture.project.mediaPool.first)
        let oldPackageReference = original.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/Old.ajar/media/interview.mov"),
                contentHash: original.contentHash,
                bookmark: Data("old package bookmark".utf8)
            )
        )
        let newPackageReference = oldPackageReference.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/New.ajar/media/interview.mov"),
                contentHash: original.contentHash,
                bookmark: Data("new package bookmark".utf8)
            )
        )
        var history = EditHistory(project: fixture.project)
        _ = try history.apply(
            .updateMediaReferences(kind: .consolidate, replacements: [oldPackageReference])
        )
        let insertedClip = try makeEditClip(
            id: try editUUID(21_807_901),
            mediaID: fixture.mediaID,
            startFrame: 9,
            durationFrames: 5
        )
        let afterInsert = try history.apply(
            .insertClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clip: insertedClip
            )
        )
        _ = history.undo()

        let rebased = try history.rebaseMediaReferences(
            expected: [oldPackageReference],
            rebased: [newPackageReference]
        )

        XCTAssertEqual(rebased.mediaPool, [newPackageReference])
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.redoCount, 1)
        XCTAssertEqual(history.undo()?.mediaPool, [original])
        XCTAssertEqual(try history.redo()?.mediaPool, [newPackageReference])
        let insertRedone = try history.redo()
        XCTAssertEqual(insertRedone?.mediaPool, [newPackageReference])
        XCTAssertEqual(insertRedone?.sequences, afterInsert.sequences)
    }

    func testFRMED008PackageMediaRebaseUsesStableIDAndHistoricalLocation() throws {
        let fixture = try makeEditFixture(seed: 21_808)
        let original = try XCTUnwrap(fixture.project.mediaPool.first)
        let firstOld = original.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/Old.ajar/media/first.mov"),
                contentHash: original.contentHash,
                bookmark: Data("first old bookmark".utf8)
            )
        )
        let secondOld = original.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/Old.ajar/media/second.mov"),
                contentHash: original.contentHash,
                bookmark: Data("second old bookmark".utf8)
            )
        )
        let firstNew = firstOld.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/New.ajar/media/first.mov"),
                contentHash: original.contentHash,
                bookmark: Data("first new bookmark".utf8)
            )
        )
        let secondNew = secondOld.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: URL(fileURLWithPath: "/New.ajar/media/second.mov"),
                contentHash: original.contentHash,
                bookmark: Data("second new bookmark".utf8)
            )
        )
        var history = EditHistory(project: fixture.project)
        _ = try history.apply(
            .updateMediaReferences(kind: .consolidate, replacements: [firstOld])
        )
        _ = try history.apply(.updateMediaReferences(kind: .relink, replacements: [secondOld]))

        XCTAssertTrue(history.persistenceMediaReferences.contains(firstOld))
        XCTAssertTrue(history.persistenceMediaReferences.contains(secondOld))
        XCTAssertEqual(
            try history.rebaseMediaReferences(
                expected: [firstOld, secondOld],
                rebased: [firstNew, secondNew]
            ).mediaPool,
            [secondNew]
        )
        XCTAssertEqual(history.undo()?.mediaPool, [firstNew])
        XCTAssertEqual(history.undo()?.mediaPool, [original])
        XCTAssertEqual(try history.redo()?.mediaPool, [firstNew])
        XCTAssertEqual(try history.redo()?.mediaPool, [secondNew])
    }
}
