// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// A project loaded from a user-visible `.ajar` package.
struct EditorAjarOpenedDocument {
    /// Recovered live state, including the FR-PROJ-005 editable/read-only mode.
    let loadResult: AjarProjectLoadResult

    /// Last explicitly saved state used for exact dirty-state comparisons.
    let savedBaseline: Project

    /// Best-effort recovery warnings, if a journal stopped at its last good command.
    let recoveryIssues: [AjarRecoveryIssue]
}

/// Typed app-layer failures for `.ajar` document operations.
enum EditorAjarDocumentStoreError: Error, Equatable {
    /// A document URL did not use the required package extension.
    case invalidPackageExtension(String)

    /// The selected package does not exist.
    case packageNotFound(String)

    /// The selected URL is not a directory package.
    case packageIsNotDirectory(String)

    /// The core codec rejected document bytes.
    case codec(AjarProjectCodecError)

    /// The atomic package persistence layer failed.
    case persistence(AjarAutosaveStoreError)

    /// A filesystem operation outside the core atomic writer failed.
    case fileOperation(path: String, reason: String)
}

/// App-side `.ajar` package lifecycle (FR-PROJ-001/002).
///
/// `AjarCore` continues to own canonical JSON and open-mode safety. This type owns only macOS
/// document concerns: package URLs, Save As cloning, and rolling versions. ADR-0007 explicitly
/// excludes `versions/` from project identity/schema versioning, so these sidecars travel with a
/// package without adding manifest fields or bumping `schemaMinor`.
struct EditorAjarDocumentStore {
    static let snapshotRetentionLimit = 10

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Opens canonical saved bytes and then applies any recoverable journal entries.
    ///
    /// The returned `AjarProjectLoadResult` is never flattened, preserving newer-minor read-only
    /// opens and the existing recovery behavior (FR-PROJ-005 / ADR-0018).
    func open(at packageURL: URL) throws -> EditorAjarOpenedDocument {
        try validateExistingPackage(packageURL)
        let baseline = try loadCanonicalPackage(at: packageURL)

        // Canonical package bytes are the authority for open mode. A stale recovery envelope
        // written by an older build must never turn a newer-minor canonical document back into an
        // editable one. It is also unsafe to replay older commands against schema this build only
        // understands well enough to inspect, so read-only opens intentionally skip recovery.
        guard baseline.openMode.allowsEditing else {
            return EditorAjarOpenedDocument(
                loadResult: baseline,
                savedBaseline: baseline.project,
                recoveryIssues: []
            )
        }

        do {
            let recovery = try AjarAutosaveStore.recoverProject(
                from: packageURL,
                fileManager: fileManager
            )
            return EditorAjarOpenedDocument(
                loadResult: recovery.loadResult,
                savedBaseline: baseline.project,
                recoveryIssues: recovery.issues
            )
        } catch let error as AjarProjectCodecError {
            throw EditorAjarDocumentStoreError.codec(error)
        } catch let error as AjarAutosaveStoreError {
            throw EditorAjarDocumentStoreError.persistence(error)
        } catch {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: packageURL.path,
                reason: String(describing: error)
            )
        }
    }

    /// Saves over the current package, snapshotting the previous saved bytes first.
    func save(
        project: Project,
        openMode: AjarProjectOpenMode,
        appliedCommandCount _: Int,
        to packageURL: URL
    ) throws {
        try validatePackageExtension(packageURL)
        try validateExistingPackage(packageURL)
        let stagingURL = makeStagingURL(for: packageURL)
        do {
            try stagePackageContents(
                project: project,
                openMode: openMode,
                sourceURL: packageURL,
                to: stagingURL
            )
            try publishCanonicalContents(
                stagingURL: stagingURL,
                destinationURL: packageURL
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw mappedError(error, path: packageURL.path)
        }
    }

    /// Saves to another package with canonical files and version history.
    ///
    /// Work happens in a sibling staging directory. Publication only occurs after all canonical
    /// writes succeed, so a failed Save As does not retarget the live document or publish half a
    /// package. Regeneratable `caches/` are intentionally not copied: this avoids a potentially
    /// multi-gigabyte copy and the new document recreates cache entries on demand. Recovery data
    /// is session-specific and likewise does not belong in the new package.
    func saveAs(
        project: Project,
        openMode: AjarProjectOpenMode,
        appliedCommandCount: Int,
        sourceURL: URL?,
        destinationURL: URL
    ) throws {
        try validatePackageExtension(destinationURL)
        if let sourceURL,
           sourceURL.standardizedFileURL == destinationURL.standardizedFileURL
        {
            try save(
                project: project,
                openMode: openMode,
                appliedCommandCount: appliedCommandCount,
                to: destinationURL
            )
            return
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        let stagingURL = makeStagingURL(for: destinationURL)
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            try stagePackageContents(
                project: project,
                openMode: openMode,
                sourceURL: sourceURL,
                to: stagingURL
            )
            try publish(stagingURL: stagingURL, destinationURL: destinationURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw mappedError(error, path: destinationURL.path)
        }
    }

    /// Reloads only explicitly saved canonical files and durably discards package recovery data.
    ///
    /// The recovery directory is removed in a staged package replacement. A later reopen therefore
    /// cannot replay the edits the user just chose to discard, while a failed replacement leaves
    /// the original package untouched.
    func revert(at packageURL: URL) throws -> AjarProjectLoadResult {
        try validateExistingPackage(packageURL)
        let baseline = try loadCanonicalPackage(at: packageURL)
        let recoveryURL = packageURL.appendingPathComponent("recovery", isDirectory: true)
        guard fileManager.fileExists(atPath: recoveryURL.path) else {
            return baseline
        }

        let stagingURL = makeStagingURL(for: packageURL)
        do {
            try fileManager.copyItem(at: packageURL, to: stagingURL)
            let stagedRecoveryURL = stagingURL.appendingPathComponent(
                "recovery",
                isDirectory: true
            )
            try fileManager.removeItem(at: stagedRecoveryURL)
            try publish(stagingURL: stagingURL, destinationURL: packageURL)
            return baseline
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw mappedError(error, path: packageURL.path)
        }
    }

    /// Save snapshots currently retained in the package, oldest first.
    func versionSnapshotURLs(in packageURL: URL) throws -> [URL] {
        let versionsURL = packageURL.appendingPathComponent("versions", isDirectory: true)
        guard fileManager.fileExists(atPath: versionsURL.path) else {
            return []
        }
        do {
            return try fileManager.contentsOfDirectory(
                at: versionsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard url.lastPathComponent.hasPrefix("save-") else {
                    return false
                }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: versionsURL.path,
                reason: String(describing: error)
            )
        }
    }
}

private extension EditorAjarDocumentStore {
    func validatePackageExtension(_ packageURL: URL) throws {
        guard packageURL.pathExtension.lowercased() == "ajar" else {
            throw EditorAjarDocumentStoreError.invalidPackageExtension(packageURL.path)
        }
    }

    func validateExistingPackage(_ packageURL: URL) throws {
        try validatePackageExtension(packageURL)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) else {
            throw EditorAjarDocumentStoreError.packageNotFound(packageURL.path)
        }
        guard isDirectory.boolValue else {
            throw EditorAjarDocumentStoreError.packageIsNotDirectory(packageURL.path)
        }
    }

    func loadCanonicalPackage(at packageURL: URL) throws -> AjarProjectLoadResult {
        let projectURL = packageURL.appendingPathComponent("project.json")
        let mediaURL = packageURL.appendingPathComponent("media.json")
        do {
            guard fileManager.isReadableFile(atPath: projectURL.path) else {
                throw AjarAutosaveStoreError.missingPackageFile("project.json")
            }
            guard fileManager.isReadableFile(atPath: mediaURL.path) else {
                throw AjarAutosaveStoreError.missingPackageFile("media.json")
            }
            return try AjarProjectCodec.decode(
                projectJSON: Data(contentsOf: projectURL),
                mediaJSON: Data(contentsOf: mediaURL)
            )
        } catch let error as AjarProjectCodecError {
            throw EditorAjarDocumentStoreError.codec(error)
        } catch let error as AjarAutosaveStoreError {
            throw EditorAjarDocumentStoreError.persistence(error)
        } catch {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: packageURL.path,
                reason: String(describing: error)
            )
        }
    }

    func stagePackageContents(
        project: Project,
        openMode: AjarProjectOpenMode,
        sourceURL: URL?,
        to packageURL: URL
    ) throws {
        do {
            // Validate and enforce read-only mode before creating any staged snapshot side effect.
            let encoded = try AjarProjectCodec.encode(project, openMode: openMode)
            try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
            if let sourceURL, fileManager.fileExists(atPath: sourceURL.path) {
                try copyCanonicalFileIfPresent(named: "project.json", from: sourceURL, to: packageURL)
                try copyCanonicalFileIfPresent(named: "media.json", from: sourceURL, to: packageURL)
                let sourceVersionsURL = sourceURL.appendingPathComponent(
                    "versions",
                    isDirectory: true
                )
                if fileManager.fileExists(atPath: sourceVersionsURL.path) {
                    try fileManager.copyItem(
                        at: sourceVersionsURL,
                        to: packageURL.appendingPathComponent("versions", isDirectory: true)
                    )
                }
            }
            try createVersionSnapshotIfPossible(in: packageURL)
            try pruneVersionSnapshots(in: packageURL)
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
        } catch let error as EditorAjarDocumentStoreError {
            throw error
        } catch let error as AjarProjectCodecError {
            throw EditorAjarDocumentStoreError.codec(error)
        } catch let error as AjarAutosaveStoreError {
            throw EditorAjarDocumentStoreError.persistence(error)
        } catch {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: packageURL.path,
                reason: String(describing: error)
            )
        }
    }

    func copyCanonicalFileIfPresent(named name: String, from sourceURL: URL, to targetURL: URL) throws {
        let sourceFileURL = sourceURL.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: sourceFileURL.path) else {
            return
        }
        try fileManager.copyItem(at: sourceFileURL, to: targetURL.appendingPathComponent(name))
    }

    func publishCanonicalContents(stagingURL: URL, destinationURL: URL) throws {
        let rollbackURL = makeStagingURL(for: destinationURL)
        try fileManager.createDirectory(at: rollbackURL, withIntermediateDirectories: true)
        var didBeginPublishing = false
        do {
            try copyCanonicalFileIfPresent(
                named: "project.json",
                from: destinationURL,
                to: rollbackURL
            )
            try copyCanonicalFileIfPresent(named: "media.json", from: destinationURL, to: rollbackURL)
            let destinationVersionsURL = destinationURL.appendingPathComponent(
                "versions",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: destinationVersionsURL.path) {
                try fileManager.copyItem(
                    at: destinationVersionsURL,
                    to: rollbackURL.appendingPathComponent("versions", isDirectory: true)
                )
            }

            didBeginPublishing = true
            try publishStagedFile(named: "project.json", from: stagingURL, to: destinationURL)
            try publishStagedFile(named: "media.json", from: stagingURL, to: destinationURL)
            try publishStagedVersions(from: stagingURL, to: destinationURL)
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: rollbackURL)
        } catch {
            if didBeginPublishing {
                try restoreCanonicalContents(from: rollbackURL, to: destinationURL)
            }
            try? fileManager.removeItem(at: rollbackURL)
            throw error
        }
    }

    func publishStagedFile(named name: String, from stagingURL: URL, to destinationURL: URL) throws {
        try AjarAtomicFileWriter.write(
            Data(contentsOf: stagingURL.appendingPathComponent(name)),
            to: destinationURL.appendingPathComponent(name),
            fileManager: fileManager
        )
    }

    func publishStagedVersions(from stagingURL: URL, to destinationURL: URL) throws {
        let stagedVersionsURL = stagingURL.appendingPathComponent("versions", isDirectory: true)
        guard fileManager.fileExists(atPath: stagedVersionsURL.path) else {
            return
        }
        let destinationVersionsURL = destinationURL.appendingPathComponent(
            "versions",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: destinationVersionsURL.path) {
            _ = try fileManager.replaceItemAt(destinationVersionsURL, withItemAt: stagedVersionsURL)
        } else {
            try fileManager.moveItem(at: stagedVersionsURL, to: destinationVersionsURL)
        }
    }

    func restoreCanonicalContents(from rollbackURL: URL, to destinationURL: URL) throws {
        for name in ["project.json", "media.json", "versions"] {
            let destination = destinationURL.appendingPathComponent(name)
            let backup = rollbackURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.copyItem(at: backup, to: destination)
            }
        }
    }

    func createVersionSnapshotIfPossible(in packageURL: URL) throws {
        let projectURL = packageURL.appendingPathComponent("project.json")
        let mediaURL = packageURL.appendingPathComponent("media.json")
        guard fileManager.isReadableFile(atPath: projectURL.path),
              fileManager.isReadableFile(atPath: mediaURL.path)
        else {
            return
        }

        let versionsURL = packageURL.appendingPathComponent("versions", isDirectory: true)
        try fileManager.createDirectory(at: versionsURL, withIntermediateDirectories: true)
        let sequence = try nextVersionSequence(in: packageURL)
        let snapshotURL = versionsURL.appendingPathComponent(
            String(format: "save-%020llu.ajar", sequence),
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
            try AjarAtomicFileWriter.write(
                Data(contentsOf: projectURL),
                to: snapshotURL.appendingPathComponent("project.json"),
                fileManager: fileManager
            )
            try AjarAtomicFileWriter.write(
                Data(contentsOf: mediaURL),
                to: snapshotURL.appendingPathComponent("media.json"),
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw error
        }
    }

    func nextVersionSequence(in packageURL: URL) throws -> UInt64 {
        let snapshots = try versionSnapshotURLs(in: packageURL)
        let largest = snapshots.compactMap { url -> UInt64? in
            let name = url.deletingPathExtension().lastPathComponent
            return UInt64(name.dropFirst("save-".count))
        }.max() ?? 0
        return largest == UInt64.max ? largest : largest + 1
    }

    func pruneVersionSnapshots(in packageURL: URL) throws {
        let snapshots = try versionSnapshotURLs(in: packageURL)
        let excessCount = max(0, snapshots.count - Self.snapshotRetentionLimit)
        for snapshotURL in snapshots.prefix(excessCount) {
            do {
                try fileManager.removeItem(at: snapshotURL)
            } catch {
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: snapshotURL.path,
                    reason: String(describing: error)
                )
            }
        }
    }

    func publish(stagingURL: URL, destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    func makeStagingURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).staging",
            isDirectory: true
        )
    }

    func mappedError(_ error: Error, path: String) -> EditorAjarDocumentStoreError {
        if let error = error as? EditorAjarDocumentStoreError {
            return error
        }
        if let error = error as? AjarProjectCodecError {
            return .codec(error)
        }
        if let error = error as? AjarAutosaveStoreError {
            return .persistence(error)
        }
        return .fileOperation(path: path, reason: String(describing: error))
    }
}

