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

    func testFRPROJ002SavePublishesCanonicalFilesWithoutReplacingCachesOrRecovery() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let packageURL = fixture.packageURL(named: "InPlace.ajar")
        let model = fixture.makeModel()
        try model.createNewProject(settings: .sensibleDefaults)
        try model.saveProjectAs(to: packageURL)
        let cacheURL = packageURL.appendingPathComponent("caches/render/cache.bin")
        let recoveryURL = packageURL.appendingPathComponent("recovery/session.bin")
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: recoveryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cache".utf8).write(to: cacheURL)
        try Data("recovery".utf8).write(to: recoveryURL)

        XCTAssertTrue(model.addSequence())
        try model.saveProject()

        XCTAssertEqual(try Data(contentsOf: cacheURL), Data("cache".utf8))
        XCTAssertEqual(try Data(contentsOf: recoveryURL), Data("recovery".utf8))
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

    @MainActor
    func makeModel() -> EditorAjarAppModel {
        EditorAjarAppModel(
            autosaveIntervalSeconds: 0,
            recentProjectsUserDefaults: userDefaults,
            recentProjectsStorageKey: recentProjectsStorageKey
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}
