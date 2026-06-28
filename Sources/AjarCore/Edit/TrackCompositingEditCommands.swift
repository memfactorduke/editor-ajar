// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct TrackCompositingEdit {
        let sequenceID: UUID
        let trackID: UUID
        let compositing: TrackCompositingPatch
    }

    static func setTrackCompositing(
        _ edit: TrackCompositingEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            copying(track, compositing: edit.compositing)
        }
    }

    static func copying(
        _ track: Track,
        compositing: TrackCompositingPatch
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
            opacity: compositing.opacity ?? track.opacity,
            blendMode: compositing.blendMode ?? track.blendMode,
            audioGain: track.audioGain,
            audioPan: track.audioPan
        )
    }
}
