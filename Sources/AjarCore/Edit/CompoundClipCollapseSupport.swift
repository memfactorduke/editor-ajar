// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct CompoundAudioDuckingSplit {
        let outer: [AudioDuckingRule]
        let nested: [AudioDuckingRule]
    }

    /// Splits FR-AUD-004 sidechain ducking rules for an FR-CMP-001 collapse.
    ///
    /// A rule is transplanted into the nested sequence when every referenced audio track is
    /// fully collapsed (all of its clips are selected), so the rule keeps ducking exactly the
    /// clips it ducked before. A rule stays on the outer sequence untouched when none of its
    /// referenced tracks contributes a selected clip. Any other rule spans the collapse
    /// boundary; collapsing would silently sever its sidechain relationship, so the edit is
    /// rejected with a typed error instead of silently changing audible behavior.
    static func splitCompoundSelectionAudioDucking(
        in sequence: Sequence,
        selectedReferences: Set<ClipReference>
    ) throws -> CompoundAudioDuckingSplit {
        let participation = audioTrackCollapseParticipation(
            in: sequence,
            selectedReferences: selectedReferences
        )

        var outer: [AudioDuckingRule] = []
        var nested: [AudioDuckingRule] = []
        for (ruleIndex, rule) in sequence.audioDucking.enumerated() {
            let referencedTrackIDs = [rule.triggerTrackID] + rule.targetTrackIDs
            if referencedTrackIDs.allSatisfy({
                !participation.participating.contains($0)
            }) {
                outer.append(rule)
            } else if referencedTrackIDs.allSatisfy({
                participation.fullyCollapsed.contains($0)
            }) {
                nested.append(rule)
            } else {
                throw EditReducerError.invalidEdit(
                    .compoundSelectionSeversAudioDucking(
                        sequenceID: sequence.id,
                        ruleIndex: ruleIndex
                    )
                )
            }
        }
        return CompoundAudioDuckingSplit(outer: outer, nested: nested)
    }

    private struct AudioTrackCollapseParticipation {
        var participating: Set<UUID> = []
        var fullyCollapsed: Set<UUID> = []
    }

    private static func audioTrackCollapseParticipation(
        in sequence: Sequence,
        selectedReferences: Set<ClipReference>
    ) -> AudioTrackCollapseParticipation {
        var participation = AudioTrackCollapseParticipation()
        for track in sequence.audioTracks {
            var clipCount = 0
            var selectedCount = 0
            for item in track.items {
                guard case .clip(let clip) = item else {
                    continue
                }
                clipCount += 1
                if selectedReferences.contains(
                    ClipReference(trackID: track.id, clipID: clip.id)
                ) {
                    selectedCount += 1
                }
            }
            if selectedCount > 0 {
                participation.participating.insert(track.id)
                if selectedCount == clipCount {
                    participation.fullyCollapsed.insert(track.id)
                }
            }
        }
        return participation
    }

    static func splitCompoundSelectionMarkers(
        in sequence: Sequence,
        selectedReferences: Set<ClipReference>,
        selectionStart: RationalTime
    ) throws -> (outer: [Marker], nested: [Marker]) {
        var outerMarkers: [Marker] = []
        var nestedMarkers: [Marker] = []

        for marker in sequence.markers {
            guard case .clip(let trackID, let clipID) = marker.anchor else {
                outerMarkers.append(marker)
                continue
            }

            if selectedReferences.contains(ClipReference(trackID: trackID, clipID: clipID)) {
                nestedMarkers.append(
                    Marker(
                        id: marker.id,
                        time: try exactTime { try marker.time.subtracting(selectionStart) },
                        name: marker.name,
                        color: marker.color,
                        note: marker.note,
                        anchor: marker.anchor
                    )
                )
            } else {
                outerMarkers.append(marker)
            }
        }

        return (outerMarkers, nestedMarkers)
    }
}
