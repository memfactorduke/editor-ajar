// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class AjarAutosaveStoreTests: XCTestCase {
    func testFRTL014AtomicWriteDoesNotReplaceGoodSnapshotBeforeCommit() throws {
        let fixture = try makeEditFixture(seed: 3_500)
        let packageURL = try temporaryPackageURL(named: "AtomicWrite.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        try AjarAutosaveStore.writeSnapshot(
            fixture.project,
            appliedCommandCount: 0,
            openMode: .editable,
            to: packageURL
        )
        let projectURL = AjarAutosaveStore.projectURL(in: packageURL)
        let originalProjectJSON = try Data(contentsOf: projectURL)

        let transaction = try AjarAtomicFileWriter.prepareWrite(
            Data("interrupted write".utf8),
            to: projectURL
        )
        defer { try? transaction.cancel() }

        XCTAssertEqual(try Data(contentsOf: projectURL), originalProjectJSON)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
    }

    func testFRTL014RecoveringSnapshotAndJournalMatchesEditHistoryCurrentProject() throws {
        let fixture = try makeEditFixture(seed: 3_510)
        let commands = try recoveryCommands(fixture: fixture)
        var history = EditHistory(project: fixture.project)
        for command in commands {
            try history.apply(command)
        }

        let snapshot = AjarAutosaveSnapshot(
            package: try AjarProjectCodec.encodeNewDocument(fixture.project),
            appliedCommandCount: 0
        )
        let journalData = try AjarAutosaveJournalCodec.encode(
            commands.enumerated().map { offset, command in
                AjarAutosaveJournalEntry(sequenceNumber: offset + 1, command: command)
            }
        )

        let recovered = try AjarAutosaveStore.recover(
            snapshot: snapshot,
            journalData: journalData
        )

        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.openMode, .editable)
        XCTAssertEqual(recovered.appliedJournalEntryCount, commands.count)
        XCTAssertEqual(recovered.latestCommandCount, commands.count)
        XCTAssertEqual(recovered.project, history.currentProject)
    }

    /// Higher-minor snapshot must not replay the journal (FR-PROJ-005 / #193 / ADR-0018).
    func testFRPROJ005Issue193HigherMinorSnapshotRecoverySkipsJournalAndStaysReadOnly() throws {
        let fixture = try makeEditFixture(seed: 3_515)
        let higherMinor = AjarProjectCodec.currentSchemaMinor + 5
        let document = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: higherMinor,
            settings: fixture.project.settings,
            mediaPool: [],
            sequences: fixture.project.sequences
        )
        let manifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: higherMinor,
            media: fixture.project.mediaPool
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let snapshot = AjarAutosaveSnapshot(
            package: AjarProjectPackageData(
                projectJSON: try encoder.encode(document),
                mediaJSON: try encoder.encode(manifest)
            ),
            appliedCommandCount: 0
        )
        let commands = try recoveryCommands(fixture: fixture)
        let journalData = try AjarAutosaveJournalCodec.encode(
            commands.enumerated().map { offset, command in
                AjarAutosaveJournalEntry(sequenceNumber: offset + 1, command: command)
            }
        )

        let recovered = try AjarAutosaveStore.recover(
            snapshot: snapshot,
            journalData: journalData
        )

        XCTAssertEqual(recovered.appliedJournalEntryCount, 0)
        XCTAssertEqual(recovered.latestCommandCount, 0)
        XCTAssertTrue(recovered.issues.isEmpty)
        guard case .readOnly(let reason) = recovered.openMode else {
            return XCTFail("Expected read-only recovery, got \(recovered.openMode)")
        }
        guard case .newerSchemaMinor(let found, let supported) = reason else {
            return XCTFail("Expected newerSchemaMinor, got \(reason)")
        }
        XCTAssertEqual(found, higherMinor)
        XCTAssertEqual(supported, AjarProjectCodec.currentSchemaMinor)
        // Snapshot project is returned unchanged — no journal rename applied.
        XCTAssertEqual(
            recovered.project.sequences.first?.name,
            fixture.project.sequences.first?.name
        )
        XCTAssertEqual(recovered.project.schemaMinor, higherMinor)
        XCTAssertEqual(
            recovered.loadResult,
            .readOnly(recovered.project, reason: reason)
        )
    }

    /// Editable snapshot still replays the journal after the open-mode gate (FR-PROJ-005 / #193).
    func testFRPROJ005Issue193EditableSnapshotRecoveryStillReplaysJournal() throws {
        let fixture = try makeEditFixture(seed: 3_516)
        let commands = try recoveryCommands(fixture: fixture)
        var history = EditHistory(project: fixture.project, openMode: .editable)
        for command in commands {
            try history.apply(command)
        }

        let snapshot = AjarAutosaveSnapshot(
            package: try AjarProjectCodec.encodeNewDocument(fixture.project),
            appliedCommandCount: 0
        )
        let journalData = try AjarAutosaveJournalCodec.encode(
            commands.enumerated().map { offset, command in
                AjarAutosaveJournalEntry(sequenceNumber: offset + 1, command: command)
            }
        )

        let recovered = try AjarAutosaveStore.recover(
            snapshot: snapshot,
            journalData: journalData
        )

        XCTAssertEqual(recovered.openMode, .editable)
        XCTAssertEqual(recovered.appliedJournalEntryCount, commands.count)
        XCTAssertEqual(recovered.latestCommandCount, commands.count)
        XCTAssertEqual(recovered.project, history.currentProject)
        XCTAssertEqual(recovered.loadResult, .editable(history.currentProject))
    }

    func testNFRSTAB002CorruptJournalReturnsTypedBestEffortRecoveryWithoutCrashing() throws {
        let fixture = try makeEditFixture(seed: 3_520)
        let commands = try recoveryCommands(fixture: fixture)
        let firstCommand = try XCTUnwrap(commands.first)
        let afterFirstCommand = try apply(firstCommand, to: fixture.project)

        let snapshot = AjarAutosaveSnapshot(
            package: try AjarProjectCodec.encodeNewDocument(fixture.project),
            appliedCommandCount: 0
        )
        var journalData = try AjarAutosaveJournalCodec.encode([
            AjarAutosaveJournalEntry(sequenceNumber: 1, command: firstCommand)
        ])
        journalData.append(Data("{\"sequenceNumber\":2".utf8))

        let recovered = try AjarAutosaveStore.recover(
            snapshot: snapshot,
            journalData: journalData
        )

        XCTAssertFalse(recovered.isComplete)
        XCTAssertEqual(recovered.openMode, .editable)
        XCTAssertEqual(recovered.project, afterFirstCommand)
        XCTAssertEqual(recovered.latestCommandCount, 1)
        XCTAssertEqual(recovered.appliedJournalEntryCount, 1)
        guard case .malformedJournalEntry(line: 2, _) = try XCTUnwrap(recovered.issues.first) else {
            return XCTFail("Expected a typed malformed-journal recovery issue")
        }
    }

    func testFRTL014NFRSTAB002CrashRecoveryRestoresLastGoodJournalStateOnDisk() throws {
        let fixture = try makeEditFixture(seed: 3_530)
        let commands = try recoveryCommands(fixture: fixture)
        let firstCommand = try XCTUnwrap(commands.first)
        let secondCommand = try XCTUnwrap(commands.dropFirst().first)
        let packageURL = try temporaryPackageURL(named: "CrashRecovery.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        try AjarAutosaveStore.writeSnapshot(
            fixture.project,
            appliedCommandCount: 0,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.appendJournalEntry(
            command: firstCommand,
            sequenceNumber: 1,
            to: packageURL
        )
        let afterFirstCommand = try apply(firstCommand, to: fixture.project)
        try AjarAutosaveStore.writeSnapshot(
            afterFirstCommand,
            appliedCommandCount: 1,
            openMode: .editable,
            to: packageURL
        )

        try AjarAutosaveStore.appendJournalEntry(
            command: secondCommand,
            sequenceNumber: 2,
            to: packageURL
        )
        let afterSecondCommand = try apply(secondCommand, to: afterFirstCommand)

        let journalURL = AjarAutosaveStore.journalURL(in: packageURL)
        var journalData = try Data(contentsOf: journalURL)
        journalData.append(Data("{\"sequenceNumber\":3".utf8))
        try journalData.write(to: journalURL)

        let recovered = try AjarAutosaveStore.recoverProject(from: packageURL)

        XCTAssertFalse(recovered.isComplete)
        XCTAssertEqual(recovered.project, afterSecondCommand)
        XCTAssertEqual(recovered.latestCommandCount, 2)
        XCTAssertEqual(recovered.appliedJournalEntryCount, 1)
        guard case .malformedJournalEntry(line: 3, _) = try XCTUnwrap(recovered.issues.first) else {
            return XCTFail("Expected a typed partial-journal recovery issue")
        }
    }

    func testFRTL014RecoveryIgnoresPartiallyUpdatedPackageFiles() throws {
        let fixture = try makeEditFixture(seed: 3_540)
        let appendedClip = try makeEditClip(
            id: editUUID(3_540_999),
            mediaID: fixture.mediaID,
            startFrame: 0
        )
        let appendCommand = EditCommand.appendClip(
            sequenceID: fixture.sequenceID,
            trackID: fixture.videoTrackID,
            clip: appendedClip
        )
        let afterAppend = try apply(appendCommand, to: fixture.project)
        let packageURL = try temporaryPackageURL(named: "PartialPackageWrite.ajar")
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }

        try AjarAutosaveStore.writeSnapshot(
            fixture.project,
            appliedCommandCount: 0,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.appendJournalEntry(
            command: appendCommand,
            sequenceNumber: 1,
            to: packageURL
        )

        let partialPackage = try AjarProjectCodec.encodeNewDocument(afterAppend)
        try AjarAtomicFileWriter.write(
            partialPackage.projectJSON,
            to: AjarAutosaveStore.projectURL(in: packageURL)
        )
        try AjarAtomicFileWriter.write(
            partialPackage.mediaJSON,
            to: AjarAutosaveStore.mediaURL(in: packageURL)
        )

        let recovered = try AjarAutosaveStore.recoverProject(from: packageURL)

        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(recovered.latestCommandCount, 1)
        XCTAssertEqual(recovered.appliedJournalEntryCount, 1)
        XCTAssertEqual(recovered.project, afterAppend)
        XCTAssertEqual(try projectTrack(recovered.project, fixture: fixture).items.count, 2)
    }

    private func recoveryCommands(fixture: EditFixture) throws -> [EditCommand] {
        [
            .renameSequence(sequenceID: fixture.sequenceID, name: "Recovered Sequence"),
            .setTrackState(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                state: TrackStatePatch(enabled: false, locked: true, hidden: true)
            )
        ]
    }

    private func temporaryPackageURL(named name: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL.appendingPathComponent(name, isDirectory: true)
    }
}
