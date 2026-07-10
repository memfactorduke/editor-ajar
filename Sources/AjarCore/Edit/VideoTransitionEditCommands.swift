// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct SetClipVideoTransitionEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let duration: RationalTime
        let kind: ClipVideoTransitionKind
        let color: ClipRGBColor?
        let direction: ClipVideoTransitionDirection?
    }

    static func applyClipVideoTransitionCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .setClipVideoTransition(
            let sequenceID,
            let trackID,
            let clipID,
            let duration,
            let kind,
            let color,
            let direction
        ):
            return try setClipVideoTransition(
                SetClipVideoTransitionEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    duration: duration,
                    kind: kind,
                    color: color,
                    direction: direction
                ),
                in: project
            )
        case .removeClipVideoTransition(let sequenceID, let trackID, let clipID):
            return try removeClipVideoTransition(
                ClipAudioMixEditTarget(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    /// Creates (or updates) the ADR-0016 §5 pair on the cut after the addressed clip:
    /// the outgoing clip gets the owning trailing record, the incoming clip the
    /// non-rendering mirror, with the duration clamped per ADR-0015 §3/§7 vocabulary.
    /// Sequence duration is never changed.
    static func setClipVideoTransition(
        _ edit: SetClipVideoTransitionEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            guard track.kind == .video else {
                throw EditReducerError.invalidEdit(
                    .videoTransitionRequiresVideoTrack(clipID: edit.clipID)
                )
            }
            var items = track.items
            let cut = try videoTransitionCutClips(for: edit, in: items)
            guard edit.duration > .zero else {
                throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: edit.clipID))
            }
            try validateVideoTransitionEdgeClips(outgoing: cut.outgoing, incoming: cut.incoming)
            let color =
                edit.color ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
            let direction = edit.direction ?? .left
            try validateVideoTransitionParameters(
                kind: edit.kind,
                direction: direction,
                clipID: cut.outgoing.id
            )
            let duration = try clampedVideoTransitionDuration(
                edit.duration,
                outgoing: cut.outgoing,
                incoming: cut.incoming,
                in: project
            )
            let record = ClipVideoTransition(
                partnerClipID: cut.incoming.id,
                duration: duration,
                kind: edit.kind,
                color: color,
                direction: direction
            )
            let mirror = ClipVideoTransition(
                partnerClipID: cut.outgoing.id,
                duration: duration,
                kind: edit.kind,
                color: color,
                direction: direction
            )
            items[cut.outgoingIndex] = .clip(
                copying(cut.outgoing, trailingTransition: .some(record))
            )
            items[cut.incomingIndex] = .clip(
                copying(cut.incoming, leadingTransition: .some(mirror))
            )
            return copying(track, items: items)
        }
    }

    /// Removes both records of the pair owned by the addressed clip's trailing edge.
    static func removeClipVideoTransition(
        _ edit: ClipAudioMixEditTarget,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            var items = track.items
            guard
                let index = clipIndex(edit.clipID, in: items),
                case .clip(let outgoing) = items[index]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: edit.sequenceID,
                    trackID: edit.trackID,
                    clipID: edit.clipID
                )
            }
            guard let record = outgoing.trailingTransition else {
                throw EditReducerError.invalidEdit(
                    .videoTransitionNotFound(clipID: edit.clipID)
                )
            }
            items[index] = .clip(
                copying(outgoing, trailingTransition: .some(nil))
            )
            if let partnerIndex = clipIndex(record.partnerClipID, in: items),
                case .clip(let partner) = items[partnerIndex],
                partner.leadingTransition?.partnerClipID == outgoing.id {
                items[partnerIndex] = .clip(
                    copying(partner, leadingTransition: .some(nil))
                )
            }
            return copying(track, items: items)
        }
    }
}

extension EditReducer {
    struct VideoTransitionCutClips {
        let outgoingIndex: Int
        let outgoing: Clip
        let incomingIndex: Int
        let incoming: Clip
    }

    static func videoTransitionCutClips(
        for edit: SetClipVideoTransitionEdit,
        in items: [TimelineItem]
    ) throws -> VideoTransitionCutClips {
        guard
            let outgoingIndex = clipIndex(edit.clipID, in: items),
            case .clip(let outgoing) = items[outgoingIndex]
        else {
            throw EditReducerError.clipNotFound(
                sequenceID: edit.sequenceID,
                trackID: edit.trackID,
                clipID: edit.clipID
            )
        }
        let incomingIndex = items.index(after: outgoingIndex)
        guard
            incomingIndex < items.endIndex,
            case .clip(let incoming) = items[incomingIndex],
            try exactTime({ try outgoing.timelineRange.end() }) == incoming.timelineRange.start
        else {
            throw EditReducerError.invalidEdit(
                .videoTransitionRequiresAdjacentClips(clipID: edit.clipID)
            )
        }
        return VideoTransitionCutClips(
            outgoingIndex: outgoingIndex,
            outgoing: outgoing,
            incomingIndex: incomingIndex,
            incoming: incoming
        )
    }

    static func validateVideoTransitionEdgeClips(outgoing: Clip, incoming: Clip) throws {
        if outgoing.timeRemap != nil {
            throw EditReducerError.invalidEdit(
                .invalidClipVideoTransition(
                    clipID: outgoing.id,
                    error: .transitionUnsupportedWithTimeRemap(
                        edge: .trailing,
                        clipID: outgoing.id
                    )
                )
            )
        }
        if incoming.timeRemap != nil {
            throw EditReducerError.invalidEdit(
                .invalidClipVideoTransition(
                    clipID: incoming.id,
                    error: .transitionUnsupportedWithTimeRemap(
                        edge: .leading,
                        clipID: incoming.id
                    )
                )
            )
        }
    }

    static func validateVideoTransitionParameters(
        kind: ClipVideoTransitionKind,
        direction: ClipVideoTransitionDirection,
        clipID: UUID
    ) throws {
        switch kind {
        case .push, .slide:
            if direction.isDiagonal {
                throw EditReducerError.invalidEdit(
                    .invalidClipVideoTransition(
                        clipID: clipID,
                        error: .transitionDirectionUnsupportedForKind(
                            edge: .trailing,
                            clipID: clipID,
                            kind: kind,
                            direction: direction
                        )
                    )
                )
            }
        case .crossDissolve, .dipToColor, .fade, .wipe, .zoom:
            break
        }
    }

    /// ADR-0015 §3/§7 vocabulary: clamps requested duration to clip durations and the
    /// outgoing tail handle; clamp-to-zero is a typed rejection.
    static func clampedVideoTransitionDuration(
        _ requested: RationalTime,
        outgoing: Clip,
        incoming: Clip,
        in project: Project
    ) throws -> RationalTime {
        let limit = try videoTransitionDurationLimit(
            outgoing: outgoing,
            incoming: incoming,
            mediaDurationsByID: mediaDurationsByID(in: project)
        )
        let clamped = min(requested, limit)
        guard clamped > .zero else {
            guard case .media(let mediaID) = outgoing.source else {
                throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: outgoing.id))
            }
            throw EditReducerError.invalidEdit(
                .invalidClipVideoTransition(
                    clipID: outgoing.id,
                    error: .transitionExceedsSourceHandle(
                        edge: .trailing,
                        clipID: outgoing.id,
                        mediaID: mediaID
                    )
                )
            )
        }
        return clamped
    }
}
