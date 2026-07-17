// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Same-directory temporary output that publishes only a completely finalized movie.
final class ExportOutputTransaction {
    let destinationURL: URL
    let temporaryURL: URL
    private let fileManager: FileManager
    private let destinationCollisionPolicy: ExportDestinationCollisionPolicy
    private var committed = false

    init(
        destinationURL: URL,
        destinationCollisionPolicy: ExportDestinationCollisionPolicy = .replaceExisting,
        fileManager: FileManager = .default
    ) throws {
        guard destinationURL.isFileURL else {
            throw ExportError.destinationMustBeFileURL(destinationURL)
        }
        let directoryURL = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ExportError.destinationDirectoryUnavailable(directoryURL)
        }

        self.destinationURL = destinationURL
        self.fileManager = fileManager
        self.destinationCollisionPolicy = destinationCollisionPolicy
        let extensionSuffix =
            destinationURL.pathExtension.isEmpty
            ? ""
            : ".\(destinationURL.pathExtension)"
        temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.deletingPathExtension().lastPathComponent)."
                + "\(UUID().uuidString).ajar-partial\(extensionSuffix)"
        )
    }

    func commit() throws {
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw ExportError.finalizationFailed("writer produced no temporary output")
        }

        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)
        guard destinationCollisionPolicy == .replaceExisting || !destinationExists else {
            throw ExportError.destinationRequiresOverwriteConfirmation(destinationURL)
        }

        do {
            if destinationExists {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            committed = true
        } catch {
            let destinationAppeared = fileManager.fileExists(atPath: destinationURL.path)
            if destinationCollisionPolicy == .requireVacant && destinationAppeared {
                throw ExportError.destinationRequiresOverwriteConfirmation(destinationURL)
            }
            let mapped = ExportErrorMapper.map(error, destinationURL: destinationURL)
            if case .diskFull = mapped {
                throw ExportError.diskFull(destinationURL)
            }
            throw ExportError.finalizationFailed(String(describing: error))
        }
    }

    func cleanUp() throws {
        guard !committed, fileManager.fileExists(atPath: temporaryURL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: temporaryURL)
        } catch {
            throw ExportCleanupFailure(
                temporaryURL: temporaryURL,
                reason: String(describing: error)
            )
        }
    }
}

/// Temporary-file removal failure surfaced to the session so it can pair with the root cause.
struct ExportCleanupFailure: Error, Equatable {
    let temporaryURL: URL
    let reason: String
}
