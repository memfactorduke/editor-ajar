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
        let participation = audioTrackParticipation(
            in: sequence,
            references: selectedReferences
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
                participation.fullyIncluded.contains($0)
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

    /// Restores nested FR-AUD-004 ducking rules onto the parent during an FR-CMP-004
    /// decompose, inverting the collapse-time transplant.
    ///
    /// A nested rule is restored when every referenced audio track is fully expanded (all of
    /// its clips landed on the parent), skipping rules the parent already contains verbatim so
    /// decomposing sibling instances of the same nested sequence never duplicates them. A rule
    /// referencing no expanded track stays with the retained nested sequence untouched — like
    /// clips and markers outside the window, it still serves other compound instances. Any
    /// other rule spans the expansion boundary, so the decompose is rejected with a typed
    /// error instead of silently severing the sidechain.
    static func restoredCompoundAudioDucking(
        from targetSequence: Sequence,
        expandedReferences: Set<ClipReference>,
        parentRules: [AudioDuckingRule]
    ) throws -> [AudioDuckingRule] {
        let participation = audioTrackParticipation(
            in: targetSequence,
            references: expandedReferences
        )

        var restored: [AudioDuckingRule] = []
        for (ruleIndex, rule) in targetSequence.audioDucking.enumerated() {
            let referencedTrackIDs = [rule.triggerTrackID] + rule.targetTrackIDs
            if referencedTrackIDs.allSatisfy({
                !participation.participating.contains($0)
            }) {
                continue
            }
            guard referencedTrackIDs.allSatisfy({
                participation.fullyIncluded.contains($0)
            }) else {
                throw EditReducerError.invalidEdit(
                    .compoundDecomposeSeversAudioDucking(
                        sequenceID: targetSequence.id,
                        ruleIndex: ruleIndex
                    )
                )
            }
            if !parentRules.contains(rule), !restored.contains(rule) {
                restored.append(rule)
            }
        }
        return restored
    }

    private struct AudioTrackParticipation {
        var participating: Set<UUID> = []
        var fullyIncluded: Set<UUID> = []
    }

    /// How each audio track of `sequence` participates in a clip-reference set: `participating`
    /// tracks contribute at least one referenced clip; `fullyIncluded` tracks contribute every
    /// clip they hold.
    private static func audioTrackParticipation(
        in sequence: Sequence,
        references: Set<ClipReference>
    ) -> AudioTrackParticipation {
        var participation = AudioTrackParticipation()
        for track in sequence.audioTracks {
            var clipCount = 0
            var referencedCount = 0
            for item in track.items {
                guard case .clip(let clip) = item else {
                    continue
                }
                clipCount += 1
                if references.contains(
                    ClipReference(trackID: track.id, clipID: clip.id)
                ) {
                    referencedCount += 1
                }
            }
            if referencedCount > 0 {
                participation.participating.insert(track.id)
                if referencedCount == clipCount {
                    participation.fullyIncluded.insert(track.id)
                }
            }
        }
        return participation
    }

    static func items(_ items: [TimelineItem], overlap range: TimeRange) throws -> Bool {
        try items.contains { try rangesIntersect($0.timelineRange, range) }
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
