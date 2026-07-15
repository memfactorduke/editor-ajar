// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Darwin
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarPackageMediaSaveAsTests: XCTestCase {
    func testFRMED008SaveAsCopiesOnlyPackageMediaAndRebasesCurrentAndVersionReferences() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let sourceMediaDirectory = sourcePackage.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceMediaDirectory,
            withIntermediateDirectories: true
        )
        let packageBytes = Data("durable consolidated media".utf8)
        let packageMedia = sourceMediaDirectory.appendingPathComponent("clip.mov")
        try packageBytes.write(to: packageMedia)
        let externalBytes = Data("external original must remain external".utf8)
        let externalMedia = fixture.rootURL.appendingPathComponent("external.mov")
        try externalBytes.write(to: externalMedia)
        let bookmarks = PackageMediaSaveAsBookmarkStore()
        let packageReference = try fixture.mediaReference(
            sourceURL: packageMedia,
            bookmark: bookmarks.createBookmark(for: packageMedia),
            bytes: packageBytes
        )
        let externalReference = try fixture.mediaReference(
            sourceURL: externalMedia,
            bookmark: bookmarks.createBookmark(for: externalMedia),
            bytes: externalBytes
        )
        let project = try fixture.project(media: [packageReference, externalReference])
        try fixture.write(project: project, to: sourcePackage)
        let store = EditorAjarDocumentStore(bookmarkStore: bookmarks)

        let saveAsResult = try store.saveAs(
            project: project,
            openMode: .editable,
            appliedCommandCount: 0,
            sourceURL: sourcePackage,
            destinationURL: destinationPackage
        )
        let saved = saveAsResult.project

        let copiedURL = destinationPackage.appendingPathComponent("media/clip.mov")
        XCTAssertEqual(saved.mediaPool[0].sourceURL, copiedURL)
        XCTAssertEqual(
            try bookmarks.resolveBookmark(try XCTUnwrap(saved.mediaPool[0].bookmark)).url,
            copiedURL
        )
        XCTAssertEqual(try Data(contentsOf: copiedURL), packageBytes)
        XCTAssertEqual(saved.mediaPool[0].id, packageReference.id)
        XCTAssertEqual(saved.mediaPool[0].contentHash, packageReference.contentHash)
        XCTAssertEqual(saved.mediaPool[0].metadata, packageReference.metadata)
        XCTAssertEqual(saved.mediaPool[0].proxyState, packageReference.proxyState)
        XCTAssertEqual(saved.mediaPool[1], externalReference)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationPackage.appendingPathComponent("media/external.mov").path
            )
        )

        let snapshots = try store.versionSnapshotURLs(in: destinationPackage)
        XCTAssertEqual(snapshots.count, 1)
        let snapshot = try store.revert(at: try XCTUnwrap(snapshots.first)).project
        XCTAssertEqual(snapshot.mediaPool[0].sourceURL, copiedURL)
        XCTAssertEqual(
            try bookmarks.resolveBookmark(try XCTUnwrap(snapshot.mediaPool[0].bookmark)).url,
            copiedURL
        )
        XCTAssertEqual(snapshot.mediaPool[1], externalReference)

        try FileManager.default.removeItem(at: sourcePackage)
        XCTAssertEqual(try store.open(at: destinationPackage).loadResult.project, saved)
        XCTAssertEqual(try Data(contentsOf: copiedURL), packageBytes)
        XCTAssertEqual(try Data(contentsOf: externalMedia), externalBytes)
    }

    func testFRMED008SaveAsRefusesPackageMediaSymlinkWithoutPublishingDestination() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let sourceMediaDirectory = sourcePackage.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceMediaDirectory,
            withIntermediateDirectories: true
        )
        let externalBytes = Data("symlink target original".utf8)
        let externalURL = fixture.rootURL.appendingPathComponent("outside.mov")
        try externalBytes.write(to: externalURL)
        let symlinkURL = sourceMediaDirectory.appendingPathComponent("unsafe.mov")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: externalURL)
        let bookmarks = PackageMediaSaveAsBookmarkStore()
        let media = try fixture.mediaReference(
            sourceURL: symlinkURL,
            bookmark: bookmarks.createBookmark(for: symlinkURL),
            bytes: externalBytes
        )
        let project = try fixture.project(media: [media])
        try fixture.write(project: project, to: sourcePackage)
        let store = EditorAjarDocumentStore(bookmarkStore: bookmarks)

        XCTAssertThrowsError(
            try store.saveAs(
                project: project,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPackage.path))
        XCTAssertEqual(try Data(contentsOf: externalURL), externalBytes)
        XCTAssertEqual(try Data(contentsOf: symlinkURL), externalBytes)
    }

    func testFRMED008SaveAsCopyFailurePreservesSourceAndExistingDestination() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let sourceMediaDirectory = sourcePackage.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceMediaDirectory,
            withIntermediateDirectories: true
        )
        let bytes = Data("copy failure original".utf8)
        let sourceMedia = sourceMediaDirectory.appendingPathComponent("clip.mov")
        try bytes.write(to: sourceMedia)
        let bookmarks = PackageMediaSaveAsBookmarkStore()
        let media = try fixture.mediaReference(
            sourceURL: sourceMedia,
            bookmark: bookmarks.createBookmark(for: sourceMedia),
            bytes: bytes
        )
        let sourceProject = try fixture.project(media: [media])
        let destinationProject = try fixture.project(media: [])
        try fixture.write(project: sourceProject, to: sourcePackage)
        try fixture.write(project: destinationProject, to: destinationPackage)
        let projectBytes = try Data(
            contentsOf: destinationPackage.appendingPathComponent("project.json")
        )
        let mediaBytes = try Data(
            contentsOf: destinationPackage.appendingPathComponent("media.json")
        )
        let store = EditorAjarDocumentStore(
            bookmarkStore: bookmarks,
            mediaFileCopier: FailingPackageMediaFileCopier()
        )

        XCTAssertThrowsError(
            try store.saveAs(
                project: sourceProject,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: destinationPackage.appendingPathComponent("project.json")),
            projectBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: destinationPackage.appendingPathComponent("media.json")),
            mediaBytes
        )
        XCTAssertEqual(try Data(contentsOf: sourceMedia), bytes)
    }

    func testFRMED008SaveAsRefusesToDeleteMediaReferencedByRetainedVersion() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let destinationMediaDirectory = destinationPackage.appendingPathComponent(
            "media",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationMediaDirectory,
            withIntermediateDirectories: true
        )
        let referencedBytes = Data("retained version destination media".utf8)
        let referencedURL = destinationMediaDirectory.appendingPathComponent("retained.mov")
        try referencedBytes.write(to: referencedURL)
        let bookmarks = PackageMediaSaveAsBookmarkStore()
        let retainedReference = try fixture.mediaReference(
            sourceURL: referencedURL,
            bookmark: bookmarks.createBookmark(for: referencedURL),
            bytes: referencedBytes
        )
        let currentProject = try fixture.project(media: [])
        let retainedProject = try fixture.project(media: [retainedReference])
        try fixture.write(project: currentProject, to: sourcePackage)
        try fixture.write(project: currentProject, to: destinationPackage)
        try fixture.write(
            project: retainedProject,
            to: sourcePackage.appendingPathComponent("versions/save-0", isDirectory: true)
        )
        let destinationProjectBytes = try Data(
            contentsOf: destinationPackage.appendingPathComponent("project.json")
        )
        let store = EditorAjarDocumentStore(bookmarkStore: bookmarks)

        XCTAssertThrowsError(
            try store.saveAs(
                project: currentProject,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        )
        XCTAssertEqual(try Data(contentsOf: referencedURL), referencedBytes)
        XCTAssertEqual(
            try Data(contentsOf: destinationPackage.appendingPathComponent("project.json")),
            destinationProjectBytes
        )
    }

    func testFRMED008UndoneConsolidationSurvivesSaveAsAndRedoAfterSourceDeletion() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let sourceMediaDirectory = sourcePackage.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceMediaDirectory,
            withIntermediateDirectories: true
        )
        let bytes = Data("undo-only consolidated media".utf8)
        let externalURL = fixture.rootURL.appendingPathComponent("original.mov")
        let consolidatedURL = sourceMediaDirectory.appendingPathComponent("consolidated.mov")
        try bytes.write(to: externalURL)
        try bytes.write(to: consolidatedURL)
        let bookmarks = PackageMediaSaveAsBookmarkStore()
        let original = try fixture.mediaReference(
            sourceURL: externalURL,
            bookmark: bookmarks.createBookmark(for: externalURL),
            bytes: bytes
        )
        let consolidated = original.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: consolidatedURL,
                contentHash: original.contentHash,
                bookmark: try bookmarks.createBookmark(for: consolidatedURL)
            )
        )
        let originalProject = try fixture.project(media: [original])
        try fixture.write(project: originalProject, to: sourcePackage)
        var history = EditHistory(project: originalProject)
        _ = try history.apply(
            .updateMediaReferences(kind: .consolidate, replacements: [consolidated])
        )
        _ = history.undo()

        let result = try EditorAjarDocumentStore(bookmarkStore: bookmarks).saveAs(
            project: history.currentProject,
            editHistory: history,
            openMode: .editable,
            appliedCommandCount: 1,
            sourceURL: sourcePackage,
            destinationURL: destinationPackage
        )
        try FileManager.default.removeItem(at: sourcePackage)

        var savedHistory = try XCTUnwrap(result.editHistory)
        let restored = try XCTUnwrap(try savedHistory.redo()?.mediaPool.first)
        let copiedURL = destinationPackage.appendingPathComponent("media/consolidated.mov")
        XCTAssertEqual(restored.sourceURL, copiedURL)
        XCTAssertEqual(
            try bookmarks.resolveBookmark(try XCTUnwrap(restored.bookmark)).url,
            copiedURL
        )
        XCTAssertEqual(try Data(contentsOf: copiedURL), bytes)
        XCTAssertEqual(savedHistory.undo()?.mediaPool, [original])
        XCTAssertEqual(try savedHistory.redo()?.mediaPool, [restored])
    }

    func testFRMED008PostConsolidationRelinkRestoresNewPackageMediaAfterSaveAs() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let sourceMediaDirectory = sourcePackage.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceMediaDirectory,
            withIntermediateDirectories: true
        )
        let bytes = Data("post-consolidation relink media".utf8)
        let originalURL = fixture.rootURL.appendingPathComponent("original.mov")
        let relinkedURL = fixture.rootURL.appendingPathComponent("relinked.mov")
        let consolidatedURL = sourceMediaDirectory.appendingPathComponent("consolidated.mov")
        try bytes.write(to: originalURL)
        try bytes.write(to: relinkedURL)
        try bytes.write(to: consolidatedURL)
        let bookmarks = PackageMediaSaveAsBookmarkStore()
        let original = try fixture.mediaReference(
            sourceURL: originalURL,
            bookmark: bookmarks.createBookmark(for: originalURL),
            bytes: bytes
        )
        let consolidated = original.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: consolidatedURL,
                contentHash: original.contentHash,
                bookmark: try bookmarks.createBookmark(for: consolidatedURL)
            )
        )
        let relinked = original.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: relinkedURL,
                contentHash: original.contentHash,
                bookmark: try bookmarks.createBookmark(for: relinkedURL)
            )
        )
        let originalProject = try fixture.project(media: [original])
        var history = EditHistory(project: originalProject)
        _ = try history.apply(
            .updateMediaReferences(kind: .consolidate, replacements: [consolidated])
        )
        _ = try history.apply(.updateMediaReferences(kind: .relink, replacements: [relinked]))
        try fixture.write(project: history.currentProject, to: sourcePackage)

        let result = try EditorAjarDocumentStore(bookmarkStore: bookmarks).saveAs(
            project: history.currentProject,
            editHistory: history,
            openMode: .editable,
            appliedCommandCount: 2,
            sourceURL: sourcePackage,
            destinationURL: destinationPackage
        )
        try FileManager.default.removeItem(at: sourcePackage)

        var savedHistory = try XCTUnwrap(result.editHistory)
        let restored = try XCTUnwrap(savedHistory.undo()?.mediaPool.first)
        let copiedURL = destinationPackage.appendingPathComponent("media/consolidated.mov")
        XCTAssertEqual(restored.sourceURL, copiedURL)
        XCTAssertEqual(
            try bookmarks.resolveBookmark(try XCTUnwrap(restored.bookmark)).url,
            copiedURL
        )
        XCTAssertEqual(try Data(contentsOf: copiedURL), bytes)
        XCTAssertEqual(try savedHistory.redo()?.mediaPool, [relinked])
        XCTAssertEqual(savedHistory.undo()?.mediaPool, [restored])
    }

    func testSaveAsRefusesPresentDestinationSubstitutionBeforePublication() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let preservedDestination = fixture.packageURL(named: "Preserved.ajar")
        let sourceProject = try fixture.project(media: [])
        let originalDestinationProject = try fixture.project(media: [])
        let substituteProject = try fixture.project(media: [])
        try fixture.write(project: sourceProject, to: sourcePackage)
        try fixture.write(project: originalDestinationProject, to: destinationPackage)
        let originalBytes = try fixture.manifestBytes(at: destinationPackage)
        let store = EditorAjarDocumentStore(saveAsWillPublish: {
            try FileManager.default.moveItem(at: destinationPackage, to: preservedDestination)
            try fixture.write(project: substituteProject, to: destinationPackage)
        })

        XCTAssertThrowsError(
            try store.saveAs(
                project: sourceProject,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.saveAsDestinationChanged = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try fixture.manifestBytes(at: preservedDestination), originalBytes)
        XCTAssertEqual(
            try EditorAjarDocumentStore().open(at: destinationPackage).loadResult.project,
            substituteProject
        )
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testSaveAsRestoresExactDestinationSubstitutedAfterPublicationRevalidation() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let preservedDestination = fixture.packageURL(named: "Preserved.ajar")
        let sourceProject = try fixture.project(media: [])
        let originalDestinationProject = try fixture.project(media: [])
        let substituteProject = try fixture.project(media: [])
        try fixture.write(project: sourceProject, to: sourcePackage)
        try fixture.write(project: originalDestinationProject, to: destinationPackage)
        let originalBytes = try fixture.manifestBytes(at: destinationPackage)
        let store = EditorAjarDocumentStore(saveAsDidRevalidatePublication: {
            try FileManager.default.moveItem(at: destinationPackage, to: preservedDestination)
            try fixture.write(project: substituteProject, to: destinationPackage)
        })

        XCTAssertThrowsError(
            try store.saveAs(
                project: sourceProject,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.saveAsDestinationChanged = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try EditorAjarDocumentStore().open(at: destinationPackage).loadResult.project,
            substituteProject,
            "rollback must restore the entry actually displaced by the exchange"
        )
        XCTAssertEqual(try fixture.manifestBytes(at: preservedDestination), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testSaveAsCleanupDoesNotTraverseTreeSubstitutedAfterQuarantineValidation() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let preservedQuarantine = fixture.packageURL(named: "Preserved-Quarantine")
        let project = try fixture.project(media: [])
        let unrelatedBytes = Data("unrelated cleanup substitution".utf8)
        try fixture.write(project: project, to: sourcePackage)
        let store = EditorAjarDocumentStore(
            saveAsWillPublish: {
                throw NSError(
                    domain: "EditorAjarPackageMediaSaveAsTests",
                    code: 267,
                    userInfo: [NSLocalizedDescriptionKey: "injected pre-publication failure"]
                )
            },
            saveAsDidRevalidateCleanup: { quarantineURL in
                try FileManager.default.moveItem(
                    at: quarantineURL,
                    to: preservedQuarantine
                )
                try FileManager.default.createDirectory(
                    at: quarantineURL,
                    withIntermediateDirectories: false
                )
                try unrelatedBytes.write(
                    to: quarantineURL.appendingPathComponent("must-survive.txt")
                )
            }
        )

        XCTAssertThrowsError(
            try store.saveAs(
                project: project,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.fileOperation = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let cleanupSubstitution = try FileManager.default.contentsOfDirectory(
            at: fixture.rootURL,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasSuffix(".cleanup") }
        let unrelatedTree = try XCTUnwrap(cleanupSubstitution)
        XCTAssertEqual(
            try Data(contentsOf: unrelatedTree.appendingPathComponent("must-survive.txt")),
            unrelatedBytes,
            "cleanup must not recursively follow the substituted quarantine path"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedQuarantine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPackage.path))
    }

    func testSaveAsCleanupRestoresTreeSubstitutedImmediatelyBeforeQuarantine() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let preservedOwnedStaging = fixture.packageURL(named: "Preserved-Owned-Staging")
        let project = try fixture.project(media: [])
        let unrelatedBytes = Data("pre-quarantine unrelated tree".utf8)
        var substitutedSourceURL: URL?
        try fixture.write(project: project, to: sourcePackage)
        let store = EditorAjarDocumentStore(
            saveAsWillPublish: {
                throw NSError(
                    domain: "EditorAjarPackageMediaSaveAsTests",
                    code: 267,
                    userInfo: [NSLocalizedDescriptionKey: "injected pre-publication failure"]
                )
            },
            saveAsWillQuarantineCleanup: { sourceURL in
                substitutedSourceURL = sourceURL
                try FileManager.default.moveItem(at: sourceURL, to: preservedOwnedStaging)
                let unrelatedDirectory = sourceURL.appendingPathComponent(
                    "unrelated",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: unrelatedDirectory,
                    withIntermediateDirectories: true
                )
                try unrelatedBytes.write(
                    to: unrelatedDirectory.appendingPathComponent("must-survive.txt")
                )
            }
        )

        XCTAssertThrowsError(
            try store.saveAs(
                project: project,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.fileOperation = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let restoredSourceURL = try XCTUnwrap(substitutedSourceURL)
        XCTAssertEqual(
            try Data(
                contentsOf: restoredSourceURL.appendingPathComponent(
                    "unrelated/must-survive.txt"
                )
            ),
            unrelatedBytes,
            "the unexpected tree must be restored to the exact source name"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: restoredSourceURL.path),
            ["unrelated"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedOwnedStaging.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
                .contains { $0.hasSuffix(".cleanup") }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPackage.path))
    }

    func testSaveAsCleanupReversesUnintendedRestoreExchangeWithoutRelocatingEntries() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let preservedOwnedStaging = fixture.packageURL(named: "Preserved-Owned-Staging")
        let preservedRestoreSource = fixture.packageURL(named: "Preserved-Restore-Source")
        let preservedRestoreQuarantine = fixture.packageURL(
            named: "Preserved-Restore-Quarantine"
        )
        let project = try fixture.project(media: [])
        let sourceBytes = Data("restore source entry".utf8)
        let quarantineBytes = Data("restore quarantine entry".utf8)
        var restoreSourceURL: URL?
        var restoreQuarantineURL: URL?
        try fixture.write(project: project, to: sourcePackage)
        let store = EditorAjarDocumentStore(
            saveAsWillPublish: {
                throw NSError(
                    domain: "EditorAjarPackageMediaSaveAsTests",
                    code: 267,
                    userInfo: [NSLocalizedDescriptionKey: "injected pre-publication failure"]
                )
            },
            saveAsWillQuarantineCleanup: { sourceURL in
                try FileManager.default.moveItem(at: sourceURL, to: preservedOwnedStaging)
                try FileManager.default.createDirectory(
                    at: sourceURL,
                    withIntermediateDirectories: false
                )
            },
            saveAsWillRestoreUnexpectedQuarantine: { sourceURL, quarantineURL in
                restoreSourceURL = sourceURL
                restoreQuarantineURL = quarantineURL
                try FileManager.default.moveItem(at: sourceURL, to: preservedRestoreSource)
                try FileManager.default.moveItem(
                    at: quarantineURL,
                    to: preservedRestoreQuarantine
                )
                try FileManager.default.createDirectory(
                    at: sourceURL,
                    withIntermediateDirectories: false
                )
                try sourceBytes.write(to: sourceURL.appendingPathComponent("source.txt"))
                try FileManager.default.createDirectory(
                    at: quarantineURL,
                    withIntermediateDirectories: false
                )
                try quarantineBytes.write(
                    to: quarantineURL.appendingPathComponent("quarantine.txt")
                )
            }
        )

        XCTAssertThrowsError(
            try store.saveAs(
                project: project,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.fileOperation = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let exactSourceURL = try XCTUnwrap(restoreSourceURL)
        let exactQuarantineURL = try XCTUnwrap(restoreQuarantineURL)
        XCTAssertEqual(
            try Data(contentsOf: exactSourceURL.appendingPathComponent("source.txt")),
            sourceBytes
        )
        XCTAssertEqual(
            try Data(
                contentsOf: exactQuarantineURL.appendingPathComponent("quarantine.txt")
            ),
            quarantineBytes
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: exactSourceURL.path),
            ["source.txt"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: exactQuarantineURL.path),
            ["quarantine.txt"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path)
                .filter { $0.hasSuffix(".cleanup") },
            [exactQuarantineURL.lastPathComponent],
            "the reverse exchange must not create another hidden relocation"
        )
    }

    func testSaveAsCleanupStopsBeforeTraversingInjectedCrossDeviceDirectory() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let project = try fixture.project(media: [])
        let childBytes = Data("simulated mounted filesystem contents".utf8)
        var boundaryURL: URL?
        try fixture.write(project: project, to: sourcePackage)
        let store = EditorAjarDocumentStore(
            saveAsWillPublish: {
                let stagingURL = try XCTUnwrap(fixture.stagingPackages().first)
                let mountedChild = stagingURL.appendingPathComponent(
                    "mounted-child",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: mountedChild,
                    withIntermediateDirectories: false
                )
                try childBytes.write(to: mountedChild.appendingPathComponent("must-survive.txt"))
                throw NSError(
                    domain: "EditorAjarPackageMediaSaveAsTests",
                    code: 267,
                    userInfo: [NSLocalizedDescriptionKey: "injected pre-publication failure"]
                )
            },
            saveAsCleanupDirectoryDevice: { directoryURL, actualDevice in
                guard directoryURL.lastPathComponent == "mounted-child" else {
                    return actualDevice
                }
                boundaryURL = directoryURL
                return actualDevice &+ 1
            }
        )

        XCTAssertThrowsError(
            try store.saveAs(
                project: project,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.fileOperation = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let rejectedBoundary = try XCTUnwrap(boundaryURL)
        XCTAssertEqual(
            try Data(contentsOf: rejectedBoundary.appendingPathComponent("must-survive.txt")),
            childBytes,
            "device policy must reject the child before recursively deleting its contents"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPackage.path))
    }

    func testSaveAsCommitsReplacementAndReturnsWarningWhenOldPackageCleanupIsRetained() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let baseProject = try fixture.project(media: [])
        var history = EditHistory(project: baseProject)
        let addedSequence = Sequence(
            id: UUID(),
            name: "Retained cleanup history",
            videoTracks: [Track(id: UUID(), kind: .video, items: [])],
            audioTracks: [Track(id: UUID(), kind: .audio, items: [])],
            markers: [],
            timebase: baseProject.settings.frameRate
        )
        _ = try history.apply(.addSequence(addedSequence))
        let committedProject = history.currentProject
        try fixture.write(project: committedProject, to: sourcePackage)
        try fixture.write(project: baseProject, to: destinationPackage)
        let retainedChild = destinationPackage.appendingPathComponent(
            "retained-child",
            isDirectory: true
        )
        let retainedBytes = Data("old package manual recovery data".utf8)
        try FileManager.default.createDirectory(
            at: retainedChild,
            withIntermediateDirectories: false
        )
        try retainedBytes.write(to: retainedChild.appendingPathComponent("must-survive.txt"))
        let store = EditorAjarDocumentStore(
            saveAsCleanupDirectoryDevice: { directoryURL, actualDevice in
                directoryURL.lastPathComponent == "retained-child"
                    ? actualDevice &+ 1
                    : actualDevice
            }
        )

        let result = try store.saveAs(
            project: committedProject,
            editHistory: history,
            openMode: .editable,
            appliedCommandCount: 1,
            sourceURL: sourcePackage,
            destinationURL: destinationPackage
        )

        XCTAssertEqual(result.project, committedProject)
        XCTAssertEqual(
            try EditorAjarDocumentStore().open(at: destinationPackage).loadResult.project,
            committedProject,
            "a post-commit cleanup warning must not roll back the published destination"
        )
        var committedHistory = try XCTUnwrap(result.editHistory)
        XCTAssertEqual(committedHistory.currentProject, committedProject)
        XCTAssertEqual(committedHistory.undo(), baseProject)
        XCTAssertEqual(try committedHistory.redo(), committedProject)
        let warning = try XCTUnwrap(result.cleanupWarning)
        guard case .retainedPackage(let retainedURL, let cleanupError) = warning else {
            return XCTFail("expected a verified retained-package warning: \(warning)")
        }
        XCTAssertEqual(
            try Data(
                contentsOf: retainedURL.appendingPathComponent(
                    "retained-child/must-survive.txt"
                )
            ),
            retainedBytes,
            "old-package cleanup data must remain available for manual recovery"
        )
        guard case EditorAjarDocumentStoreError.saveAsDestinationChanged = cleanupError else {
            return XCTFail("unexpected cleanup warning: \(cleanupError)")
        }
    }

    func testSaveAsCleanupWarningHasNoLocationAfterUnexpectedEntryIsRestored() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let preservedPreviousDestination = fixture.packageURL(
            named: "Preserved-Previous-Destination.ajar"
        )
        let sourceProject = try fixture.project(media: [])
        let previousDestinationProject = try fixture.project(media: [])
        let unrelatedBytes = Data("post-commit cleanup substitution".utf8)
        var restoredUnexpectedURL: URL?
        try fixture.write(project: sourceProject, to: sourcePackage)
        try fixture.write(project: previousDestinationProject, to: destinationPackage)
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

        let result = try store.saveAs(
            project: sourceProject,
            openMode: .editable,
            appliedCommandCount: 0,
            sourceURL: sourcePackage,
            destinationURL: destinationPackage
        )

        XCTAssertEqual(
            try EditorAjarDocumentStore().open(at: destinationPackage).loadResult.project,
            sourceProject
        )
        guard case .skippedSafely(let cleanupError) = try XCTUnwrap(result.cleanupWarning) else {
            return XCTFail("an identity-changing cleanup must not expose a retained URL")
        }
        guard case EditorAjarDocumentStoreError.saveAsDestinationChanged = cleanupError else {
            return XCTFail("unexpected cleanup warning: \(cleanupError)")
        }
        let exactRestoredURL = try XCTUnwrap(restoredUnexpectedURL)
        XCTAssertEqual(
            try Data(contentsOf: exactRestoredURL.appendingPathComponent("must-survive.txt")),
            unrelatedBytes
        )
        XCTAssertEqual(
            try EditorAjarDocumentStore().open(at: preservedPreviousDestination).loadResult.project,
            previousDestinationProject
        )
    }

    func testSaveAsCleanupWarningHasNoLocationWhenParentValidationFailsBeforeQuarantine() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let sourceProject = try fixture.project(media: [])
        let previousDestinationProject = try fixture.project(media: [])
        var didReachParentValidation = false
        try fixture.write(project: sourceProject, to: sourcePackage)
        try fixture.write(project: previousDestinationProject, to: destinationPackage)
        let previousDestinationBytes = try fixture.manifestBytes(at: destinationPackage)
        let store = EditorAjarDocumentStore(
            saveAsWillValidatePreviousDestinationCleanup: {
                didReachParentValidation = true
                throw EditorAjarDocumentStoreError.saveAsDestinationChanged(
                    path: fixture.rootURL.path,
                    reason: "injected pre-quarantine parent validation refusal"
                )
            }
        )

        let result = try store.saveAs(
            project: sourceProject,
            openMode: .editable,
            appliedCommandCount: 0,
            sourceURL: sourcePackage,
            destinationURL: destinationPackage
        )

        XCTAssertTrue(didReachParentValidation)
        XCTAssertEqual(
            try EditorAjarDocumentStore().open(at: destinationPackage).loadResult.project,
            sourceProject
        )
        guard case .skippedSafely(let cleanupError) = try XCTUnwrap(result.cleanupWarning) else {
            return XCTFail("pre-quarantine refusal must not invent a retained package URL")
        }
        guard case EditorAjarDocumentStoreError.saveAsDestinationChanged = cleanupError else {
            return XCTFail("unexpected cleanup warning: \(cleanupError)")
        }
        let retainedStaging = try XCTUnwrap(fixture.stagingPackages().first)
        XCTAssertEqual(
            try fixture.manifestBytes(at: retainedStaging),
            previousDestinationBytes,
            "the refused cleanup target must remain intact for recovery"
        )
    }

    func testSaveAsRefusesDestinationThatAppearsAfterExpectedAbsence() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let sourceProject = try fixture.project(media: [])
        let appearedProject = try fixture.project(media: [])
        try fixture.write(project: sourceProject, to: sourcePackage)
        let store = EditorAjarDocumentStore(saveAsWillPublish: {
            try fixture.write(project: appearedProject, to: destinationPackage)
        })

        XCTAssertThrowsError(
            try store.saveAs(
                project: sourceProject,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.saveAsDestinationChanged = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try EditorAjarDocumentStore().open(at: destinationPackage).loadResult.project,
            appearedProject
        )
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testSaveAsRefusesValidatedDestinationThatDisappears() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let preservedDestination = fixture.packageURL(named: "Preserved.ajar")
        let project = try fixture.project(media: [])
        try fixture.write(project: project, to: sourcePackage)
        try fixture.write(project: project, to: destinationPackage)
        let store = EditorAjarDocumentStore(saveAsWillPublish: {
            try FileManager.default.moveItem(at: destinationPackage, to: preservedDestination)
        })

        XCTAssertThrowsError(
            try store.saveAs(
                project: project,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedDestination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPackage.path))
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testSaveAsRefusesParentDirectorySubstitutionAndPreservesBothTrees() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let originalParent = fixture.rootURL.appendingPathComponent("Chosen", isDirectory: true)
        let displacedParent = fixture.rootURL.appendingPathComponent(
            "Chosen-Preserved",
            isDirectory: true
        )
        let destinationPackage = originalParent.appendingPathComponent(
            "Destination.ajar",
            isDirectory: true
        )
        let project = try fixture.project(media: [])
        let unvalidatedProject = try fixture.project(media: [])
        try fixture.write(project: project, to: sourcePackage)
        try FileManager.default.createDirectory(
            at: originalParent,
            withIntermediateDirectories: true
        )
        let store = EditorAjarDocumentStore(saveAsWillPublish: {
            try FileManager.default.moveItem(at: originalParent, to: displacedParent)
            try fixture.write(project: unvalidatedProject, to: destinationPackage)
        })

        XCTAssertThrowsError(
            try store.saveAs(
                project: project,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.saveAsDestinationChanged = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try EditorAjarDocumentStore().open(at: destinationPackage).loadResult.project,
            unvalidatedProject
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: displacedParent.path)
                .filter { $0.hasSuffix(".staging") }.count,
            0,
            "only the descriptor-identified staging package is cleaned after parent substitution"
        )
    }

    func testSaveAsSynchronizesStagedAndFinalManifestsBeforeCleanup() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let project = try fixture.project(media: [])
        try fixture.write(project: project, to: sourcePackage)
        try fixture.write(project: try fixture.project(media: []), to: destinationPackage)
        let events = SaveAsSynchronizationEvents()
        events.finalPackageURL = destinationPackage
        events.stagingRootURL = fixture.rootURL
        let synchronizer = RecordingSaveAsSynchronizer(events: events)
        let store = EditorAjarDocumentStore(
            saveAsSynchronizer: synchronizer,
            saveAsWillPublish: { events.values.append(.willPublish) }
        )

        _ = try store.saveAs(
            project: project,
            openMode: .editable,
            appliedCommandCount: 0,
            sourceURL: sourcePackage,
            destinationURL: destinationPackage
        )

        let willPublish = try XCTUnwrap(events.values.firstIndex(of: .willPublish))
        let parentSync = try XCTUnwrap(events.values.firstIndex { event in
            if case .directory(_, true) = event { return true }
            return false
        })
        let firstFinalFile = try XCTUnwrap(events.values.firstIndex { event in
            if case .file(let path) = event {
                return path.hasPrefix(destinationPackage.path + "/")
            }
            return false
        })
        XCTAssertGreaterThan(willPublish, 0)
        XCTAssertGreaterThan(parentSync, willPublish)
        XCTAssertGreaterThan(firstFinalFile, parentSync)
        XCTAssertEqual(
            events.values[..<willPublish].filter {
                if case .file = $0 { return true }
                return false
            }.count,
            4,
            "staged root and snapshot manifests must all sync before publication"
        )
        XCTAssertEqual(
            events.values[(parentSync + 1)...].filter {
                if case .file = $0 { return true }
                return false
            }.count,
            4,
            "final root and snapshot manifests must all sync after publication"
        )
        XCTAssertTrue(events.values[..<willPublish].contains { event in
            if case .file(let path) = event {
                return path.contains(".Destination.ajar.") && path.hasSuffix("project.json")
            }
            return false
        })
        XCTAssertTrue(events.values[(firstFinalFile + 1)...].contains { event in
            if case .directory(let path, false) = event {
                return path == destinationPackage.path
            }
            return false
        })
        XCTAssertTrue(events.sawRollbackDuringFinalRootSynchronization)
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testSaveAsFinalSynchronizationFailureRollsBackNewDestination() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let project = try fixture.project(media: [])
        try fixture.write(project: project, to: sourcePackage)
        let synchronizer = RecordingSaveAsSynchronizer(
            events: SaveAsSynchronizationEvents(),
            failingFilePath: destinationPackage.appendingPathComponent("media.json").path
        )
        let store = EditorAjarDocumentStore(saveAsSynchronizer: synchronizer)

        XCTAssertThrowsError(
            try store.saveAs(
                project: project,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        ) { error in
            guard case EditorAjarDocumentStoreError.saveAsSynchronization = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPackage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }

    func testSaveAsFinalSynchronizationFailureRestoresReplacedDestination() throws {
        let fixture = try PackageMediaSaveAsFixture()
        defer { fixture.cleanup() }
        let sourcePackage = fixture.packageURL(named: "Source.ajar")
        let destinationPackage = fixture.packageURL(named: "Destination.ajar")
        let sourceProject = try fixture.project(media: [])
        let destinationProject = try fixture.project(media: [])
        try fixture.write(project: sourceProject, to: sourcePackage)
        try fixture.write(project: destinationProject, to: destinationPackage)
        let destinationBytes = try fixture.manifestBytes(at: destinationPackage)
        let synchronizer = RecordingSaveAsSynchronizer(
            events: SaveAsSynchronizationEvents(),
            failingFilePath: destinationPackage.appendingPathComponent("media.json").path
        )
        let store = EditorAjarDocumentStore(saveAsSynchronizer: synchronizer)

        XCTAssertThrowsError(
            try store.saveAs(
                project: sourceProject,
                openMode: .editable,
                appliedCommandCount: 0,
                sourceURL: sourcePackage,
                destinationURL: destinationPackage
            )
        )
        XCTAssertEqual(try fixture.manifestBytes(at: destinationPackage), destinationBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePackage.path))
        XCTAssertTrue(try fixture.stagingPackages().isEmpty)
    }
}

