// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Darwin
import Foundation

protocol EditorAjarPackageMediaFileCopying {
    func copyRegularFile(
        named filename: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws
}

struct EditorAjarDefaultPackageMediaFileCopier: EditorAjarPackageMediaFileCopying {
    func copyRegularFile(
        named filename: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws {
        let sourceDirectoryDescriptor = sourceDirectory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDirectoryDescriptor >= 0 else {
            throw EditorAjarPackageMediaSaveAsError.operationFailed(
                url: sourceDirectory,
                operation: "open package media directory",
                code: errno
            )
        }
        defer { Darwin.close(sourceDirectoryDescriptor) }

        let destinationDirectoryDescriptor = destinationDirectory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard destinationDirectoryDescriptor >= 0 else {
            throw EditorAjarPackageMediaSaveAsError.operationFailed(
                url: destinationDirectory,
                operation: "open staged media directory",
                code: errno
            )
        }
        defer { Darwin.close(destinationDirectoryDescriptor) }

        let sourceDescriptor = filename.withCString { name in
            Darwin.openat(sourceDirectoryDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        let sourceURL = sourceDirectory.appendingPathComponent(filename)
        guard sourceDescriptor >= 0 else {
            throw EditorAjarPackageMediaSaveAsError.operationFailed(
                url: sourceURL,
                operation: "open package media source",
                code: errno
            )
        }
        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? sourceHandle.close() }

        var sourceInformation = stat()
        guard fstat(sourceDescriptor, &sourceInformation) == 0 else {
            throw EditorAjarPackageMediaSaveAsError.operationFailed(
                url: sourceURL,
                operation: "inspect package media source",
                code: errno
            )
        }
        guard sourceInformation.st_mode & S_IFMT == S_IFREG else {
            throw EditorAjarPackageMediaSaveAsError.unsafePackageMedia(sourceURL)
        }

        let destinationDescriptor = filename.withCString { name in
            Darwin.openat(
                destinationDirectoryDescriptor,
                name,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        guard destinationDescriptor >= 0 else {
            throw EditorAjarPackageMediaSaveAsError.operationFailed(
                url: destinationURL,
                operation: "create staged package media",
                code: errno
            )
        }
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: true
        )
        defer { try? destinationHandle.close() }

        while let data = try sourceHandle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try destinationHandle.write(contentsOf: data)
        }
        try destinationHandle.synchronize()
    }
}

enum EditorAjarPackageMediaSaveAsError: Error {
    case packageMediaDirectoryUnsafe(URL)
    case unsafePackageMedia(URL)
    case packageMediaHashUnavailable(mediaID: UUID, url: URL)
    case packageMediaHashMismatch(mediaID: UUID, url: URL)
    case destinationWouldDeleteReferencedMedia(mediaID: UUID, url: URL)
    case destinationReferenceUnavailable(mediaID: UUID)
    case operationFailed(url: URL, operation: String, code: Int32)
}

struct EditorAjarPreparedPackageMediaSaveAs {
    let project: Project
    let expectedReferences: [MediaRef]
    let rebasedReferences: [MediaRef]
}

struct EditorAjarFinalizedPackageMediaSaveAs {
    let project: Project
    let expectedReferences: [MediaRef]
    let rebasedReferences: [MediaRef]
}

struct EditorAjarPackageMediaSaveAs {
    private let fileManager: FileManager
    private let bookmarkStore: any MediaBookmarkStore
    private let hasher: any MediaFileHashing
    private let fileCopier: any EditorAjarPackageMediaFileCopying

    init(
        fileManager: FileManager,
        bookmarkStore: any MediaBookmarkStore,
        hasher: any MediaFileHashing = SHA256MediaFileHasher(),
        fileCopier: any EditorAjarPackageMediaFileCopying =
            EditorAjarDefaultPackageMediaFileCopier()
    ) {
        self.fileManager = fileManager
        self.bookmarkStore = bookmarkStore
        self.hasher = hasher
        self.fileCopier = fileCopier
    }

    func validateDestinationReplacement(
        project: Project,
        persistenceMediaReferences: [MediaRef]? = nil,
        sourcePackageURL: URL?,
        destinationPackageURL: URL
    ) throws {
        guard fileManager.fileExists(atPath: destinationPackageURL.path) else {
            return
        }
        try validateDestinationReplacement(
            media: persistenceMediaReferences ?? project.mediaPool,
            destinationPackageURL: destinationPackageURL
        )
        guard let sourcePackageURL else {
            return
        }
        try inspectVersionSnapshots(in: sourcePackageURL) { snapshot, _ in
            try validateDestinationReplacement(
                media: snapshot.project.mediaPool,
                destinationPackageURL: destinationPackageURL
            )
        }
    }

    private func validateDestinationReplacement(
        media: [MediaRef],
        destinationPackageURL: URL
    ) throws {
        for reference in media {
            let urls = try availableURLs(for: reference)
            for url in urls {
                if isDescendant(url, of: destinationPackageURL) {
                    throw EditorAjarPackageMediaSaveAsError.destinationWouldDeleteReferencedMedia(
                        mediaID: reference.id,
                        url: url
                    )
                }
            }
        }
    }

    func prepareStagedPackage(
        project: Project,
        persistenceMediaReferences: [MediaRef],
        sourcePackageURL: URL?,
        stagingPackageURL: URL,
        destinationPackageURL: URL
    ) throws -> EditorAjarPreparedPackageMediaSaveAs {
        guard let sourcePackageURL else {
            return EditorAjarPreparedPackageMediaSaveAs(
                project: project,
                expectedReferences: persistenceMediaReferences,
                rebasedReferences: persistenceMediaReferences
            )
        }
        let rebaser = StagedPackageMediaRebaser(
            fileManager: fileManager,
            bookmarkStore: bookmarkStore,
            hasher: hasher,
            fileCopier: fileCopier,
            sourcePackageURL: sourcePackageURL,
            stagingPackageURL: stagingPackageURL,
            destinationPackageURL: destinationPackageURL
        )
        let stagedProject = try rebaser.rebase(project)
        try rewriteVersionSnapshots(in: stagingPackageURL) { snapshot in
            try rebaser.rebase(snapshot)
        }
        let rebasedReferences = try persistenceMediaReferences.map(rebaser.rebase)
        try rebaser.synchronizeStagedMediaDirectoryIfNeeded()
        return EditorAjarPreparedPackageMediaSaveAs(
            project: stagedProject,
            expectedReferences: persistenceMediaReferences,
            rebasedReferences: rebasedReferences
        )
    }

    func finalizePublishedPackage(
        prepared: EditorAjarPreparedPackageMediaSaveAs,
        openMode: AjarProjectOpenMode,
        packageURL: URL
    ) throws -> EditorAjarFinalizedPackageMediaSaveAs {
        let finalizedProject = try addingFinalBookmarks(
            to: prepared.project,
            packageURL: packageURL
        )
        try write(finalizedProject, openMode: openMode, to: packageURL)
        try rewriteVersionSnapshots(in: packageURL) { snapshot in
            try addingFinalBookmarks(to: snapshot, packageURL: packageURL)
        }
        let finalizedReferences = try prepared.rebasedReferences.map {
            try addingFinalBookmark(to: $0, packageURL: packageURL)
        }
        return EditorAjarFinalizedPackageMediaSaveAs(
            project: finalizedProject,
            expectedReferences: prepared.expectedReferences,
            rebasedReferences: finalizedReferences
        )
    }
}

private extension EditorAjarPackageMediaSaveAs {
    func availableURLs(for media: MediaRef) throws -> [URL] {
        var result: [URL] = []
        if let bookmark = media.bookmark {
            guard let resolution = try? bookmarkStore.resolveBookmark(bookmark),
                resolution.url.isFileURL
            else {
                throw EditorAjarPackageMediaSaveAsError.destinationReferenceUnavailable(
                    mediaID: media.id
                )
            }
            result.append(resolution.url)
        }
        if let sourceURL = media.sourceURL, sourceURL.isFileURL {
            result.append(sourceURL)
        }
        return result
    }

    func addingFinalBookmarks(to project: Project, packageURL: URL) throws -> Project {
        let media = try project.mediaPool.map { reference in
            try addingFinalBookmark(to: reference, packageURL: packageURL)
        }
        return replacingMedia(in: project, with: media)
    }

    func addingFinalBookmark(to reference: MediaRef, packageURL: URL) throws -> MediaRef {
        let mediaDirectory = packageURL.appendingPathComponent("media", isDirectory: true)
        guard let sourceURL = reference.sourceURL,
            sourceURL.deletingLastPathComponent().standardizedFileURL
                == mediaDirectory.standardizedFileURL
        else {
            return reference
        }
        let started = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if started {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let bookmark = try bookmarkStore.createBookmark(for: sourceURL)
        return reference.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: sourceURL,
                contentHash: reference.contentHash,
                bookmark: bookmark
            )
        )
    }

    func rewriteVersionSnapshots(
        in packageURL: URL,
        transform: (Project) throws -> Project
    ) throws {
        try inspectVersionSnapshots(in: packageURL) { loaded, snapshotURL in
            try write(try transform(loaded.project), openMode: loaded.openMode, to: snapshotURL)
        }
    }

    func inspectVersionSnapshots(
        in packageURL: URL,
        visit: (AjarProjectLoadResult, URL) throws -> Void
    ) throws {
        let versionsURL = packageURL.appendingPathComponent("versions", isDirectory: true)
        guard fileManager.fileExists(atPath: versionsURL.path) else {
            return
        }
        let snapshots = try fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for snapshotURL in snapshots {
            let values = try snapshotURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }
            let projectURL = snapshotURL.appendingPathComponent("project.json")
            let mediaURL = snapshotURL.appendingPathComponent("media.json")
            guard fileManager.fileExists(atPath: projectURL.path),
                fileManager.fileExists(atPath: mediaURL.path)
            else {
                continue
            }
            let loaded = try AjarProjectCodec.decode(
                projectJSON: Data(contentsOf: projectURL),
                mediaJSON: Data(contentsOf: mediaURL)
            )
            try visit(loaded, snapshotURL)
        }
    }