/// Holds a document security scope for the complete open session.
///
/// Unsandboxed/test URLs commonly return `false`; that means no matching scope was needed, not
/// that the URL is invalid.
final class EditorAjarSecurityScopedAccess {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// App-side recent-document persistence. URLs/bookmarks never enter project manifests.
struct EditorAjarRecentProjectsStore {
    static let maximumCount = 10

    private struct Record: Codable {
        let urlString: String
        let bookmark: Data?
    }

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "document.recentProjects"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func load() -> [URL] {
        guard let data = userDefaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else {
            return []
        }
        return records.compactMap(resolve)
    }

    func record(_ url: URL) -> [URL] {
        let standardizedURL = url.standardizedFileURL
        var urls = load().filter { $0.standardizedFileURL != standardizedURL }
        urls.insert(standardizedURL, at: 0)
        urls = Array(urls.prefix(Self.maximumCount))
        persist(urls)
        return urls
    }

    func remove(_ url: URL) -> [URL] {
        let standardizedURL = url.standardizedFileURL
        let urls = load().filter { $0.standardizedFileURL != standardizedURL }
        persist(urls)
        return urls
    }

    private func persist(_ urls: [URL]) {
        let records = urls.map { url in
            Record(
                urlString: url.absoluteString,
                bookmark: try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            )
        }
        if let data = try? JSONEncoder().encode(records) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private func resolve(_ record: Record) -> URL? {
        if let bookmark = record.bookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    refreshBookmark(for: resolved, replacing: record)
                }
                // Preserve the bookmark-resolved URL itself: standardizing it can discard the
                // security-scope association that a future sandboxed build must retain.
                return resolved
            }
        }
        return URL(string: record.urlString)?.standardizedFileURL
    }

    private func refreshBookmark(for url: URL, replacing record: Record) {
        guard let data = userDefaults.data(forKey: storageKey),
              var records = try? JSONDecoder().decode([Record].self, from: data),
              let index = records.firstIndex(where: { $0.urlString == record.urlString }),
              let bookmark = try? url.bookmarkData(
                  options: [.withSecurityScope],
                  includingResourceValuesForKeys: nil,
                  relativeTo: nil
              )
        else {
            return
        }
        records[index] = Record(urlString: url.absoluteString, bookmark: bookmark)
        if let refreshedData = try? JSONEncoder().encode(records) {
            userDefaults.set(refreshedData, forKey: storageKey)
        }
    }
}
