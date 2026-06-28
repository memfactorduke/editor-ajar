// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct TrackAudioMixEdit {
        let sequenceID: UUID
        let trackID: UUID
        let audio: TrackAudioMixPatch
    }

    struct TrackAudioMixTarget {
        let sequenceID: UUID
        let trackID: UUID
    }

    static func setTrackAudioMix(
        _ edit: TrackAudioMixEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            copying(track, audio: edit.audio)
        }
    }

    static func clearTrackAudioMix(
        _ target: TrackAudioMixTarget,
        in project: Project
    ) throws -> Project {
        try setTrackAudioMix(
            TrackAudioMixEdit(
                sequenceID: target.sequenceID,
                trackID: target.trackID,
                audio: TrackAudioMixPatch(gain: .constant(.one), pan: .constant(.zero))
            ),
            in: project
        )
    }

    static func copying(
        _ track: Track,
        audio: TrackAudioMixPatch
    ) -> Track {
        Track(
            id: track.id,
            kind: track.kind,
            items: track.items,
            enabled: track.enabled,
            locked: track.locked,
            muted: track.muted,
            solo: track.solo,
            hidden: track.hidden,
            opacity: track.opacity,
            blendMode: track.blendMode,
            audioGain: audio.gain ?? track.audioGain,
            audioPan: audio.pan ?? track.audioPan
        )
    }
}