private final class SaveAsSynchronizationEvents {
    enum Event: Equatable {
        case file(String)
        case directory(String, Bool)
        case willPublish
    }

    var values: [Event] = []
    var finalPackageURL: URL?
    var stagingRootURL: URL?
    var sawRollbackDuringFinalRootSynchronization = false
}

private struct RecordingSaveAsSynchronizer: EditorAjarSaveAsSynchronizing {
    let events: SaveAsSynchronizationEvents
    var failingFilePath: String?

    init(events: SaveAsSynchronizationEvents, failingFilePath: String? = nil) {
        self.events = events
        self.failingFilePath = failingFilePath
    }

    func synchronizeFile(at url: URL) throws {
        events.values.append(.file(url.path))
        if url.path == failingFilePath {
            throw EditorAjarDocumentStoreError.saveAsSynchronization(
                path: url.path,
                operation: "injected final manifest synchronization failure",
                code: EIO
            )
        }
    }

    func synchronizeDirectory(at url: URL, descriptor: Int32?) throws {
        events.values.append(.directory(url.path, descriptor != nil))
        if descriptor == nil,
            url.standardizedFileURL == events.finalPackageURL?.standardizedFileURL,
            let stagingRootURL = events.stagingRootURL,
            let children = try? FileManager.default.contentsOfDirectory(
                at: stagingRootURL,
                includingPropertiesForKeys: nil
            )
        {
            events.sawRollbackDuringFinalRootSynchronization = children.contains {
                $0.lastPathComponent.hasSuffix(".staging")
            }
        }
    }
}

