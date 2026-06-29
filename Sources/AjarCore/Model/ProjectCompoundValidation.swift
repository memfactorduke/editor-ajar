// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ProjectValidator {
    struct SequenceReferenceEdge {
        let targetID: UUID
    }

    static func sequenceReferenceGraph(
        in project: Project
    ) -> [UUID: [SequenceReferenceEdge]] {
        var references: [UUID: [SequenceReferenceEdge]] = [:]

        for sequence in project.sequences {
            for track in sequence.videoTracks + sequence.audioTracks {
                for item in track.items {
                    guard case .clip(let clip) = item else {
                        continue
                    }

                    if case .sequence(let targetID) = clip.source {
                        references[sequence.id, default: []].append(
                            SequenceReferenceEdge(targetID: targetID)
                        )
                    }
                }
            }
        }

        return references
    }

    static func sequenceReferenceCreatesCycle(
        sourceID: UUID,
        targetID: UUID,
        referencesBySource: [UUID: [SequenceReferenceEdge]]
    ) -> Bool {
        return sequenceReachable(
            from: targetID,
            to: sourceID,
            referencesBySource: referencesBySource
        )
    }

    private static func sequenceReachable(
        from startID: UUID,
        to goalID: UUID,
        referencesBySource: [UUID: [SequenceReferenceEdge]]
    ) -> Bool {
        var visited = Set<UUID>()
        var stack = [startID]

        while let currentID = stack.popLast() {
            if currentID == goalID {
                return true
            }
            guard visited.insert(currentID).inserted else {
                continue
            }
            stack.append(contentsOf: referencesBySource[currentID, default: []].map(\.targetID))
        }

        return false
    }
}
