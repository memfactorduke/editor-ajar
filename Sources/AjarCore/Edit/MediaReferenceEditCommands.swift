// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    static func addMediaReferences(
        _ additions: [MediaRef],
        to project: Project
    ) throws -> Project {
        var seenIDs = Set(project.mediaPool.map(\.id))
        for addition in additions where !seenIDs.insert(addition.id).inserted {
            throw EditReducerError.duplicateImportedMediaReferenceID(addition.id)
        }

        return Project(
            schemaVersion: project.schemaVersion,
            schemaMinor: project.schemaMinor,
            settings: project.settings,
            mediaPool: project.mediaPool + additions,
            sequences: project.sequences,
            looks: project.looks
        )
    }

    static func updateMediaReferences(
        _ replacements: [MediaRef],
        in project: Project
    ) throws -> Project {
        var replacementsByID: [UUID: MediaRef] = [:]
        for replacement in replacements {
            guard replacementsByID[replacement.id] == nil else {
                throw EditReducerError.duplicateMediaReferenceReplacement(replacement.id)
            }
            guard project.mediaPool.contains(where: { $0.id == replacement.id }) else {
                throw EditReducerError.mediaReferenceNotFound(replacement.id)
            }
            replacementsByID[replacement.id] = replacement
        }

        let updatedMedia = project.mediaPool.map { media in
            replacementsByID[media.id] ?? media
        }
        return Project(
            schemaVersion: project.schemaVersion,
            schemaMinor: project.schemaMinor,
            settings: project.settings,
            mediaPool: updatedMedia,
            sequences: project.sequences,
            looks: project.looks
        )
    }
}
