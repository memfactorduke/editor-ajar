// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

enum ProjectPackageIO {
    /// Loads a `.ajar` package and preserves editable vs read-only open mode (FR-PROJ-005).
    ///
    /// Callers that only **read** (render / bench / golden) may use `loadResult.project` for
    /// any mode. Paths that **write** must pass `loadResult.openMode` into ``writeProject`` so
    /// higher-minor documents cannot be stripped.
    static func loadProject(from packageURL: URL) throws -> AjarProjectLoadResult {
        do {
            let snapshot = try AjarAutosaveStore.readSnapshot(from: packageURL)
            return try AjarProjectCodec.decode(
                projectJSON: snapshot.package.projectJSON,
                mediaJSON: snapshot.package.mediaJSON
            )
        } catch let error as AjarCLIError {
            throw error
        } catch AjarAutosaveStoreError.missingPackageFile(let relativePath) {
            throw AjarCLIError.missingFile(
                packageURL.appendingPathComponent(relativePath).path
            )
        } catch {
            throw AjarCLIError.projectLoadFailed(String(describing: error))
        }
    }

    /// Writes a newly produced editable project package (fixtures / synthetic documents).
    static func writeProject(_ project: Project, to packageURL: URL) throws {
        try writeProject(project, openMode: .editable, to: packageURL)
    }

    /// Writes a project that was previously loaded, refusing read-only opens (FR-PROJ-005).
    static func writeProject(_ loadResult: AjarProjectLoadResult, to packageURL: URL) throws {
        try writeProject(loadResult.project, openMode: loadResult.openMode, to: packageURL)
    }

    /// Writes `project` when the session open mode is known.
    ///
    /// - Parameters:
    ///   - project: Project to persist.
    ///   - openMode: Must be `.editable`. Read-only opens throw
    ///     `AjarCLIError.projectWriteBlockedReadOnly` with the typed reason message.
    ///   - packageURL: Destination `.ajar` package directory.
    /// - Throws: `AjarCLIError.projectWriteBlockedReadOnly` when `openMode` is read-only;
    ///   otherwise package I/O errors from `AjarAutosaveStore.writeSnapshot`.
    static func writeProject(
        _ project: Project,
        openMode: AjarProjectOpenMode,
        to packageURL: URL
    ) throws {
        if case .readOnly(let reason) = openMode {
            throw AjarCLIError.projectWriteBlockedReadOnly(reason: reason)
        }

        try AjarAutosaveStore.writeSnapshot(
            project,
            appliedCommandCount: 0,
            openMode: openMode,
            to: packageURL
        )
    }
}