private struct PackageMediaSaveAsBookmarkStore: MediaBookmarkStore {
    func createBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> MediaBookmarkResolution {
        guard let path = String(data: data, encoding: .utf8) else {
            throw MediaBookmarkError.resolutionFailed(reason: "invalid test bookmark")
        }
        return MediaBookmarkResolution(url: URL(fileURLWithPath: path), isStale: false)
    }
}

private struct FailingPackageMediaFileCopier: EditorAjarPackageMediaFileCopying {
    func copyRegularFile(
        named filename: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws {
        throw NSError(
            domain: "EditorAjarPackageMediaSaveAsTests",
            code: 267,
            userInfo: [NSLocalizedDescriptionKey: "injected package-media copy failure"]
        )
    }
}

private struct PackageMediaSaveAsFixture {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "editor-ajar-package-save-as-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func packageURL(named name: String) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: true)
    }

    func mediaReference(sourceURL: URL, bookmark: Data, bytes: Data) throws -> MediaRef {
        MediaRef(
            id: UUID(),
            sourceURL: sourceURL,
            bookmark: bookmark,
            contentHash: ContentHash.sha256(data: bytes),
            metadata: MediaMetadata(
                codecID: "test",
                pixelDimensions: PixelDimensions(width: 64, height: 36),
                frameRate: try FrameRate(frames: 24),
                duration: try RationalTime(value: 1, timescale: 1),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            ),
            proxyState: .ready(relativePath: "caches/proxies/test.mov")
        )
    }

    func project(media: [MediaRef]) throws -> Project {
        let base = try EditorAjarNewProjectFactory.makeProject(settings: .sensibleDefaults)
        return Project(
            schemaVersion: base.schemaVersion,
            schemaMinor: base.schemaMinor,
            settings: base.settings,
            mediaPool: media,
            sequences: base.sequences,
            looks: base.looks
        )
    }

    func write(project: Project, to packageURL: URL) throws {
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let encoded = try AjarProjectCodec.encode(project, openMode: .editable)
        try encoded.projectJSON.write(
            to: packageURL.appendingPathComponent("project.json"),
            options: .atomic
        )
        try encoded.mediaJSON.write(
            to: packageURL.appendingPathComponent("media.json"),
            options: .atomic
        )
    }

    func manifestBytes(at packageURL: URL) throws -> [Data] {
        try ["project.json", "media.json"].map {
            try Data(contentsOf: packageURL.appendingPathComponent($0))
        }
    }

    func stagingPackages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".staging") }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
