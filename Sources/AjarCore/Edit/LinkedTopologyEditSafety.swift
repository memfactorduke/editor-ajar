// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    private struct LinkedTopologyMember {
        let trackID: UUID
        let trackLocked: Bool
        let clip: Clip
    }

    private struct LinkedBladeIntent {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let atTime: RationalTime
        let rightClipID: UUID
    }

    private struct LinkedBladeValidationContext {
        let sequenceID: UUID
        let linkGroupID: UUID
        let members: [LinkedTopologyMember]
        let intents: [LinkedBladeIntent]
        let mutations: [LinkedMemberMutation]
        let editedSequence: Sequence
    }

    private enum LinkedMemberMutation: Equatable {
        case removed
        case retained(
            timelineStartDelta: RationalTime,
            durationDelta: RationalTime,
            linkGroupID: UUID?
        )
    }

    /// Insert, overwrite, and blade are track-local primitives, but linked A/V is a multi-track
    /// topology. A direct primitive must not move, remove, or split just one member. Transactions
    /// remain the grouped path: their fully applied result is checked here, after every primitive
    /// has run but before the project enters history or central validation.
    static func validateLinkedTopologyEdit(
        _ command: EditCommand,
        from originalProject: Project,
        to editedProject: Project
    ) throws {
        guard containsLinkedTopologySensitiveCommand(command) else {
            return
        }

        let bladeIntents = linkedBladeIntents(in: command)
        for originalSequence in originalProject.sequences {
            guard
                let editedSequence = editedProject.sequences.first(where: {
                    $0.id == originalSequence.id
                })
            else {
                continue
            }
            try validateLinkedTopologyGroups(
                in: originalSequence,
                editedSequence: editedSequence,
                bladeIntents: bladeIntents
            )
            try validateNewLinkedTopologyGroups(
                in: originalSequence,
                editedSequence: editedSequence
            )
        }
    }

    /// Existing projects may contain legacy malformed link identities, so this gate deliberately
    /// leaves untouched groups alone. Any group introduced by the current topology edit must meet
    /// the same minimum shape enforced by `linkClips`: at least two members spanning both essences.
    private static func validateNewLinkedTopologyGroups(
        in originalSequence: Sequence,
        editedSequence: Sequence
    ) throws {
        let originalGroupIDs = Set(linkedTopologyGroups(in: originalSequence).keys)
        let editedGroups = linkedTopologyGroups(in: editedSequence)
        for (linkGroupID, members) in editedGroups where !originalGroupIDs.contains(linkGroupID) {
            guard members.count >= 2 else {
                throw EditReducerError.invalidEdit(
                    .linkRequiresAtLeastTwoClips(linkGroupID: linkGroupID)
                )
            }
            let hasVideo = members.contains { $0.clip.kind == .video }
            let hasAudio = members.contains { $0.clip.kind == .audio }
            guard hasVideo, hasAudio else {
                throw EditReducerError.invalidEdit(
                    .linkRequiresVideoAndAudio(linkGroupID: linkGroupID)
                )
            }
        }
    }

    private static func validateLinkedTopologyGroups(
        in originalSequence: Sequence,
        editedSequence: Sequence,
        bladeIntents: [LinkedBladeIntent]
    ) throws {
        let groups = linkedTopologyGroups(in: originalSequence)
        for (linkGroupID, members) in groups {
            let intents = bladeIntents.filter { intent in
                intent.sequenceID == originalSequence.id
                    && members.contains(where: {
                        $0.trackID == intent.trackID && $0.clip.id == intent.clipID
                    })
            }
            let mutations = try members.map { member in
                try linkedMemberMutation(member, in: editedSequence)
            }
            let wasAffected =
                !intents.isEmpty
                || zip(members, mutations).contains {
                    !linkedMemberIsUnchanged(
                        original: $0.0.clip,
                        mutation: $0.1,
                        linkGroupID: linkGroupID
                    )
                }
            guard wasAffected else {
                continue
            }
            try rejectLockedLinkedTopologyGroup(
                sequenceID: originalSequence.id,
                linkGroupID: linkGroupID,
                members: members
            )
            if intents.isEmpty {
                guard linkedMutationsMatch(mutations) else {
                    throw linkedTopologyDesynchronizationError(
                        sequenceID: originalSequence.id,
                        linkGroupID: linkGroupID
                    )
                }
            } else {
                try validateGroupedBlade(
                    LinkedBladeValidationContext(
                        sequenceID: originalSequence.id,
                        linkGroupID: linkGroupID,
                        members: members,
                        intents: intents,
                        mutations: mutations,
                        editedSequence: editedSequence
                    )
                )
            }
        }
    }

    private static func rejectLockedLinkedTopologyGroup(
        sequenceID: UUID,
        linkGroupID: UUID,
        members: [LinkedTopologyMember]
    ) throws {
        guard let lockedMember = members.first(where: \.trackLocked) else {
            return
        }
        throw EditReducerError.invalidEdit(
            .linkedEditTargetsLockedTrack(
                sequenceID: sequenceID,
                linkGroupID: linkGroupID,
                trackID: lockedMember.trackID
            )
        )
    }

    private static func containsLinkedTopologySensitiveCommand(_ command: EditCommand) -> Bool {
        switch command {
        case .insertClip, .overwriteClip, .bladeClip, .rippleDeleteClip, .liftClip:
            return true
        case .threePointEdit:
            return true
        case .transaction(let commands):
            return commands.contains(where: containsLinkedTopologySensitiveCommand)
        default:
            return false
        }
    }

    private static func linkedBladeIntents(in command: EditCommand) -> [LinkedBladeIntent] {
        switch command {
        case .bladeClip(
            let sequenceID,
            let trackID,
            let clipID,
            let atTime,
            let rightClipID
        ):
            return [
                LinkedBladeIntent(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    atTime: atTime,
                    rightClipID: rightClipID
                )
            ]
        case .transaction(let commands):
            return commands.flatMap(linkedBladeIntents)
        default:
            return []
        }
    }

    private static func linkedTopologyGroups(
        in sequence: Sequence
    ) -> [UUID: [LinkedTopologyMember]] {
        var groups: [UUID: [LinkedTopologyMember]] = [:]
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard case .clip(let clip) = item,
                    let linkGroupID = clip.linkGroupID
                else {
                    continue
                }
                groups[linkGroupID, default: []].append(
                    LinkedTopologyMember(
                        trackID: track.id,
                        trackLocked: track.locked,
                        clip: clip
                    )
                )
            }
        }
        return groups
    }

    private static func linkedMemberMutation(
        _ member: LinkedTopologyMember,
        in editedSequence: Sequence
    ) throws -> LinkedMemberMutation {
        guard let editedClip = clip(withID: member.clip.id, in: editedSequence) else {
            return .removed
        }
        return .retained(
            timelineStartDelta: try subtractTimes(
                editedClip.timelineRange.start,
                member.clip.timelineRange.start
            ),
            durationDelta: try subtractTimes(
                editedClip.timelineRange.duration,
                member.clip.timelineRange.duration
            ),
            linkGroupID: editedClip.linkGroupID
        )
    }

    private static func linkedMemberIsUnchanged(
        original: Clip,
        mutation: LinkedMemberMutation,
        linkGroupID: UUID
    ) -> Bool {
        guard
            case .retained(
                timelineStartDelta: .zero,
                durationDelta: .zero,
                linkGroupID: let retainedLinkGroupID
            ) = mutation,
            retainedLinkGroupID == linkGroupID
        else {
            return false
        }
        return original.linkGroupID == linkGroupID
    }

    private static func linkedMutationsMatch(_ mutations: [LinkedMemberMutation]) -> Bool {
        guard let first = mutations.first else {
            return true
        }
        return mutations.dropFirst().allSatisfy { $0 == first }
    }

    private static func validateGroupedBlade(_ context: LinkedBladeValidationContext) throws {
        let refusal = linkedTopologyDesynchronizationError(
            sequenceID: context.sequenceID,
            linkGroupID: context.linkGroupID
        )
        guard context.intents.count == context.members.count,
            Set(context.intents.map(\.clipID)).count == context.members.count,
            let cut = context.intents.first?.atTime,
            context.intents.allSatisfy({ $0.atTime == cut }),
            context.mutations.allSatisfy({ mutation in
                guard case .retained(_, _, let retainedLinkGroupID) = mutation else {
                    return false
                }
                return retainedLinkGroupID == context.linkGroupID
            })
        else {
            throw refusal
        }

        for member in context.members {
            guard let left = clip(withID: member.clip.id, in: context.editedSequence),
                try left.timelineRange.end() == cut
            else {
                throw refusal
            }
        }

        let rightClips = context.intents.compactMap {
            clip(withID: $0.rightClipID, in: context.editedSequence)
        }
        guard rightClips.count == context.intents.count,
            let rightGroupID = rightClips.first?.linkGroupID,
            rightGroupID != context.linkGroupID,
            rightClips.allSatisfy({ $0.linkGroupID == rightGroupID })
        else {
            throw refusal
        }

        let rightClipIDs = Set(rightClips.map(\.id))
        let finalRightGroupIDs = Set(
            linkedTopologyGroups(
                in: context.editedSequence
            )[rightGroupID, default: []].map { $0.clip.id }
        )
        guard finalRightGroupIDs == rightClipIDs else {
            throw refusal
        }

        let startOffsets = try zip(context.intents, rightClips).map { intent, rightClip in
            try subtractTimes(rightClip.timelineRange.start, intent.atTime)
        }
        guard startOffsets.dropFirst().allSatisfy({ $0 == startOffsets.first }) else {
            throw refusal
        }
    }

    private static func clip(withID clipID: UUID, in sequence: Sequence) -> Clip? {
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard case .clip(let clip) = item, clip.id == clipID else {
                    continue
                }
                return clip
            }
        }
        return nil
    }

    private static func linkedTopologyDesynchronizationError(
        sequenceID: UUID,
        linkGroupID: UUID
    ) -> EditReducerError {
        .invalidEdit(
            .linkedEditWouldDesynchronizeGroup(
                sequenceID: sequenceID,
                linkGroupID: linkGroupID
            )
        )
    }
}