    func write(_ project: Project, openMode: AjarProjectOpenMode, to packageURL: URL) throws {
        let encoded = try AjarProjectCodec.encode(project, openMode: openMode)
        try AjarAtomicFileWriter.write(
            encoded.projectJSON,
            to: packageURL.appendingPathComponent("project.json"),
            fileManager: fileManager
        )
        try AjarAtomicFileWriter.write(
            encoded.mediaJSON,
            to: packageURL.appendingPathComponent("media.json"),
            fileManager: fileManager
        )
    }

    func replacingMedia(in project: Project, with media: [MediaRef]) -> Project {
        Project(
            schemaVersion: project.schemaVersion,
            schemaMinor: project.schemaMinor,
            settings: project.settings,
            mediaPool: media,
            sequences: project.sequences,
            looks: project.looks
        )
    }

    func isDescendant(_ url: URL, of directory: URL) -> Bool {
        isLexicalDescendant(url, of: directory)
            || isLexicalDescendant(
                url.resolvingSymlinksInPath(),
                of: directory.resolvingSymlinksInPath()
            )
    }

    func isLexicalDescendant(_ url: URL, of directory: URL) -> Bool {
        let candidate = url.standardizedFileURL.pathComponents
        let ancestor = directory.standardizedFileURL.pathComponents
        return candidate.count > ancestor.count
            && Array(candidate.prefix(ancestor.count)) == ancestor
    }
}

private final class StagedPackageMediaRebaser {
    private let fileManager: FileManager
    private let bookmarkStore: any MediaBookmarkStore
    private let hasher: any MediaFileHashing
    private let fileCopier: any EditorAjarPackageMediaFileCopying
    private let sourceMediaDirectory: URL
    private let stagingMediaDirectory: URL
    private let destinationMediaDirectory: URL
    private var copiedHashesByFilename: [String: ContentHash] = [:]
    private var didCreateStagedMediaDirectory = false

