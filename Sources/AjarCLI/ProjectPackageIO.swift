// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

enum ProjectPackageIO {
    static func loadProject(from packageURL: URL) throws -> Project {
        let projectURL = packageURL.appendingPathComponent("project.json")
        let mediaURL = packageURL.appendingPathComponent("media.json")
        guard FileManager.default.isReadableFile(atPath: projectURL.path) else {
            throw AjarCLIError.missingFile(projectURL.path)
        }
        guard FileManager.default.isReadableFile(atPath: mediaURL.path) else {
            throw AjarCLIError.missingFile(mediaURL.path)
        }

        do {
            let result = try AjarProjectCodec.decode(
                projectJSON: try Data(contentsOf: projectURL),
                mediaJSON: try Data(contentsOf: mediaURL)
            )
            switch result {
            case .editable(let project), .readOnly(let project, _):
                return project
            }
        } catch let error as AjarCLIError {
            throw error
        } catch {
            throw AjarCLIError.projectLoadFailed(String(describing: error))
        }
    }

    static func writeProject(_ project: Project, to packageURL: URL) throws {
        let package = try AjarProjectCodec.encode(project)
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try package.projectJSON.write(to: packageURL.appendingPathComponent("project.json"))
        try package.mediaJSON.write(to: packageURL.appendingPathComponent("media.json"))
    }
}
