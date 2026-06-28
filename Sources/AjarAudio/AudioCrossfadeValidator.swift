// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

extension OfflineAudioMixer {
    static func validateCrossfades(in sequence: Sequence) throws {
        for track in sequence.audioTracks where track.kind == .audio {
            try validateCrossfades(in: track.items)
        }
    }
}

private extension OfflineAudioMixer {
    static func validateCrossfades(in items: [TimelineItem]) throws {
        for index in items.indices {
            guard case .clip(let clip) = items[index] else {
                continue
            }
            try validateCrossfade(
                clip.audioMix.leadingCrossfade,
                edge: .leadingCrossfade,
                clip: clip,
                adjacentClip: adjacentClip(before: index, in: items),
                items: items
            )
            try validateCrossfade(
                clip.audioMix.trailingCrossfade,
                edge: .trailingCrossfade,
                clip: clip,
                adjacentClip: adjacentClip(after: index, in: items),
                items: items
            )
        }
    }

    static func validateCrossfade(
        _ crossfade: ClipAudioCrossfade?,
        edge: ClipAudioFadeEdge,
        clip: Clip,
        adjacentClip: Clip?,
        items: [TimelineItem]
    ) throws {
        guard let crossfade else {
            return
        }
        if crossfade.partnerClipID == clip.id {
            throw AudioRenderError.crossfadePartnerMatchesClip(edge: edge, clipID: clip.id)
        }
        guard containsClip(crossfade.partnerClipID, in: items) else {
            throw AudioRenderError.crossfadePartnerMissing(
                edge: edge,
                clipID: clip.id,
                partnerClipID: crossfade.partnerClipID
            )
        }
        guard let adjacentClip,
              adjacentClip.id == crossfade.partnerClipID,
              try touches(clip, adjacentClip: adjacentClip, edge: edge)
        else {
            throw AudioRenderError.crossfadePartnerNotAdjacent(
                edge: edge,
                clipID: clip.id,
                partnerClipID: crossfade.partnerClipID
            )
        }
    }

    static func adjacentClip(
        before index: Array<TimelineItem>.Index,
        in items: [TimelineItem]
    ) -> Clip? {
        guard index > items.startIndex else {
            return nil
        }
        if case .clip(let clip) = items[items.index(before: index)] {
            return clip
        }
        return nil
    }

    static func adjacentClip(
        after index: Array<TimelineItem>.Index,
        in items: [TimelineItem]
    ) -> Clip? {
        let nextIndex = items.index(after: index)
        guard nextIndex < items.endIndex else {
            return nil
        }
        if case .clip(let clip) = items[nextIndex] {
            return clip
        }
        return nil
    }

    static func containsClip(_ clipID: UUID, in items: [TimelineItem]) -> Bool {
        items.contains { item in
            if case .clip(let clip) = item {
                return clip.id == clipID
            }
            return false
        }
    }

    static func touches(_ clip: Clip, adjacentClip: Clip, edge: ClipAudioFadeEdge) throws -> Bool {
        do {
            switch edge {
            case .leadingCrossfade:
                return try adjacentClip.timelineRange.end() == clip.timelineRange.start
            case .trailingCrossfade:
                return try clip.timelineRange.end() == adjacentClip.timelineRange.start
            case .fadeIn, .fadeOut:
                return true
            }
        } catch {
            throw AudioRenderError.timeArithmetic(String(describing: error))
        }
    }
}