    init(
        fileManager: FileManager,
        bookmarkStore: any MediaBookmarkStore,
        hasher: any MediaFileHashing,
        fileCopier: any EditorAjarPackageMediaFileCopying,
        sourcePackageURL: URL,
        stagingPackageURL: URL,
        destinationPackageURL: URL
    ) {
        self.fileManager = fileManager
        self.bookmarkStore = bookmarkStore
        self.hasher = hasher
        self.fileCopier = fileCopier
        sourceMediaDirectory = sourcePackageURL.appendingPathComponent("media", isDirectory: true)
        stagingMediaDirectory = stagingPackageURL.appendingPathComponent("media", isDirectory: true)
        destinationMediaDirectory = destinationPackageURL.appendingPathComponent(
            "media",
            isDirectory: true
        )
    }

    func rebase(_ project: Project) throws -> Project {
        let media = try project.mediaPool.map(rebase)
        return Project(
            schemaVersion: project.schemaVersion,
            schemaMinor: project.schemaMinor,
            settings: project.settings,
            mediaPool: media,
            sequences: project.sequences,
            looks: project.looks
        )
    }

    func synchronizeStagedMediaDirectoryIfNeeded() throws {
        guard didCreateStagedMediaDirectory else {
            return
        }
        try synchronizeDirectory(stagingMediaDirectory)
        try synchronizeDirectory(stagingMediaDirectory.deletingLastPathComponent())
    }
}

private extension StagedPackageMediaRebaser {
    func rebase(_ media: MediaRef) throws -> MediaRef {
        guard let sourceURL = try packageLocalSource(for: media) else {
            return media
        }
        guard let expectedHash = media.contentHash else {
            throw EditorAjarPackageMediaSaveAsError.packageMediaHashUnavailable(
                mediaID: media.id,
                url: sourceURL
            )
        }
        try validateSourceMediaDirectory()
        try fileManager.createDirectory(
            at: stagingMediaDirectory,
            withIntermediateDirectories: true
        )
        didCreateStagedMediaDirectory = true
        let filename = sourceURL.lastPathComponent
        let stagedURL = stagingMediaDirectory.appendingPathComponent(filename)
        if let copiedHash = copiedHashesByFilename[filename] {
            guard copiedHash == expectedHash else {
                throw EditorAjarPackageMediaSaveAsError.packageMediaHashMismatch(
                    mediaID: media.id,
                    url: sourceURL
                )
            }
        } else {
            let started = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if started {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try fileCopier.copyRegularFile(
                named: filename,
                from: sourceMediaDirectory,
                to: stagingMediaDirectory
            )
            let copiedHash = try hasher.contentHash(of: stagedURL)
            guard copiedHash == expectedHash else {
                throw EditorAjarPackageMediaSaveAsError.packageMediaHashMismatch(
                    mediaID: media.id,
                    url: sourceURL
                )
            }
            copiedHashesByFilename[filename] = copiedHash
        }
        let destinationURL = destinationMediaDirectory.appendingPathComponent(filename)
        return media.consolidated(
            to: MediaRelinkCandidate(
                sourceURL: destinationURL,
                contentHash: expectedHash,
                bookmark: nil
            )
        )
    }

    func packageLocalSource(for media: MediaRef) throws -> URL? {
        var candidates: [URL] = []
        if let sourceURL = media.sourceURL, sourceURL.isFileURL {
            candidates.append(sourceURL)
        }
        if let bookmark = media.bookmark {
            guard let resolved = try? bookmarkStore.resolveBookmark(bookmark),
                resolved.url.isFileURL
            else {
                throw EditorAjarPackageMediaSaveAsError.destinationReferenceUnavailable(
                    mediaID: media.id
                )
            }
            candidates.append(resolved.url)
        }
        for candidate in candidates {
            if try isDirectPackageMediaChild(candidate) {
                return candidate
            }
        }
        return nil
    }

    func isDirectPackageMediaChild(_ candidate: URL) throws -> Bool {
        let lexicalParent = candidate.deletingLastPathComponent().standardizedFileURL
        let lexicalMedia = sourceMediaDirectory.standardizedFileURL
        if lexicalParent == lexicalMedia {
            return true
        }
        let resolvedParent = lexicalParent.resolvingSymlinksInPath().standardizedFileURL
        let resolvedMedia = lexicalMedia.resolvingSymlinksInPath().standardizedFileURL
        if resolvedParent == resolvedMedia {
            return true
        }
        if isDescendant(candidate, of: sourceMediaDirectory) {
            throw EditorAjarPackageMediaSaveAsError.unsafePackageMedia(candidate)
        }
        return false
    }

    func validateSourceMediaDirectory() throws {
        var information = stat()
        let result = sourceMediaDirectory.path.withCString { path in
            lstat(path, &information)
        }
        guard result == 0, information.st_mode & S_IFMT == S_IFDIR else {
            throw EditorAjarPackageMediaSaveAsError.packageMediaDirectoryUnsafe(
                sourceMediaDirectory
            )
        }
    }

    func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw EditorAjarPackageMediaSaveAsError.operationFailed(
                url: url,
                operation: "open staged package directory",
                code: errno
            )
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw EditorAjarPackageMediaSaveAsError.operationFailed(
                url: url,
                operation: "synchronize staged package directory",
                code: errno
            )
        }
    }

    func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let candidate = url.standardizedFileURL.pathComponents
        let ancestor = directory.standardizedFileURL.pathComponents
        return candidate.count > ancestor.count
            && Array(candidate.prefix(ancestor.count)) == ancestor
    }
}
