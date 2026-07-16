// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AppKit
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarDocumentLifecycleTests: XCTestCase {
    func testFRPROJ001NewProjectSaveAndReopenRoundTrips() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var settings = EditorAjarNewProjectSettings.sensibleDefaults
        settings.resolutionChoice = .ultraHD
        settings.frameRateChoice = .fps24
        settings.colorSpaceChoice = .displayP3
        settings.audioRateChoice = .hz96000

        let model = fixture.makeModel()
        try model.createNewProject(settings: settings)
        let createdProject = try XCTUnwrap(model.project)
        XCTAssertTrue(model.isDocumentDirty)
        XCTAssertNil(model.documentURL)
        XCTAssertEqual(createdProject.settings.resolution, PixelDimensions(width: 3_840, height: 2_160))
        XCTAssertEqual(createdProject.settings.frameRate, try FrameRate(frames: 24))
        XCTAssertEqual(createdProject.settings.colorSpace, .displayP3)
        XCTAssertEqual(createdProject.settings.audioSampleRate, 96_000)
        XCTAssertTrue(createdProject.mediaPool.isEmpty)

        let packageURL = fixture.packageURL(named: "RoundTrip.ajar")
        try model.saveProjectAs(to: packageURL)
        XCTAssertFalse(model.isDocumentDirty)
        XCTAssertEqual(model.documentURL, packageURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("project.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("media.json").path
        ))

        let reopened = fixture.makeModel()
        try reopened.openProject(at: packageURL)
        XCTAssertEqual(reopened.project, createdProject)
        XCTAssertEqual(reopened.projectOpenMode, .editable)
        XCTAssertFalse(reopened.isDocumentDirty)
    }

    func testFRPROJ002SaveAsRetargetsWithoutOverwritingOriginal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let originalURL = fixture.packageURL(named: "Original.ajar")
        let copyURL = fixture.packageURL(named: "Copy.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: originalURL)
        let originalProject = try XCTUnwrap(model.project)

        XCTAssertTrue(model.addSequence())
        let editedProject = try XCTUnwrap(model.project)
        XCTAssertNotEqual(editedProject, originalProject)
        try model.saveProjectAs(to: copyURL)

        let originalModel = fixture.makeModel()
        try originalModel.openProject(at: originalURL)
        let copiedModel = fixture.makeModel()
        try copiedModel.openProject(at: copyURL)
        XCTAssertEqual(originalModel.project, originalProject)
        XCTAssertEqual(copiedModel.project, editedProject)
        XCTAssertEqual(model.documentURL, copyURL.standardizedFileURL)
        XCTAssertEqual(model.documentDisplayName, "Copy")
        XCTAssertFalse(model.isDocumentDirty)
    }

    func testFRPROJ002SaveAsAdoptsCommittedReplacementWithRetainedCleanupWarning() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceURL = fixture.packageURL(named: "Source.ajar")
        let destinationURL = fixture.packageURL(named: "Destination.ajar")
        let retainedBytes = Data("app model retained cleanup data".utf8)
        let store = EditorAjarDocumentStore(
            saveAsCleanupDirectoryDevice: { directoryURL, actualDevice in
                directoryURL.lastPathComponent == "retained-child"
                    ? actualDevice &+ 1
                    : actualDevice
            }
        )
        let model = fixture.makeModel(documentStore: store)
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: sourceURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        let retainedChild = destinationURL.appendingPathComponent(
            "retained-child",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: retainedChild,
            withIntermediateDirectories: false
        )
        try retainedBytes.write(to: retainedChild.appendingPathComponent("must-survive.txt"))
        XCTAssertTrue(model.addSequence())
        let committedProject = try XCTUnwrap(model.project)
        let undoCount = model.editHistory?.undoCount

        try model.saveProjectAs(to: destinationURL)

        XCTAssertEqual(model.documentURL, destinationURL.standardizedFileURL)
        XCTAssertEqual(model.project, committedProject)
        XCTAssertEqual(model.editHistory?.undoCount, undoCount)
        XCTAssertFalse(model.isDocumentDirty)
        XCTAssertNotNil(model.documentWarningMessage)
        XCTAssertTrue(model.documentWarningMessage?.contains("The project was saved") == true)
        XCTAssertTrue(model.documentWarningMessage?.contains("Destination") == true)
        let reopened = fixture.makeModel()
        try reopened.openProject(at: destinationURL)
        XCTAssertEqual(reopened.project, committedProject)

        model.undo()
        XCTAssertNotEqual(model.project, committedProject)
        XCTAssertTrue(model.isDocumentDirty)
        model.redo()
        XCTAssertEqual(model.project, committedProject)
        XCTAssertFalse(model.isDocumentDirty)

        let retainedCleanupURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.rootURL,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasSuffix(".cleanup") }
        )
        XCTAssertEqual(
            try Data(
                contentsOf: retainedCleanupURL.appendingPathComponent(
                    "retained-child/must-survive.txt"
                )
            ),
            retainedBytes
        )
        XCTAssertTrue(
            model.documentWarningMessage?.contains(retainedCleanupURL.lastPathComponent) == true,
            "a verified retained package warning should identify its exact quarantine name"
        )
        model.dismissDocumentWarning()
        XCTAssertNil(model.documentWarningMessage)
    }

    func testFRPROJ002SaveAsWarnsWithoutLocationAfterUnexpectedCleanupEntryIsRestored() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceURL = fixture.packageURL(named: "Source.ajar")
        let destinationURL = fixture.packageURL(named: "Destination.ajar")
        let preservedPreviousDestination = fixture.packageURL(
            named: "Preserved-Previous-Destination.ajar"
        )
        let unrelatedBytes = Data("app model cleanup substitution".utf8)
        var restoredUnexpectedURL: URL?
        let store = EditorAjarDocumentStore(
            saveAsWillQuarantineCleanup: { cleanupSourceURL in
                restoredUnexpectedURL = cleanupSourceURL
                try FileManager.default.moveItem(
                    at: cleanupSourceURL,
                    to: preservedPreviousDestination
                )
                try FileManager.default.createDirectory(
                    at: cleanupSourceURL,
                    withIntermediateDirectories: false
                )
                try unrelatedBytes.write(
                    to: cleanupSourceURL.appendingPathComponent("must-survive.txt")
                )
            }
        )
        let model = fixture.makeModel(documentStore: store)
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: sourceURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        XCTAssertTrue(model.addSequence())
        let committedProject = try XCTUnwrap(model.project)

        try model.saveProjectAs(to: destinationURL)

        XCTAssertEqual(model.documentURL, destinationURL.standardizedFileURL)
        XCTAssertEqual(model.project, committedProject)
        XCTAssertFalse(model.isDocumentDirty)
        XCTAssertTrue(
            model.documentWarningMessage?.contains(
                "Automatic cleanup was skipped safely because the older folder changed"
            ) == true
        )
        XCTAssertTrue(
            model.documentWarningMessage?.contains(
                "No folder was identified as safe to delete"
            ) == true
        )
        let exactRestoredURL = try XCTUnwrap(restoredUnexpectedURL)
        XCTAssertFalse(
            model.documentWarningMessage?.contains(exactRestoredURL.lastPathComponent) == true
        )
        XCTAssertFalse(
            model.documentWarningMessage?.contains(fixture.rootURL.lastPathComponent) == true
        )
        XCTAssertEqual(
            try Data(contentsOf: exactRestoredURL.appendingPathComponent("must-survive.txt")),
            unrelatedBytes
        )
        let reopened = fixture.makeModel()
        try reopened.openProject(at: destinationURL)
        XCTAssertEqual(reopened.project, committedProject)
    }

    func testFRPROJ002SaveAsWarnsWithoutLocationWhenCleanupParentValidationFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceURL = fixture.packageURL(named: "Source.ajar")
        let destinationURL = fixture.packageURL(named: "Destination.ajar")
        var didReachParentValidation = false
        let store = EditorAjarDocumentStore(
            saveAsWillValidatePreviousDestinationCleanup: {
                didReachParentValidation = true
                throw EditorAjarDocumentStoreError.saveAsDestinationChanged(
                    path: fixture.rootURL.path,
                    reason: "injected pre-quarantine parent validation refusal"
                )
            }
        )
        let model = fixture.makeModel(documentStore: store)
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: sourceURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        XCTAssertTrue(model.addSequence())
        let committedProject = try XCTUnwrap(model.project)

        try model.saveProjectAs(to: destinationURL)

        XCTAssertTrue(didReachParentValidation)
        XCTAssertEqual(model.documentURL, destinationURL.standardizedFileURL)
        XCTAssertEqual(model.project, committedProject)
        XCTAssertFalse(model.isDocumentDirty)
        XCTAssertTrue(
            model.documentWarningMessage?.contains(
                "Automatic cleanup was skipped safely because the older folder changed"
            ) == true
        )
        XCTAssertFalse(
            model.documentWarningMessage?.contains(fixture.rootURL.lastPathComponent) == true
        )
        let reopened = fixture.makeModel()
        try reopened.openProject(at: destinationURL)
        XCTAssertEqual(reopened.project, committedProject)
        XCTAssertEqual(try fixture.stagingPackages().count, 1)
    }

    func testFRPROJ002RevertDiscardsUnsavedEditsAndHistory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "Revert.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)
        let savedProject = try XCTUnwrap(model.project)

        XCTAssertTrue(model.addSequence())
        XCTAssertTrue(model.isDocumentDirty)
        XCTAssertTrue(model.canUndo)
        try model.revertProject()

        XCTAssertEqual(model.project, savedProject)
        XCTAssertFalse(model.isDocumentDirty)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testFRPROJ002RevertDurablyDiscardsPackageRecoveryEdits() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "RecoveredRevert.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)
        let savedProject = try XCTUnwrap(model.project)
        let savedProjectBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("project.json")
        )
        let savedMediaBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("media.json")
        )

        XCTAssertTrue(model.addSequence())
        let recoveredProject = try XCTUnwrap(model.project)
        try AjarAutosaveStore.writeSnapshot(
            recoveredProject,
            appliedCommandCount: 1,
            openMode: .editable,
            to: packageURL
        )
        try AjarAtomicFileWriter.write(
            savedProjectBytes,
            to: packageURL.appendingPathComponent("project.json")
        )
        try AjarAtomicFileWriter.write(
            savedMediaBytes,
            to: packageURL.appendingPathComponent("media.json")
        )

        let recoveredModel = fixture.makeModel()
        try recoveredModel.openProject(at: packageURL)
        XCTAssertEqual(recoveredModel.project, recoveredProject)
        XCTAssertTrue(recoveredModel.isDocumentDirty)

        try recoveredModel.revertProject()
        XCTAssertEqual(recoveredModel.project, savedProject)
        XCTAssertFalse(recoveredModel.isDocumentDirty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent("recovery").path
        ))

        let reopenedModel = fixture.makeModel()
        try reopenedModel.openProject(at: packageURL)
        XCTAssertEqual(reopenedModel.project, savedProject)
        XCTAssertFalse(reopenedModel.isDocumentDirty)
    }

    func testFRPROJ002DirtyStateTracksPersistedEditsAgainstSavedBaseline() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "Dirty.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        XCTAssertTrue(model.isDocumentDirty)
        try model.saveProjectAs(to: packageURL)
        XCTAssertFalse(model.isDocumentDirty)

        model.scrub(to: 0)
        model.toggleCanvasSafeAreaGuides()
        XCTAssertFalse(model.isDocumentDirty, "session-only controls must not dirty the document")

        XCTAssertTrue(model.addSequence())
        XCTAssertTrue(model.isDocumentDirty)
        model.undo()
        XCTAssertFalse(model.isDocumentDirty, "undoing exactly to the saved baseline is clean")
        model.redo()
        XCTAssertTrue(model.isDocumentDirty)
        try model.saveProject()
        XCTAssertFalse(model.isDocumentDirty)
    }

    func testFRPROJ002ExplicitSaveClearsRecoveryUntilAnotherEdit() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recoveryURL = fixture.packageURL(named: "Recovery.ajar")
        let documentURL = fixture.packageURL(named: "Saved.ajar")
        let model = EditorAjarAppModel(
            autosavePackageURL: recoveryURL,
            autosaveIntervalSeconds: 0,
            recentProjectsUserDefaults: fixture.userDefaults,
            recentProjectsStorageKey: fixture.recentProjectsStorageKey
        )

        try model.createNewProject(settings: .sensibleDefaults)
        await model.autosaveCheckpointForTesting()
        XCTAssertTrue(AjarAutosaveStore.hasRecoverableSnapshot(at: recoveryURL))

        try model.saveProjectAs(to: documentURL)
        await model.autosaveCheckpointForTesting()
        XCTAssertFalse(AjarAutosaveStore.hasRecoverableSnapshot(at: recoveryURL))

        XCTAssertTrue(model.addSequence())
        await model.autosaveCheckpointForTesting()
        XCTAssertTrue(AjarAutosaveStore.hasRecoverableSnapshot(at: recoveryURL))
    }

    func testFRPROJ002ClosingDiscardClearsAppRecoveryBeforeTermination() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let recoveryURL = fixture.packageURL(named: "ClosingRecovery.ajar")
        let model = EditorAjarAppModel(
            autosavePackageURL: recoveryURL,
            autosaveIntervalSeconds: 0,
            recentProjectsUserDefaults: fixture.userDefaults,
            recentProjectsStorageKey: fixture.recentProjectsStorageKey
        )
        try model.createNewProject(settings: .sensibleDefaults)
        await model.autosaveCheckpointForTesting()
        XCTAssertTrue(AjarAutosaveStore.hasRecoverableSnapshot(at: recoveryURL))

        model.discardUnsavedChangesForClosing()
        await model.finishPendingDocumentWrites()

        XCTAssertFalse(model.isDocumentDirty)
        XCTAssertFalse(AjarAutosaveStore.hasRecoverableSnapshot(at: recoveryURL))
    }

    func testFRPROJ002VersionSnapshotsKeepNewestTenAndPruneOldest() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "Versions.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        for _ in 1...12 {
            XCTAssertTrue(model.addSequence())
            try model.saveProject()
        }

        let store = EditorAjarDocumentStore()
        let snapshots = try store.versionSnapshotURLs(in: packageURL)
        XCTAssertEqual(snapshots.count, EditorAjarDocumentStore.snapshotRetentionLimit)
        let retainedSequenceCounts = try snapshots.map { snapshotURL in
            try store.revert(at: snapshotURL).project.sequences.count
        }
        XCTAssertEqual(retainedSequenceCounts, Array(3...12))
    }

    func testFRPROJ002FailedStagedSaveLeavesPackageAndVersionsUntouched() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "Atomic.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)
        let project = try XCTUnwrap(model.project)
        let projectBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("project.json")
        )
        let mediaBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("media.json")
        )
        let store = EditorAjarDocumentStore()
        let snapshotsBefore = try store.versionSnapshotURLs(in: packageURL)
        let unsupportedMinor = AjarProjectCodec.currentSchemaMinor + 1

        XCTAssertThrowsError(
            try store.save(
                project: project,
                openMode: .readOnly(reason: .newerSchemaMinor(
                    found: unsupportedMinor,
                    supported: AjarProjectCodec.currentSchemaMinor
                )),
                appliedCommandCount: 0,
                to: packageURL
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("project.json")),
            projectBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("media.json")),
            mediaBytes
        )
        XCTAssertEqual(try store.versionSnapshotURLs(in: packageURL), snapshotsBefore)

        let siblings = try FileManager.default.contentsOfDirectory(
            at: fixture.rootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.hasSuffix(".staging") })
    }

    func testFRPROJ002SaveRebasesRecoveryWithoutReplacingCachesOrRecoverySidecars() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "InPlace.ajar")
        let synchronizationEvents = InPlaceSaveSynchronizationEvents()
        let model = fixture.makeModel(
            documentStore: EditorAjarDocumentStore(
                saveDidPublishRecovery: {
                    synchronizationEvents.values.append(.recoveryPublished)
                },
                saveDidPublishContents: {
                    synchronizationEvents.values.append(.contentsPublished)
                },
                saveAsSynchronizer: RecordingInPlaceSaveSynchronizer(
                    events: synchronizationEvents
                )
            )
        )
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)
        synchronizationEvents.values.removeAll()
        let cacheURL = packageURL.appendingPathComponent("caches/render/cache.bin")
        let recoveryURL = packageURL.appendingPathComponent("recovery/session.bin")
        let nestedRecoveryURL = packageURL.appendingPathComponent(
            "recovery/plugins/session.bin"
        )
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: recoveryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nestedRecoveryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cache".utf8).write(to: cacheURL)
        try Data("recovery".utf8).write(to: recoveryURL)
        try Data("nested recovery".utf8).write(to: nestedRecoveryURL)

        XCTAssertTrue(model.addSequence())
        try model.saveProject()

        XCTAssertEqual(try Data(contentsOf: cacheURL), Data("cache".utf8))
        XCTAssertEqual(try Data(contentsOf: recoveryURL), Data("recovery".utf8))
        XCTAssertEqual(try Data(contentsOf: nestedRecoveryURL), Data("nested recovery".utf8))
        let nestedFileIndex = try eventIndex(
            in: synchronizationEvents.values,
            kind: .file,
            pathSuffix: "/recovery/plugins/session.bin"
        )
        let topLevelFileIndex = try eventIndex(
            in: synchronizationEvents.values,
            kind: .file,
            pathSuffix: "/recovery/session.bin"
        )
        let nestedDirectoryIndex = try eventIndex(
            in: synchronizationEvents.values,
            kind: .directory,
            pathSuffix: "/recovery/plugins"
        )
        let recoveryDirectoryIndex = try stagingRecoveryDirectoryIndex(
            in: synchronizationEvents.values,
            destinationRecoveryURL: recoveryURL.deletingLastPathComponent()
        )
        let packageDirectoryIndex = try XCTUnwrap(
            synchronizationEvents.values.firstIndex(of: .directory(packageURL.path))
        )
        let publicationBoundaryIndex = try XCTUnwrap(
            synchronizationEvents.values.firstIndex(of: .recoveryPublished)
        )
        XCTAssertLessThan(topLevelFileIndex, recoveryDirectoryIndex)
        XCTAssertLessThan(nestedFileIndex, nestedDirectoryIndex)
        XCTAssertLessThan(nestedDirectoryIndex, recoveryDirectoryIndex)
        XCTAssertLessThan(recoveryDirectoryIndex, packageDirectoryIndex)
        XCTAssertLessThan(packageDirectoryIndex, publicationBoundaryIndex)

        let projectURL = packageURL.appendingPathComponent("project.json")
        let mediaURL = packageURL.appendingPathComponent("media.json")
        let versionsURL = packageURL.appendingPathComponent("versions", isDirectory: true)
        let projectTemporaryIndex = try XCTUnwrap(
            synchronizationEvents.values.firstIndex { event in
                guard case .file(let path) = event else {
                    return false
                }
                return path.contains("/.project.json.") && path.hasSuffix(".tmp")
            }
        )
        let projectFileIndex = try XCTUnwrap(
            synchronizationEvents.values.firstIndex(of: .file(projectURL.path))
        )
        let projectPackageIndex = try directoryEventIndex(
            in: synchronizationEvents.values,
            path: packageURL.path,
            after: projectFileIndex
        )
        let mediaTemporaryIndex = try XCTUnwrap(
            synchronizationEvents.values.firstIndex { event in
                guard case .file(let path) = event else {
                    return false
                }
                return path.contains("/.media.json.") && path.hasSuffix(".tmp")
            }
        )
        let mediaFileIndex = try XCTUnwrap(
            synchronizationEvents.values.firstIndex(of: .file(mediaURL.path))
        )
        let mediaPackageIndex = try directoryEventIndex(
            in: synchronizationEvents.values,
            path: packageURL.path,
            after: mediaFileIndex
        )
        let stagedVersionsIndex = try stagingDirectoryIndex(
            in: synchronizationEvents.values,
            named: "versions",
            destinationURL: versionsURL
        )
        let publishedVersionsIndex = try XCTUnwrap(
            synchronizationEvents.values.firstIndex(of: .directory(versionsURL.path))
        )
        let versionsPackageIndex = try directoryEventIndex(
            in: synchronizationEvents.values,
            path: packageURL.path,
            after: publishedVersionsIndex
        )
        let contentsBoundaryIndex = try XCTUnwrap(
            synchronizationEvents.values.firstIndex(of: .contentsPublished)
        )
        XCTAssertLessThan(projectTemporaryIndex, projectFileIndex)
        XCTAssertLessThan(projectFileIndex, projectPackageIndex)
        XCTAssertLessThan(projectPackageIndex, mediaTemporaryIndex)
        XCTAssertLessThan(mediaTemporaryIndex, mediaFileIndex)
        XCTAssertLessThan(mediaFileIndex, mediaPackageIndex)
        XCTAssertLessThan(mediaPackageIndex, stagedVersionsIndex)
        XCTAssertLessThan(stagedVersionsIndex, publishedVersionsIndex)
        XCTAssertLessThan(publishedVersionsIndex, versionsPackageIndex)
        XCTAssertLessThan(versionsPackageIndex, contentsBoundaryIndex)
        let recovery = try AjarAutosaveStore.recoverProject(from: packageURL)
        XCTAssertEqual(recovery.project, model.project)
        XCTAssertEqual(recovery.appliedJournalEntryCount, 0)
    }

    func testFRPROJ002NFRSTAB002ExplicitSaveRebasesStalePackageRecovery() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "StaleRecovery.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        XCTAssertTrue(model.addSequence())
        let staleRecoveryProject = try XCTUnwrap(model.project)
        try AjarAutosaveStore.writeSnapshot(
            staleRecoveryProject,
            appliedCommandCount: 1,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.replaceJournal(with: [], in: packageURL)

        XCTAssertTrue(model.addSequence())
        let explicitlySavedProject = try XCTUnwrap(model.project)
        XCTAssertNotEqual(explicitlySavedProject, staleRecoveryProject)
        try model.saveProject()

        let reopened = fixture.makeModel()
        try reopened.openProject(at: packageURL)

        XCTAssertEqual(reopened.project, explicitlySavedProject)
        XCTAssertFalse(reopened.isDocumentDirty)
        let recovery = try AjarAutosaveStore.recoverProject(from: packageURL)
        XCTAssertEqual(recovery.project, explicitlySavedProject)
        XCTAssertEqual(recovery.appliedJournalEntryCount, 0)
    }

    func testNFRSTAB002FailedSaveAfterPublicationRollsBackCanonicalAndRecovery() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "RecoveryRollback.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        XCTAssertTrue(model.addSequence())
        let previousProject = try XCTUnwrap(model.project)
        try AjarAutosaveStore.writeSnapshot(
            previousProject,
            appliedCommandCount: 1,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.replaceJournal(with: [], in: packageURL)
        let previousProjectBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("project.json")
        )
        let previousMediaBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("media.json")
        )
        let previousRecoveryBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("recovery/snapshot.json")
        )

        XCTAssertTrue(model.addSequence())
        let attemptedProject = try XCTUnwrap(model.project)
        let store = EditorAjarDocumentStore(
            saveDidPublishContents: {
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: packageURL.path,
                    reason: "injected post-publication failure"
                )
            }
        )

        XCTAssertThrowsError(
            try store.save(
                project: attemptedProject,
                openMode: .editable,
                appliedCommandCount: 2,
                to: packageURL
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("project.json")),
            previousProjectBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("media.json")),
            previousMediaBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("recovery/snapshot.json")),
            previousRecoveryBytes
        )
        XCTAssertEqual(
            try AjarAutosaveStore.recoverProject(from: packageURL).project,
            previousProject
        )
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testNFRSTAB002FailedRestorationRetainsCompleteRollbackBackup() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "RetainedRollback.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        let duration = try RationalTime(value: 1, timescale: 1)
        let media = MediaRef(
            id: UUID(),
            sourceURL: fixture.rootURL.appendingPathComponent("retained-rollback.mov"),
            contentHash: ContentHash.sha256(data: Data("retained rollback media".utf8)),
            metadata: MediaMetadata(
                codecID: "prores422",
                pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
                frameRate: try FrameRate(frames: 30),
                duration: duration,
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        XCTAssertTrue(model.applyEditForTesting(.addMediaReferences([media])))
        let sequence = try XCTUnwrap(model.project?.sequences.first)
        let track = try XCTUnwrap(sequence.videoTracks.first)
        let range = try TimeRange(start: .zero, duration: duration)
        let clip = Clip(
            id: UUID(),
            source: .media(id: media.id),
            sourceRange: range,
            timelineRange: range,
            kind: .video,
            name: "Retained Rollback Clip"
        )
        XCTAssertTrue(
            model.applyEditForTesting(
                .addClip(sequenceID: sequence.id, trackID: track.id, clip: clip)
            )
        )
        try model.saveProject()
        let previousProject = try XCTUnwrap(model.project)
        let previousProjectBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("project.json")
        )
        let previousMediaBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("media.json")
        )
        let previousRecoveryBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("recovery/snapshot.json")
        )
        let previousVersionURLs = try EditorAjarDocumentStore().versionSnapshotURLs(
            in: packageURL
        )
        let previousVersionURL = try XCTUnwrap(previousVersionURLs.first)
        XCTAssertEqual(previousVersionURLs.count, 1)
        let previousVersionProjectBytes = try Data(
            contentsOf: previousVersionURL.appendingPathComponent("project.json")
        )
        let previousVersionMediaBytes = try Data(
            contentsOf: previousVersionURL.appendingPathComponent("media.json")
        )

        let projectWithoutClip = try apply(
            .removeClip(sequenceID: sequence.id, trackID: track.id, clipID: clip.id),
            to: previousProject
        )
        let attemptedProject = Project(
            schemaVersion: projectWithoutClip.schemaVersion,
            schemaMinor: projectWithoutClip.schemaMinor,
            settings: projectWithoutClip.settings,
            mediaPool: [],
            sequences: projectWithoutClip.sequences,
            looks: projectWithoutClip.looks
        )
        var restorationStarted = false
        var reportedReason: String?
        let synchronizationEvents = InPlaceSaveSynchronizationEvents(
            failingDirectoryURL: packageURL,
            directoryFailureMatchOffset: 3,
            shouldFailDirectory: { restorationStarted }
        )
        let store = EditorAjarDocumentStore(
            saveDidPublishContents: {
                restorationStarted = true
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: packageURL.path,
                    reason: "injected post-publication failure"
                )
            },
            saveAsSynchronizer: RecordingInPlaceSaveSynchronizer(
                events: synchronizationEvents
            )
        )

        XCTAssertThrowsError(
            try store.save(
                project: attemptedProject,
                openMode: .editable,
                appliedCommandCount: 3,
                to: packageURL
            )
        ) { error in
            guard let documentError = error as? EditorAjarDocumentStoreError,
                case .fileOperation(let path, let reason) = documentError
            else {
                return XCTFail("Expected a typed restoration failure, got \(error)")
            }
            XCTAssertEqual(path, packageURL.path)
            XCTAssertTrue(reason.contains("rollback backup was retained"))
            reportedReason = reason
        }

        XCTAssertEqual(synchronizationEvents.remainingDirectoryFailures, 0)
        let retainedBackups = try fixture.stagingPackages()
        let retainedBackupURL = try XCTUnwrap(retainedBackups.first)
        XCTAssertEqual(retainedBackups.count, 1)
        XCTAssertTrue(reportedReason?.contains(retainedBackupURL.lastPathComponent) == true)
        XCTAssertEqual(
            try Data(contentsOf: retainedBackupURL.appendingPathComponent("project.json")),
            previousProjectBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedBackupURL.appendingPathComponent("media.json")),
            previousMediaBytes
        )
        XCTAssertEqual(
            try Data(
                contentsOf: retainedBackupURL.appendingPathComponent("recovery/snapshot.json")
            ),
            previousRecoveryBytes
        )
        let retainedVersions = try EditorAjarDocumentStore().versionSnapshotURLs(
            in: retainedBackupURL
        )
        let retainedVersionURL = try XCTUnwrap(retainedVersions.first)
        XCTAssertEqual(
            retainedVersions.map(\.lastPathComponent),
            previousVersionURLs.map(\.lastPathComponent)
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedVersionURL.appendingPathComponent("project.json")),
            previousVersionProjectBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedVersionURL.appendingPathComponent("media.json")),
            previousVersionMediaBytes
        )
        let rollbackRecoveryDirectoryIndex = try eventIndex(
            in: synchronizationEvents.values,
            kind: .directory,
            pathSuffix: "/\(retainedBackupURL.lastPathComponent)/recovery"
        )
        for name in [
            "snapshot.json",
            "manifest.json",
            "edit-journal.jsonl",
            "save-transaction.json",
        ] {
            let fileIndex = try eventIndex(
                in: synchronizationEvents.values,
                kind: .file,
                pathSuffix: "/\(retainedBackupURL.lastPathComponent)/recovery/\(name)"
            )
            XCTAssertLessThan(fileIndex, rollbackRecoveryDirectoryIndex)
        }
        let rollbackRootIndex = try XCTUnwrap(
            synchronizationEvents.values.indices.first { index in
                guard index > rollbackRecoveryDirectoryIndex,
                    case .directory(let path) = synchronizationEvents.values[index]
                else {
                    return false
                }
                return path.hasSuffix("/\(retainedBackupURL.lastPathComponent)")
            }
        )
        let failedDestinationRootIndex = try XCTUnwrap(
            synchronizationEvents.values.lastIndex(of: .directory(packageURL.path))
        )
        XCTAssertLessThan(rollbackRecoveryDirectoryIndex, rollbackRootIndex)
        XCTAssertLessThan(rollbackRootIndex, failedDestinationRootIndex)

        // The failure is injected after versions and recovery were restored from disposable copies.
        // The original rollback package must still be complete even though its final root barrier
        // failed and the published package's durability is therefore not guaranteed.
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("project.json")),
            previousProjectBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("media.json")),
            previousMediaBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("recovery/snapshot.json")),
            previousRecoveryBytes
        )
    }

    func testNFRSTAB002RecoveryPublishesBeforeCanonicalAndBoundaryFailureRollsBack() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "RecoveryFirst.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        XCTAssertTrue(model.addSequence())
        let previousProject = try XCTUnwrap(model.project)
        try AjarAutosaveStore.writeSnapshot(
            previousProject,
            appliedCommandCount: 1,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.replaceJournal(with: [], in: packageURL)
        let previousProjectBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("project.json")
        )

        XCTAssertTrue(model.addSequence())
        let attemptedProject = try XCTUnwrap(model.project)
        var projectObservedAtBoundary: Project?
        var canonicalBytesObservedAtBoundary: Data?
        let synchronizationEvents = InPlaceSaveSynchronizationEvents()
        let recoveryURL = packageURL.appendingPathComponent("recovery", isDirectory: true)
        let store = EditorAjarDocumentStore(
            saveDidPublishRecovery: {
                synchronizationEvents.values.append(.recoveryPublished)
                projectObservedAtBoundary = try AjarAutosaveStore.recoverProject(
                    from: packageURL
                ).project
                canonicalBytesObservedAtBoundary = try Data(
                    contentsOf: packageURL.appendingPathComponent("project.json")
                )
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: packageURL.path,
                    reason: "injected recovery-first boundary failure"
                )
            },
            saveAsSynchronizer: RecordingInPlaceSaveSynchronizer(
                events: synchronizationEvents
            )
        )

        XCTAssertThrowsError(
            try store.save(
                project: attemptedProject,
                openMode: .editable,
                appliedCommandCount: 2,
                to: packageURL
            )
        )

        XCTAssertEqual(projectObservedAtBoundary, attemptedProject)
        XCTAssertEqual(canonicalBytesObservedAtBoundary, previousProjectBytes)
        let stagingRecoveryIndex = try stagingRecoveryDirectoryIndex(
            in: synchronizationEvents.values,
            destinationRecoveryURL: recoveryURL
        )
        guard case .directory(let stagingRecoveryPath) =
            synchronizationEvents.values[stagingRecoveryIndex]
        else {
            return XCTFail("Expected a staged recovery directory event")
        }
        let publicationEvents: [InPlaceSaveSynchronizationEvents.Event] = [
            .file(stagingRecoveryPath + "/snapshot.json"),
            .file(stagingRecoveryPath + "/manifest.json"),
            .file(stagingRecoveryPath + "/edit-journal.jsonl"),
            .file(stagingRecoveryPath + "/save-transaction.json"),
            .directory(stagingRecoveryPath),
            .directory(packageURL.path),
            .recoveryPublished,
        ]
        XCTAssertEqual(
            Array(synchronizationEvents.values.prefix(publicationEvents.count)),
            publicationEvents
        )
        XCTAssertEqual(
            try AjarAutosaveStore.recoverProject(from: packageURL).project,
            previousProject
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("project.json")),
            previousProjectBytes
        )
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testNFRSTAB002RecoveryDurabilityFailurePreventsCanonicalPublication() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "RecoveryDurabilityFailure.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        XCTAssertTrue(model.addSequence())
        let previousProject = try XCTUnwrap(model.project)
        try AjarAutosaveStore.writeSnapshot(
            previousProject,
            appliedCommandCount: 1,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.replaceJournal(with: [], in: packageURL)
        let previousManifestURL = packageURL.appendingPathComponent("recovery/manifest.json")
        let previousJournalURL = packageURL.appendingPathComponent("recovery/edit-journal.jsonl")
        let sidecarURL = packageURL.appendingPathComponent("recovery/session.bin")
        let nestedSidecarURL = packageURL.appendingPathComponent("recovery/plugins/session.bin")
        try FileManager.default.createDirectory(
            at: nestedSidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("sidecar".utf8).write(to: sidecarURL)
        try Data("nested sidecar".utf8).write(to: nestedSidecarURL)
        try FileManager.default.removeItem(at: previousManifestURL)
        try FileManager.default.removeItem(at: previousJournalURL)
        let previousProjectBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("project.json")
        )
        let previousMediaBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("media.json")
        )
        let previousRecoveryBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("recovery/snapshot.json")
        )
        let previousProjectFileNumber = try fileNumber(
            at: packageURL.appendingPathComponent("project.json")
        )
        let previousMediaFileNumber = try fileNumber(
            at: packageURL.appendingPathComponent("media.json")
        )

        XCTAssertTrue(model.addSequence())
        let attemptedProject = try XCTUnwrap(model.project)
        let synchronizationEvents = InPlaceSaveSynchronizationEvents(
            failingDirectoryURL: packageURL
        )
        var reachedCanonicalPublicationBoundary = false
        let store = EditorAjarDocumentStore(
            saveDidPublishRecovery: {
                reachedCanonicalPublicationBoundary = true
            },
            saveAsSynchronizer: RecordingInPlaceSaveSynchronizer(
                events: synchronizationEvents
            )
        )

        XCTAssertThrowsError(
            try store.save(
                project: attemptedProject,
                openMode: .editable,
                appliedCommandCount: 2,
                to: packageURL
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.saveAsSynchronization = error else {
                return XCTFail("Expected a typed durability failure, got \(error)")
            }
        }

        XCTAssertFalse(reachedCanonicalPublicationBoundary)
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("project.json")),
            previousProjectBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("media.json")),
            previousMediaBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("recovery/snapshot.json")),
            previousRecoveryBytes
        )
        XCTAssertEqual(
            try fileNumber(at: packageURL.appendingPathComponent("project.json")),
            previousProjectFileNumber
        )
        XCTAssertEqual(
            try fileNumber(at: packageURL.appendingPathComponent("media.json")),
            previousMediaFileNumber
        )
        XCTAssertEqual(
            try AjarAutosaveStore.recoverProject(from: packageURL).project,
            previousProject
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousJournalURL.path))
        XCTAssertEqual(try Data(contentsOf: sidecarURL), Data("sidecar".utf8))
        XCTAssertEqual(try Data(contentsOf: nestedSidecarURL), Data("nested sidecar".utf8))
        let sidecarSynchronizationPaths: [String] = synchronizationEvents.values.compactMap {
            event -> String? in
            guard case let .file(path) = event,
                  path.hasSuffix("/recovery/session.bin")
            else {
                return nil
            }
            return path
        }
        let nestedSidecarSynchronizationPaths: [String] = synchronizationEvents.values.compactMap {
            event -> String? in
            guard case let .file(path) = event,
                  path.hasSuffix("/recovery/plugins/session.bin")
            else {
                return nil
            }
            return path
        }
        // The staged replacement, immutable rollback backup, and disposable restoration copy must
        // each be synchronized independently. Distinct paths prove restoration did not consume the
        // retained backup while making the destination durable.
        XCTAssertEqual(sidecarSynchronizationPaths.count, 3)
        XCTAssertEqual(Set(sidecarSynchronizationPaths).count, 3)
        XCTAssertEqual(nestedSidecarSynchronizationPaths.count, 3)
        XCTAssertEqual(Set(nestedSidecarSynchronizationPaths).count, 3)
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testNFRSTAB002OpenRecoversBothCanonicalPairSplitsByInterruptedSave() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "SplitCanonicalPair.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)
        XCTAssertTrue(model.addSequence())
        try model.saveProject()
        let store = EditorAjarDocumentStore()
        let validVersionsBeforeInterruption = try store.versionSnapshotURLs(in: packageURL)
        XCTAssertEqual(validVersionsBeforeInterruption.count, 1)

        let duration = try RationalTime(value: 1, timescale: 1)
        let media = MediaRef(
            id: UUID(),
            sourceURL: fixture.rootURL.appendingPathComponent("interrupted.mov"),
            contentHash: ContentHash.sha256(data: Data("interrupted media".utf8)),
            metadata: MediaMetadata(
                codecID: "prores422",
                pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
                frameRate: try FrameRate(frames: 30),
                duration: duration,
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        XCTAssertTrue(model.applyEditForTesting(.addMediaReferences([media])))
        let sequence = try XCTUnwrap(model.project?.sequences.first)
        let track = try XCTUnwrap(sequence.videoTracks.first)
        let range = try TimeRange(start: .zero, duration: duration)
        let interruptedClip = Clip(
            id: UUID(),
            source: .media(id: media.id),
            sourceRange: range,
            timelineRange: range,
            kind: .video,
            name: "Interrupted Save Clip"
        )
        XCTAssertTrue(
            model.applyEditForTesting(
                .addClip(
                    sequenceID: sequence.id,
                    trackID: track.id,
                    clip: interruptedClip
                )
            )
        )
        let interruptedSaveProject = try XCTUnwrap(model.project)

        // Capture the real on-disk state after recovery and project.json publish, but before
        // media.json. The throwing hook then lets the source package roll back normally.
        let interruptedPackageURL = fixture.packageURL(named: "InterruptedCopy.ajar")
        let interruptingStore = EditorAjarDocumentStore(
            saveDidPublishProject: {
                try FileManager.default.copyItem(at: packageURL, to: interruptedPackageURL)
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: packageURL.path,
                    reason: "injected project-first boundary failure"
                )
            }
        )
        XCTAssertThrowsError(
            try interruptingStore.save(
                project: interruptedSaveProject,
                openMode: .editable,
                appliedCommandCount: 2,
                to: packageURL
            )
        )
        XCTAssertThrowsError(
            try AjarProjectCodec.decode(
                projectJSON: Data(
                    contentsOf: interruptedPackageURL.appendingPathComponent("project.json")
                ),
                mediaJSON: Data(
                    contentsOf: interruptedPackageURL.appendingPathComponent("media.json")
                )
            )
        )

        let driftedRecoveryPackageURL = fixture.packageURL(named: "DriftedRecovery.ajar")
        try FileManager.default.copyItem(
            at: interruptedPackageURL,
            to: driftedRecoveryPackageURL
        )
        try Data("tampered manifest".utf8).write(
            to: driftedRecoveryPackageURL.appendingPathComponent("recovery/manifest.json")
        )
        let driftedReopen = fixture.makeModel()
        XCTAssertThrowsError(try driftedReopen.openProject(at: driftedRecoveryPackageURL))
        XCTAssertNil(driftedReopen.project)

        let reopened = fixture.makeModel()
        try reopened.openProject(at: interruptedPackageURL)

        XCTAssertEqual(reopened.project, interruptedSaveProject)
        XCTAssertTrue(reopened.isDocumentDirty)
        XCTAssertEqual(reopened.loadMessage, "Opened project at the last recoverable edit")

        try reopened.saveProject()
        XCTAssertFalse(reopened.isDocumentDirty)
        let versionsAfterRepair = try store.versionSnapshotURLs(in: interruptedPackageURL)
        XCTAssertEqual(
            versionsAfterRepair.map(\.lastPathComponent),
            validVersionsBeforeInterruption.map(\.lastPathComponent)
        )
        for versionURL in versionsAfterRepair {
            XCTAssertNoThrow(
                try AjarProjectCodec.decode(
                    projectJSON: Data(
                        contentsOf: versionURL.appendingPathComponent("project.json")
                    ),
                    mediaJSON: Data(
                        contentsOf: versionURL.appendingPathComponent("media.json")
                    )
                )
            )
        }
        let cleanReopen = fixture.makeModel()
        try cleanReopen.openProject(at: interruptedPackageURL)
        XCTAssertEqual(cleanReopen.project, interruptedSaveProject)
        XCTAssertFalse(cleanReopen.isDocumentDirty)

        // Removing the clip and its media makes the inverse old-project/new-media split invalid.
        // Although media.json is replaced second in process order, an unsynchronized power loss can
        // persist it while retaining the previous project.json, so that state must recover too.
        let projectWithoutClip = try apply(
            .removeClip(
                sequenceID: sequence.id,
                trackID: track.id,
                clipID: interruptedClip.id
            ),
            to: interruptedSaveProject
        )
        let removedMediaProject = Project(
            schemaVersion: projectWithoutClip.schemaVersion,
            schemaMinor: projectWithoutClip.schemaMinor,
            settings: projectWithoutClip.settings,
            mediaPool: [],
            sequences: projectWithoutClip.sequences,
            looks: projectWithoutClip.looks
        )
        let previousProjectJSON = try Data(
            contentsOf: interruptedPackageURL.appendingPathComponent("project.json")
        )
        let savedPackage = try AjarProjectCodec.encode(
            removedMediaProject,
            openMode: .editable
        )
        let inverseSplitPackageURL = fixture.packageURL(named: "InverseSplit.ajar")
        let inverseInterruptingStore = EditorAjarDocumentStore(
            saveDidPublishProject: {
                try FileManager.default.copyItem(
                    at: interruptedPackageURL,
                    to: inverseSplitPackageURL
                )
                try previousProjectJSON.write(
                    to: inverseSplitPackageURL.appendingPathComponent("project.json")
                )
                try savedPackage.mediaJSON.write(
                    to: inverseSplitPackageURL.appendingPathComponent("media.json")
                )
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: interruptedPackageURL.path,
                    reason: "injected inverse durability ordering"
                )
            }
        )
        XCTAssertThrowsError(
            try inverseInterruptingStore.save(
                project: removedMediaProject,
                openMode: .editable,
                appliedCommandCount: 3,
                to: interruptedPackageURL
            )
        )
        XCTAssertThrowsError(
            try AjarProjectCodec.decode(
                projectJSON: Data(
                    contentsOf: inverseSplitPackageURL.appendingPathComponent("project.json")
                ),
                mediaJSON: Data(
                    contentsOf: inverseSplitPackageURL.appendingPathComponent("media.json")
                )
            )
        )

        let inverseReopen = fixture.makeModel()
        try inverseReopen.openProject(at: inverseSplitPackageURL)
        XCTAssertEqual(inverseReopen.project, removedMediaProject)
        XCTAssertTrue(inverseReopen.isDocumentDirty)
        try inverseReopen.saveProject()
        XCTAssertFalse(inverseReopen.isDocumentDirty)
    }

    func testNFRSTAB002OpenRejectsUnrelatedRecoveryForCorruptCanonicalPair() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "UnrelatedRecovery.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        XCTAssertTrue(model.addSequence())
        try AjarAutosaveStore.writeSnapshot(
            try XCTUnwrap(model.project),
            appliedCommandCount: 1,
            openMode: .editable,
            to: packageURL
        )
        try Data("unrelated corrupt project".utf8).write(
            to: packageURL.appendingPathComponent("project.json")
        )
        try Data("unrelated corrupt media".utf8).write(
            to: packageURL.appendingPathComponent("media.json")
        )

        let reopened = fixture.makeModel()
        XCTAssertThrowsError(try reopened.openProject(at: packageURL))
        XCTAssertNil(reopened.project)
    }

    func testNFRSTAB002OpenRejectsStaleRecoveryWhenOnlyUnchangedMediaMatches() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "StaleGeneration.ajar")
        let staleRecoveryURL = fixture.rootURL.appendingPathComponent(
            "StaleRecovery",
            isDirectory: true
        )
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        XCTAssertTrue(model.addSequence())
        try model.saveProject()
        let staleProject = try XCTUnwrap(model.project)
        try FileManager.default.copyItem(
            at: packageURL.appendingPathComponent("recovery", isDirectory: true),
            to: staleRecoveryURL
        )
        let unchangedMedia = try Data(
            contentsOf: packageURL.appendingPathComponent("media.json")
        )

        XCTAssertTrue(model.addSequence())
        try model.saveProject()
        XCTAssertNotEqual(model.project, staleProject)
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("media.json")),
            unchangedMedia
        )

        let recoveryURL = packageURL.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.removeItem(at: recoveryURL)
        try FileManager.default.copyItem(at: staleRecoveryURL, to: recoveryURL)
        try Data("corrupt newer project".utf8).write(
            to: packageURL.appendingPathComponent("project.json")
        )

        let reopened = fixture.makeModel()
        XCTAssertThrowsError(try reopened.openProject(at: packageURL))
        XCTAssertNil(reopened.project)
    }

    func testNFRSTAB002SaveRejectsSymlinkedRecoveryWithoutWritingOutsidePackage() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "SymlinkedRecovery.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)

        let externalRecoveryURL = fixture.rootURL.appendingPathComponent(
            "ExternalRecovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalRecoveryURL,
            withIntermediateDirectories: true
        )
        let externalSnapshotURL = externalRecoveryURL.appendingPathComponent("snapshot.json")
        let externalBytes = Data("must remain unchanged".utf8)
        try externalBytes.write(to: externalSnapshotURL)
        try FileManager.default.createSymbolicLink(
            at: packageURL.appendingPathComponent("recovery"),
            withDestinationURL: externalRecoveryURL
        )

        XCTAssertTrue(model.addSequence())
        XCTAssertThrowsError(try model.saveProject())

        XCTAssertEqual(try Data(contentsOf: externalSnapshotURL), externalBytes)
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testNFRSTAB002SaveRejectsSymlinkedCanonicalManifestsBeforePublication() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        for manifestName in ["project.json", "media.json"] {
            let packageURL = fixture.packageURL(named: "Symlinked-\(manifestName).ajar")
            let model = fixture.makeModel()
            try model.createNewProject(settings: .sensibleDefaults)
            try model.saveProjectAs(to: packageURL)
            let savedProject = try XCTUnwrap(model.project)

            let manifestURL = packageURL.appendingPathComponent(manifestName)
            let externalURL = fixture.rootURL.appendingPathComponent("external-\(manifestName)")
            let externalBytes = try Data(contentsOf: manifestURL)
            try externalBytes.write(to: externalURL)
            try FileManager.default.removeItem(at: manifestURL)
            try FileManager.default.createSymbolicLink(
                at: manifestURL,
                withDestinationURL: externalURL
            )

            let counterpartName = manifestName == "project.json" ? "media.json" : "project.json"
            let counterpartURL = packageURL.appendingPathComponent(counterpartName)
            let counterpartBytes = try Data(contentsOf: counterpartURL)
            let counterpartFileNumber = try fileNumber(at: counterpartURL)
            let packageEntries = try FileManager.default.contentsOfDirectory(atPath: packageURL.path)
                .sorted()

            XCTAssertThrowsError(
                try EditorAjarDocumentStore().save(
                    project: savedProject,
                    openMode: .editable,
                    appliedCommandCount: 0,
                    to: packageURL
                )
            ) { error in
                guard let documentError = error as? EditorAjarDocumentStoreError,
                    case .fileOperation(let path, let reason) = documentError
                else {
                    return XCTFail("Expected a typed canonical-manifest rejection, got \(error)")
                }
                XCTAssertEqual(path, manifestURL.path)
                XCTAssertTrue(reason.contains("symbolic links"))
            }

            XCTAssertEqual(try Data(contentsOf: externalURL), externalBytes)
            XCTAssertEqual(try Data(contentsOf: counterpartURL), counterpartBytes)
            XCTAssertEqual(try fileNumber(at: counterpartURL), counterpartFileNumber)
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: manifestURL.path),
                externalURL.path
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: packageURL.path).sorted(),
                packageEntries
            )
            XCTAssertTrue(try fixture.stagingPackages().isEmpty)
        }
    }

    func testFRPROJ002SaveAsCopiesCanonicalHistoryButNotRegeneratableCachesOrRecovery() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sourceURL = fixture.packageURL(named: "Source.ajar")
        let destinationURL = fixture.packageURL(named: "Destination.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: sourceURL)
        try FileManager.default.createDirectory(
            at: sourceURL.appendingPathComponent("caches"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourceURL.appendingPathComponent("recovery"),
            withIntermediateDirectories: true
        )
        try Data("cache".utf8).write(
            to: sourceURL.appendingPathComponent("caches/cache.bin")
        )
        try Data("recovery".utf8).write(
            to: sourceURL.appendingPathComponent("recovery/session.bin")
        )

        XCTAssertTrue(model.addSequence())
        try model.saveProjectAs(to: destinationURL)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.appendingPathComponent("project.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationURL.appendingPathComponent("media.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.appendingPathComponent("caches").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destinationURL.appendingPathComponent("recovery").path
        ))
    }

    func testFRPROJ001RecentProjectsPersistAppSideAndPromoteReopenedProject() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let firstURL = fixture.packageURL(named: "First.ajar")
        let secondURL = fixture.packageURL(named: "Second.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: firstURL)
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: secondURL)
        XCTAssertEqual(
            model.recentProjectURLs.map(\.standardizedFileURL),
            [secondURL.standardizedFileURL, firstURL.standardizedFileURL]
        )

        let relaunched = fixture.makeModel()
        XCTAssertEqual(
            relaunched.recentProjectURLs.map(\.standardizedFileURL),
            [secondURL.standardizedFileURL, firstURL.standardizedFileURL]
        )
        try relaunched.openProject(at: firstURL)
        XCTAssertEqual(
            relaunched.recentProjectURLs.map(\.standardizedFileURL),
            [firstURL.standardizedFileURL, secondURL.standardizedFileURL]
        )

        let projectBytes = try Data(
            contentsOf: firstURL.appendingPathComponent("project.json")
        )
        let mediaBytes = try Data(
            contentsOf: firstURL.appendingPathComponent("media.json")
        )
        XCTAssertNil(String(data: projectBytes, encoding: .utf8)?.range(of: "recentProjects"))
        XCTAssertNil(String(data: mediaBytes, encoding: .utf8)?.range(of: "recentProjects"))
    }

    func testFRPROJ001FailedRecentOpenRemovesAndRepersistsEntry() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let missingURL = fixture.packageURL(named: "Missing.ajar")
        let store = EditorAjarRecentProjectsStore(
            userDefaults: fixture.userDefaults,
            storageKey: fixture.recentProjectsStorageKey
        )
        _ = store.record(missingURL)

        let model = fixture.makeModel()
        XCTAssertEqual(model.recentProjectURLs.map(\.standardizedFileURL), [missingURL])
        XCTAssertThrowsError(try model.openRecentProject(at: missingURL))
        XCTAssertTrue(model.recentProjectURLs.isEmpty)
        XCTAssertTrue(fixture.makeModel().recentProjectURLs.isEmpty)
    }

    func testFRPROJ005ExplicitOpenPreservesReadOnlyModeAndRefusesResave() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "Future.ajar")
        let project = try EditorAjarNewProjectFactory.makeProject(settings: .sensibleDefaults)
        let higherMinor = AjarProjectCodec.currentSchemaMinor + 1
        try writeHigherMinorPackage(
            project: project,
            schemaMinor: higherMinor,
            to: packageURL
        )
        let originalProjectBytes = try Data(
            contentsOf: packageURL.appendingPathComponent("project.json")
        )

        let model = fixture.makeModel()
        try model.openProject(at: packageURL)
        XCTAssertTrue(model.isProjectReadOnly)
        XCTAssertTrue(model.isReadOnlyBannerVisible)
        XCTAssertFalse(model.canSaveProject)
        XCTAssertThrowsError(try model.saveProjectAs(to: fixture.packageURL(named: "Copy.ajar"))) {
            error in
            guard case EditorAjarDocumentLifecycleError.projectOpenedReadOnly = error else {
                return XCTFail("Expected typed read-only save refusal, got \(error)")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: packageURL.appendingPathComponent("project.json")),
            originalProjectBytes
        )
    }

    func testFRPROJ005CanonicalReadOnlyModeWinsOverStaleEditableRecovery() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "FutureWithOldRecovery.ajar")
        let project = try EditorAjarNewProjectFactory.makeProject(settings: .sensibleDefaults)
        try AjarAutosaveStore.writeSnapshot(
            project,
            appliedCommandCount: 0,
            openMode: .editable,
            to: packageURL
        )
        try AjarAutosaveStore.replaceJournal(with: [], in: packageURL)
        let higherMinor = AjarProjectCodec.currentSchemaMinor + 1
        try writeHigherMinorPackage(
            project: project,
            schemaMinor: higherMinor,
            to: packageURL
        )

        let model = fixture.makeModel()
        try model.openProject(at: packageURL)

        XCTAssertTrue(model.isProjectReadOnly)
        XCTAssertEqual(model.project?.schemaMinor, higherMinor)
        XCTAssertFalse(model.canSaveProject)
    }

    func testFRPROJ001TypedOpenErrorsUseLocalizedUserFacingDetails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.makeModel()
        let privatePath = "/Users/example/Secret/Missing.ajar"

        model.presentDocumentError(
            EditorAjarDocumentStoreError.packageNotFound(privatePath),
            operation: .open
        )

        let message = try XCTUnwrap(model.documentErrorMessage)
        XCTAssertEqual(
            message,
            "Could not open the project: The selected project could not be found."
        )
        XCTAssertFalse(message.contains("packageNotFound"))
        XCTAssertFalse(message.contains(privatePath))
    }

    func testFRPROJ002WindowAndQuitDelegatesRespectUnsavedDecision() {
        let windowDelegate = EditorAjarWindowStateBridge.Coordinator {
            false
        }
        XCTAssertFalse(windowDelegate.windowShouldClose(NSWindow()))
        windowDelegate.shouldCloseWindow = { true }
        XCTAssertTrue(windowDelegate.windowShouldClose(NSWindow()))

        let applicationDelegate = EditorAjarApplicationDelegate()
        applicationDelegate.shouldTerminate = { false }
        XCTAssertEqual(
            applicationDelegate.applicationShouldTerminate(NSApplication.shared),
            .terminateCancel
        )
        applicationDelegate.shouldTerminate = { true }
        XCTAssertEqual(
            applicationDelegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )
    }

    func testFRPROJ003FirstMediaAutoDetectionSeamUsesAvailableMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        let media = MediaRef(
            id: UUID(),
            sourceURL: fixture.rootURL.appendingPathComponent("first.mov"),
            contentHash: ContentHash.sha256(data: Data("first".utf8)),
            metadata: MediaMetadata(
                codecID: "prores422",
                pixelDimensions: PixelDimensions(width: 3_840, height: 2_160),
                frameRate: try FrameRate(frames: 24),
                duration: try RationalTime(value: 10, timescale: 1),
                colorSpace: .displayP3,
                audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )

        let detected = try XCTUnwrap(
            model.autoDetectedSettingsForFirstImportedMedia(
                media,
                detectedAudioSampleRate: 96_000
            )
        )
        XCTAssertEqual(detected.resolution, PixelDimensions(width: 3_840, height: 2_160))
        XCTAssertEqual(detected.frameRate, try FrameRate(frames: 24))
        XCTAssertEqual(detected.colorSpace, .displayP3)
        XCTAssertEqual(detected.audioSampleRate, 96_000)
    }

    private func makeFixture() throws -> DocumentLifecycleFixture {
        try DocumentLifecycleFixture()
    }

    private func fileNumber(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func eventIndex(
        in events: [InPlaceSaveSynchronizationEvents.Event],
        kind: InPlaceSaveSynchronizationEvents.Kind,
        pathSuffix: String
    ) throws -> Int {
        try XCTUnwrap(events.firstIndex { event in
            switch (kind, event) {
            case (.file, .file(let path)), (.directory, .directory(let path)):
                path.hasSuffix(pathSuffix)
            default:
                false
            }
        })
    }

    private func stagingRecoveryDirectoryIndex(
        in events: [InPlaceSaveSynchronizationEvents.Event],
        destinationRecoveryURL: URL
    ) throws -> Int {
        try XCTUnwrap(events.firstIndex { event in
            guard case .directory(let path) = event else {
                return false
            }
            return path.hasSuffix("/recovery")
                && URL(fileURLWithPath: path).standardizedFileURL
                    != destinationRecoveryURL.standardizedFileURL
        })
    }

    private func directoryEventIndex(
        in events: [InPlaceSaveSynchronizationEvents.Event],
        path: String,
        after precedingIndex: Int
    ) throws -> Int {
        try XCTUnwrap(events.indices.first { index in
            index > precedingIndex && events[index] == .directory(path)
        })
    }

    private func stagingDirectoryIndex(
        in events: [InPlaceSaveSynchronizationEvents.Event],
        named name: String,
        destinationURL: URL
    ) throws -> Int {
        try XCTUnwrap(events.firstIndex { event in
            guard case .directory(let path) = event else {
                return false
            }
            return path.hasSuffix("/\(name)")
                && URL(fileURLWithPath: path).standardizedFileURL
                    != destinationURL.standardizedFileURL
        })
    }

    private func writeHigherMinorPackage(
        project: Project,
        schemaMinor: Int,
        to packageURL: URL
    ) throws {
        let document = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: schemaMinor,
            settings: project.settings,
            mediaPool: [],
            sequences: project.sequences,
            looks: project.looks
        )
        let manifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: schemaMinor,
            media: project.mediaPool
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try encoder.encode(document).write(
            to: packageURL.appendingPathComponent("project.json")
        )
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent("media.json")
        )
    }
}

