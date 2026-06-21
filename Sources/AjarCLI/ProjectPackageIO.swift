// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

enum ProjectPackageIO {
    static func loadProject(from packageURL: URL) throws -> Project {
        do {
            let snapshot = try AjarAutosaveStore.readSnapshot(from: packageURL)
            let result = try AjarProjectCodec.decode(
                projectJSON: snapshot.package.projectJSON,
                mediaJSON: snapshot.package.mediaJSON
            )
            switch result {
            case .editable(let project), .readOnly(let project, _):
                return project
            }
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

    static func writeProject(_ project: Project, to packageURL: URL) throws {
        try AjarAutosaveStore.writeSnapshot(project, appliedCommandCount: 0, to: packageURL)
    }
}
