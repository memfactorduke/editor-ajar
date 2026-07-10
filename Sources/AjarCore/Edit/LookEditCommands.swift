// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    static func applyLookCommand(_ command: EditCommand, to project: Project) throws -> Project {
        switch command {
        case .copyClipGrade(let source, let target, let newNodeIDs):
            return try copyClipGrade(
                source: source,
                target: target,
                newNodeIDs: newNodeIDs,
                in: project
            )
        case .saveLookFromClip(let source, let lookID, let name):
            return try saveLookFromClip(
                source: source,
                lookID: lookID,
                name: name,
                in: project
            )
        case .applyLookToClip(let lookID, let target, let newNodeIDs):
            return try applyLookToClip(
                lookID: lookID,
                target: target,
                newNodeIDs: newNodeIDs,
                in: project
            )
        case .renameLook(let lookID, let name):
            return try renameLook(lookID: lookID, name: name, in: project)
        case .deleteLook(let lookID):
            return try deleteLook(lookID: lookID, in: project)
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    private static func copyClipGrade(
        source: ProjectClipReference,
        target: ProjectClipReference,
        newNodeIDs: [UUID],
        in project: Project
    ) throws -> Project {
        let grade = try sourceGrade(at: source, in: project)
        let targetClip = try clip(at: target, in: project)
        try validateVideoGradeClip(targetClip)
        let remapped = try remappedGrade(
            grade,
            newNodeIDs: newNodeIDs,
            target: targetClip
        )
        return try replacingGrade(remapped, at: target, in: project)
    }

    private static func saveLookFromClip(
        source: ProjectClipReference,
        lookID: UUID,
        name: String,
        in project: Project
    ) throws -> Project {
        let grade = try sourceGrade(at: source, in: project)
        guard !project.looks.contains(where: { $0.id == lookID }) else {
            throw EditReducerError.invalidEdit(.duplicateLookID(lookID))
        }
        try validateLookName(name, excluding: nil, in: project)

        let look = ProjectLook(id: lookID, name: name, grade: grade)
        return replacingLooks(project.looks + [look], in: project)
    }

    private static func applyLookToClip(
        lookID: UUID,
        target: ProjectClipReference,
        newNodeIDs: [UUID],
        in project: Project
    ) throws -> Project {
        guard let look = project.looks.first(where: { $0.id == lookID }) else {
            throw EditReducerError.invalidEdit(.lookNotFound(lookID))
        }
        let targetClip = try clip(at: target, in: project)
        try validateVideoGradeClip(targetClip)
        let remapped = try remappedGrade(
            look.grade,
            newNodeIDs: newNodeIDs,
            target: targetClip
        )
        return try replacingGrade(remapped, at: target, in: project)
    }

    private static func renameLook(
        lookID: UUID,
        name: String,
        in project: Project
    ) throws -> Project {
        guard let index = project.looks.firstIndex(where: { $0.id == lookID }) else {
            throw EditReducerError.invalidEdit(.lookNotFound(lookID))
        }
        try validateLookName(name, excluding: lookID, in: project)

        var looks = project.looks
        let look = looks[index]
        looks[index] = ProjectLook(id: look.id, name: name, grade: look.grade)
        return replacingLooks(looks, in: project)
    }

    private static func deleteLook(lookID: UUID, in project: Project) throws -> Project {
        guard let index = project.looks.firstIndex(where: { $0.id == lookID }) else {
            throw EditReducerError.invalidEdit(.lookNotFound(lookID))
        }
        var looks = project.looks
        looks.remove(at: index)
        return replacingLooks(looks, in: project)
    }

    private static func sourceGrade(
        at reference: ProjectClipReference,
        in project: Project
    ) throws -> ClipEffectStack {
        let sourceClip = try clip(at: reference, in: project)
        try validateVideoGradeClip(sourceClip)
        let grade = sourceClip.effectStack.grade
        guard !grade.nodes.isEmpty else {
            throw EditReducerError.invalidEdit(
                .gradeSourceHasNoGrade(clipID: sourceClip.id)
            )
        }
        return grade
    }

    private static func clip(
        at reference: ProjectClipReference,
        in project: Project
    ) throws -> Clip {
        let containingSequence = try sequence(reference.sequenceID, in: project)
        return try locateClip(
            ClipReference(trackID: reference.trackID, clipID: reference.clipID),
            in: containingSequence
        ).clip
    }

    private static func validateVideoGradeClip(_ clip: Clip) throws {
        guard clip.kind == .video else {
            throw EditReducerError.invalidEdit(
                .gradeRequiresVideoClip(clipID: clip.id, kind: clip.kind)
            )
        }
    }

    private static func remappedGrade(
        _ grade: ClipEffectStack,
        newNodeIDs: [UUID],
        target: Clip
    ) throws -> ClipEffectStack {
        try validateGradeNodeIDs(newNodeIDs, grade: grade, target: target)
        let nodes = zip(grade.nodes, newNodeIDs).map { node, newID in
            ClipEffectNode(id: newID, enabled: node.enabled, definition: node.definition)
        }
        return ClipEffectStack(nodes: nodes)
    }

    private static func validateGradeNodeIDs(
        _ newNodeIDs: [UUID],
        grade: ClipEffectStack,
        target: Clip
    ) throws {
        guard newNodeIDs.count == grade.nodes.count else {
            throw EditReducerError.invalidEdit(
                .gradeNodeIDCountMismatch(
                    expected: grade.nodes.count,
                    actual: newNodeIDs.count
                )
            )
        }

        var seen = Set<UUID>()
        for nodeID in newNodeIDs where !seen.insert(nodeID).inserted {
            throw EditReducerError.invalidEdit(.duplicateGradeNodeID(nodeID: nodeID))
        }

        let sourceIDs = Set(grade.nodes.map(\.id))
        let targetIDs = Set(target.effectStack.nodes.map(\.id))
        for nodeID in newNodeIDs where sourceIDs.contains(nodeID) || targetIDs.contains(nodeID) {
            throw EditReducerError.invalidEdit(.gradeNodeIDNotFresh(nodeID: nodeID))
        }
    }

    private static func replacingGrade(
        _ grade: ClipEffectStack,
        at target: ProjectClipReference,
        in project: Project
    ) throws -> Project {
        try replacingTrack(target.trackID, sequenceID: target.sequenceID, in: project) { track in
            var items = track.items
            guard
                let index = clipIndex(target.clipID, in: items),
                case .clip(let clip) = items[index]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: target.sequenceID,
                    trackID: target.trackID,
                    clipID: target.clipID
                )
            }
            let stack = clip.effectStack.replacingGrade(with: grade)
            items[index] = .clip(copying(clip, effectStack: stack))
            return copying(track, items: items)
        }
    }

    private static func validateLookName(
        _ name: String,
        excluding lookID: UUID?,
        in project: Project
    ) throws {
        let normalized = ProjectLookValidator.normalizedName(name)
        guard !normalized.isEmpty else {
            throw EditReducerError.invalidEdit(.blankLookName)
        }
        let duplicate = project.looks.contains { look in
            look.id != lookID && ProjectLookValidator.normalizedName(look.name) == normalized
        }
        guard !duplicate else {
            throw EditReducerError.invalidEdit(.duplicateLookName(name))
        }
    }

    private static func replacingLooks(_ looks: [ProjectLook], in project: Project) -> Project {
        Project(
            schemaVersion: project.schemaVersion,
            settings: project.settings,
            mediaPool: project.mediaPool,
            sequences: project.sequences,
            looks: looks
        )
    }
}