private struct DocumentLifecycleFixture {
    let rootURL: URL
    let userDefaults: UserDefaults
    let userDefaultsSuiteName: String
    let recentProjectsStorageKey: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "editor-ajar-document-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        userDefaultsSuiteName = "org.editorajar.tests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: userDefaultsSuiteName))
        recentProjectsStorageKey = "document.recentProjects.\(UUID().uuidString)"
    }

    func packageURL(named name: String) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: true)
    }

    func stagingPackages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".staging") }
    }

    @MainActor
    func makeModel(
        documentStore: EditorAjarDocumentStore = EditorAjarDocumentStore()
    ) -> EditorAjarAppModel {
        EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            documentStore: documentStore,
            recentProjectsUserDefaults: userDefaults,
            recentProjectsStorageKey: recentProjectsStorageKey
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}

private final class InPlaceSaveSynchronizationEvents {
    enum Kind {
        case file
        case directory
    }

    enum Event: Equatable {
        case file(String)
        case directory(String)
        case recoveryPublished
        case contentsPublished
    }

    var values: [Event] = []
    let failingDirectoryURL: URL?
    let shouldFailDirectory: () -> Bool
    var remainingDirectoryMatchesBeforeFailure: Int
    var remainingDirectoryFailures: Int

    init(
        failingDirectoryURL: URL? = nil,
        directoryFailureMatchOffset: Int = 0,
        shouldFailDirectory: @escaping () -> Bool = { true }
    ) {
        self.failingDirectoryURL = failingDirectoryURL
        self.shouldFailDirectory = shouldFailDirectory
        remainingDirectoryMatchesBeforeFailure = directoryFailureMatchOffset
        remainingDirectoryFailures = failingDirectoryURL == nil ? 0 : 1
    }
}

private struct RecordingInPlaceSaveSynchronizer: EditorAjarSaveAsSynchronizing {
    let events: InPlaceSaveSynchronizationEvents

    func synchronizeFile(at url: URL) throws {
        events.values.append(.file(url.path))
    }

    func synchronizeDirectory(at url: URL, descriptor _: Int32?) throws {
        events.values.append(.directory(url.path))
        if url.standardizedFileURL == events.failingDirectoryURL?.standardizedFileURL,
            events.remainingDirectoryFailures > 0,
            events.shouldFailDirectory()
        {
            if events.remainingDirectoryMatchesBeforeFailure > 0 {
                events.remainingDirectoryMatchesBeforeFailure -= 1
                return
            }
            events.remainingDirectoryFailures -= 1
            throw EditorAjarDocumentStoreError.saveAsSynchronization(
                path: url.path,
                operation: "injected in-place Save directory synchronization failure",
                code: EIO
            )
        }
    }
}
