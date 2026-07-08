// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct SetClipAudioCrossfadeEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let duration: RationalTime
        let curve: ClipAudioFadeCurve?
    }

    static func applyClipAudioCrossfadeCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .setClipAudioCrossfade(
            let sequenceID,
            let trackID,
            let clipID,
            let duration,
            let curve
        ):
            return try setClipAudioCrossfade(
                SetClipAudioCrossfadeEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    duration: duration,
                    curve: curve
                ),
                in: project
            )
        case .removeClipAudioCrossfade(let sequenceID, let trackID, let clipID):
            return try removeClipAudioCrossfade(
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

    /// Creates (or updates) the ADR-0015 §5 pair on the cut after the addressed clip:
    /// the outgoing clip gets the owning trailing record, the incoming clip the
    /// non-rendering mirror, with the duration clamped per §3/§7 and any same-edge fades
    /// cleared per §6 in the same undoable command.
    static func setClipAudioCrossfade(
        _ edit: SetClipAudioCrossfadeEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            guard track.kind == .audio else {
                throw EditReducerError.invalidEdit(
                    .crossfadeRequiresAudioTrack(clipID: edit.clipID)
                )
            }
            var items = track.items
            let cut = try crossfadeCutClips(for: edit, in: items)
            guard edit.duration > .zero else {
                throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: edit.clipID))
            }
            try validateCrossfadeEdgeClips(outgoing: cut.outgoing, incoming: cut.incoming)
            let curve = try resolvedCrossfadeCurve(
                edit.curve,
                outgoing: cut.outgoing,
                incoming: cut.incoming
            )
            let duration = try clampedCrossfadeDuration(
                edit.duration,
                outgoing: cut.outgoing,
                incoming: cut.incoming,
                in: project
            )
            items[cut.outgoingIndex] = .clip(
                copying(
                    cut.outgoing,
                    audioMix: copying(
                        cut.outgoing.audioMix,
                        fadeOut: ClipAudioFade.none,
                        trailingCrossfade: .some(
                            ClipAudioCrossfade(
                                partnerClipID: cut.incoming.id,
                                duration: duration,
                                curve: curve
                            )
                        )
                    )
                )
            )
            items[cut.incomingIndex] = .clip(
                copying(
                    cut.incoming,
                    audioMix: copying(
                        cut.incoming.audioMix,
                        fadeIn: ClipAudioFade.none,
                        leadingCrossfade: .some(
                            ClipAudioCrossfade(
                                partnerClipID: cut.outgoing.id,
                                duration: duration,
                                curve: curve
                            )
                        )
                    )
                )
            )
            return copying(track, items: items)
        }
    }

    /// Removes both records of the pair owned by the addressed clip's trailing edge
    /// atomically.
    static func removeClipAudioCrossfade(
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
            guard let record = outgoing.audioMix.trailingCrossfade else {
                throw EditReducerError.invalidEdit(.crossfadeNotFound(clipID: edit.clipID))
            }
            items[index] = .clip(
                copying(
                    outgoing,
                    audioMix: copying(outgoing.audioMix, trailingCrossfade: .some(nil))
                )
            )
            if let partnerIndex = clipIndex(record.partnerClipID, in: items),
                case .clip(let partner) = items[partnerIndex],
                partner.audioMix.leadingCrossfade?.partnerClipID == outgoing.id {
                items[partnerIndex] = .clip(
                    copying(
                        partner,
                        audioMix: copying(partner.audioMix, leadingCrossfade: .some(nil))
                    )
                )
            }
            return copying(track, items: items)
        }
    }
}

extension EditReducer {
    struct CrossfadeCutClips {
        let outgoingIndex: Int
        let outgoing: Clip
        let incomingIndex: Int
        let incoming: Clip
    }

    /// Locates the addressed outgoing clip and its abutting next clip on the track.
    static func crossfadeCutClips(
        for edit: SetClipAudioCrossfadeEdit,
        in items: [TimelineItem]
    ) throws -> CrossfadeCutClips {
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
                .crossfadeRequiresAdjacentClips(clipID: edit.clipID)
            )
        }
        return CrossfadeCutClips(
            outgoingIndex: outgoingIndex,
            outgoing: outgoing,
            incomingIndex: incomingIndex,
            incoming: incoming
        )
    }

    /// ADR-0015 §2: clips with an FR-SPD-002 time-remap curve reject crossfade edges.
    static func validateCrossfadeEdgeClips(outgoing: Clip, incoming: Clip) throws {
        if outgoing.timeRemap != nil {
            throw EditReducerError.invalidEdit(
                .invalidClipAudioCrossfade(
                    clipID: outgoing.id,
                    error: .crossfadeUnsupportedWithTimeRemap(
                        edge: .trailingCrossfade,
                        clipID: outgoing.id
                    )
                )
            )
        }
        if incoming.timeRemap != nil {
            throw EditReducerError.invalidEdit(
                .invalidClipAudioCrossfade(
                    clipID: incoming.id,
                    error: .crossfadeUnsupportedWithTimeRemap(
                        edge: .leadingCrossfade,
                        clipID: incoming.id
                    )
                )
            )
        }
    }

    /// ADR-0015 §4 curve selection: an explicit user curve wins (rejected unless it is a
    /// crossfade curve); otherwise `linear` for the blade-split signature and `equalPower`
    /// for everything else.
    static func resolvedCrossfadeCurve(
        _ explicit: ClipAudioFadeCurve?,
        outgoing: Clip,
        incoming: Clip
    ) throws -> ClipAudioFadeCurve {
        guard let explicit else {
            return automaticCrossfadeCurve(outgoing: outgoing, incoming: incoming)
        }
        guard ClipAudioCrossfadeValidator.supportedCrossfadeCurves.contains(explicit) else {
            throw EditReducerError.invalidEdit(
                .invalidClipAudioCrossfade(
                    clipID: outgoing.id,
                    error: .crossfadeCurveUnsupported(
                        edge: .trailingCrossfade,
                        clipID: outgoing.id,
                        curve: explicit
                    )
                )
            )
        }
        return explicit
    }

    /// ADR-0015 §4 automatic selection: `linear` when the edges are same-source contiguous
    /// mappings — same media/sequence ID, outgoing `sourceRange.end` equal to the incoming
    /// `sourceRange.start`, identical `speed`/`reverse`, and neither edge frozen (a freeze
    /// frame holds one frame, so its content does not continue across the cut) — else
    /// `equalPower`.
    static func automaticCrossfadeCurve(outgoing: Clip, incoming: Clip) -> ClipAudioFadeCurve {
        guard
            outgoing.source == incoming.source,
            outgoing.speed == incoming.speed,
            outgoing.reverse == incoming.reverse,
            !outgoing.freezeFrame,
            !incoming.freezeFrame,
            let outgoingSourceEnd = try? outgoing.sourceRange.end(),
            outgoingSourceEnd == incoming.sourceRange.start
        else {
            return .equalPower
        }
        return .linear
    }

    /// ADR-0015 §3/§7: clamps the requested duration to the clip durations and the
    /// outgoing tail handle; clamping to zero is a typed rejection, never a silent no-op.
    static func clampedCrossfadeDuration(
        _ requested: RationalTime,
        outgoing: Clip,
        incoming: Clip,
        in project: Project
    ) throws -> RationalTime {
        let limit = try crossfadeDurationLimit(
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
                .invalidClipAudioCrossfade(
                    clipID: outgoing.id,
                    error: .crossfadeExceedsSourceHandle(
                        edge: .trailingCrossfade,
                        clipID: outgoing.id,
                        mediaID: mediaID
                    )
                )
            )
        }
        return clamped
    }
}
