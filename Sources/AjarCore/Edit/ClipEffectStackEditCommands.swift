// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct ClipEffectStackEditTarget {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
    }

    struct AddClipEffectNodeEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let node: ClipEffectNode
        let destinationIndex: Int?
    }

    struct ClipEffectNodeIDEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let nodeID: UUID
    }

    struct MoveClipEffectNodeEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let nodeID: UUID
        let destinationIndex: Int
    }

    struct SetClipEffectNodeEnabledEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let nodeID: UUID
        let enabled: Bool
    }

    struct SetClipEffectNodeParametersEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let nodeID: UUID
        let definition: ClipEffectDefinition
    }

    // swiftlint:disable:next function_body_length
    static func applyClipEffectStackCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .addClipEffectNode(
            let sequenceID, let trackID, let clipID, let node, let destinationIndex
        ):
            return try addClipEffectNode(
                AddClipEffectNodeEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    node: node,
                    destinationIndex: destinationIndex
                ),
                in: project
            )
        case .removeClipEffectNode(let sequenceID, let trackID, let clipID, let nodeID):
            return try removeClipEffectNode(
                ClipEffectNodeIDEdit(
                    sequenceID: sequenceID, trackID: trackID, clipID: clipID, nodeID: nodeID
                ),
                in: project
            )
        case .moveClipEffectNode(
            let sequenceID, let trackID, let clipID, let nodeID, let destinationIndex
        ):
            return try moveClipEffectNode(
                MoveClipEffectNodeEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    nodeID: nodeID,
                    destinationIndex: destinationIndex
                ),
                in: project
            )
        case .setClipEffectNodeEnabled(
            let sequenceID, let trackID, let clipID, let nodeID, let enabled
        ):
            return try setClipEffectNodeEnabled(
                SetClipEffectNodeEnabledEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    nodeID: nodeID,
                    enabled: enabled
                ),
                in: project
            )
        case .setClipEffectNodeParameters(
            let sequenceID, let trackID, let clipID, let nodeID, let definition
        ):
            return try setClipEffectNodeParameters(
                SetClipEffectNodeParametersEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    nodeID: nodeID,
                    definition: definition
                ),
                in: project
            )
        case .resetClipEffectNode(let sequenceID, let trackID, let clipID, let nodeID):
            return try resetClipEffectNode(
                ClipEffectNodeIDEdit(
                    sequenceID: sequenceID, trackID: trackID, clipID: clipID, nodeID: nodeID
                ),
                in: project
            )
        case .resetClipEffectStack(let sequenceID, let trackID, let clipID):
            return try resetClipEffectStack(
                ClipEffectStackEditTarget(
                    sequenceID: sequenceID, trackID: trackID, clipID: clipID
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    static func addClipEffectNode(
        _ edit: AddClipEffectNodeEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffectStack(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            var nodes = clip.effectStack.nodes
            if nodes.contains(where: { node in node.id == edit.node.id }) {
                throw EditReducerError.invalidEdit(
                    .duplicateClipEffectNodeID(clipID: edit.clipID, nodeID: edit.node.id)
                )
            }
            let insertionIndex = edit.destinationIndex ?? nodes.count
            guard insertionIndex >= 0, insertionIndex <= nodes.count else {
                throw EditReducerError.invalidEdit(
                    .clipEffectNodeDestinationIndexOutOfRange(
                        clipID: edit.clipID,
                        index: insertionIndex,
                        count: nodes.count
                    )
                )
            }
            nodes.insert(edit.node, at: insertionIndex)
            return ClipEffectStack(nodes: nodes)
        }
    }

    static func removeClipEffectNode(
        _ edit: ClipEffectNodeIDEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffectStack(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            var nodes = clip.effectStack.nodes
            guard let index = nodes.firstIndex(where: { node in node.id == edit.nodeID }) else {
                throw EditReducerError.invalidEdit(
                    .clipEffectNodeNotFound(clipID: edit.clipID, nodeID: edit.nodeID)
                )
            }
            nodes.remove(at: index)
            return ClipEffectStack(nodes: nodes)
        }
    }

    static func moveClipEffectNode(
        _ edit: MoveClipEffectNodeEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffectStack(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            var nodes = clip.effectStack.nodes
            guard let sourceIndex = nodes.firstIndex(where: { node in node.id == edit.nodeID })
            else {
                throw EditReducerError.invalidEdit(
                    .clipEffectNodeNotFound(clipID: edit.clipID, nodeID: edit.nodeID)
                )
            }
            guard nodes.indices.contains(edit.destinationIndex) else {
                throw EditReducerError.invalidEdit(
                    .clipEffectNodeDestinationIndexOutOfRange(
                        clipID: edit.clipID,
                        index: edit.destinationIndex,
                        count: nodes.count
                    )
                )
            }
            let node = nodes.remove(at: sourceIndex)
            nodes.insert(node, at: edit.destinationIndex)
            return ClipEffectStack(nodes: nodes)
        }
    }

    static func setClipEffectNodeEnabled(
        _ edit: SetClipEffectNodeEnabledEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffectStack(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            try replacingEffectNode(
                id: edit.nodeID,
                in: clip.effectStack,
                clipID: edit.clipID
            ) { node in
                node.replacing(enabled: edit.enabled)
            }
        }
    }

    static func setClipEffectNodeParameters(
        _ edit: SetClipEffectNodeParametersEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffectStack(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            try replacingEffectNode(
                id: edit.nodeID,
                in: clip.effectStack,
                clipID: edit.clipID
            ) { node in
                guard node.kind == edit.definition.kind else {
                    throw EditReducerError.invalidEdit(
                        .invalidClipEffectStack(
                            clipID: edit.clipID,
                            error: .effectNodeKindMismatch(
                                nodeID: edit.nodeID,
                                expected: node.kind,
                                actual: edit.definition.kind
                            )
                        )
                    )
                }
                return node.replacing(definition: edit.definition)
            }
        }
    }

    static func resetClipEffectNode(
        _ edit: ClipEffectNodeIDEdit,
        in project: Project
    ) throws -> Project {
        try updateClipEffectStack(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { clip in
            try replacingEffectNode(
                id: edit.nodeID,
                in: clip.effectStack,
                clipID: edit.clipID
            ) { node in
                node.replacing(definition: .identity(for: node.kind))
            }
        }
    }

    static func resetClipEffectStack(
        _ edit: ClipEffectStackEditTarget,
        in project: Project
    ) throws -> Project {
        try updateClipEffectStack(
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            clipID: edit.clipID,
            in: project
        ) { _ in
            .empty
        }
    }

    private static func replacingEffectNode(
        id nodeID: UUID,
        in stack: ClipEffectStack,
        clipID: UUID,
        update: (ClipEffectNode) throws -> ClipEffectNode
    ) throws -> ClipEffectStack {
        var nodes = stack.nodes
        guard let index = nodes.firstIndex(where: { node in node.id == nodeID }) else {
            throw EditReducerError.invalidEdit(
                .clipEffectNodeNotFound(clipID: clipID, nodeID: nodeID)
            )
        }
        nodes[index] = try update(nodes[index])
        return ClipEffectStack(nodes: nodes)
    }

    private static func validateEffectStack(_ stack: ClipEffectStack, clipID: UUID) throws {
        guard let error = ClipEffectStackValidator.errors(for: stack).first else {
            return
        }
        throw EditReducerError.invalidEdit(
            .invalidClipEffectStack(clipID: clipID, error: error)
        )
    }

    private static func updateClipEffectStack(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        in project: Project,
        update: (Clip) throws -> ClipEffectStack
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            var items = track.items
            guard
                let index = clipIndex(clipID, in: items),
                case .clip(let clip) = items[index]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                )
            }

            let stack = try update(clip)
            try validateEffectStack(stack, clipID: clipID)
            items[index] = .clip(copying(clip, effectStack: stack))
            return copying(track, items: items)
        }
    }
}
