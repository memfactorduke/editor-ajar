// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct DecomposeCompoundClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
    }

    static func decomposeCompoundClip(
        _ edit: DecomposeCompoundClipEdit,
        in project: Project
    ) throws -> Project {
        try decomposeCompoundClipResolvingTarget(edit, in: project)
    }

    private static func decomposeCompoundClipResolvingTarget(
        _ edit: DecomposeCompoundClipEdit,
        in project: Project
    ) throws -> Project {
        guard let parentSequence = project.sequences.first(where: { $0.id == edit.sequenceID })
        else {
            throw EditReducerError.sequenceNotFound(edit.sequenceID)
        }
        let parentTrack = try track(
            at: locateTrack(edit.trackID, in: parentSequence),
            videoTracks: parentSequence.videoTracks,
            audioTracks: parentSequence.audioTracks
        )
        guard
            let itemIndex = clipIndex(edit.clipID, in: parentTrack.items),
            case .clip(let compoundClip) = parentTrack.items[itemIndex]
        else {
            throw EditReducerError.clipNotFound(
                sequenceID: edit.sequenceID,
                trackID: edit.trackID,
                clipID: edit.clipID
            )
        }
        guard case .sequence(let targetSequenceID) = compoundClip.source else {
            throw EditReducerError.invalidEdit(
                .decomposeRequiresCompoundClip(clipID: edit.clipID)
            )
        }
        guard let targetSequence = project.sequences.first(where: { $0.id == targetSequenceID })
        else {
            throw EditReducerError.sequenceNotFound(targetSequenceID)
        }

        return try decomposeCompoundClip(edit, targetSequence: targetSequence, in: project)
    }

    private struct DecomposeCompoundTarget {
        let location: TrackLocation
        let itemIndex: Int
        let compoundClip: Clip
    }

    private static func decomposeCompoundClip(
        _ edit: DecomposeCompoundClipEdit,
        targetSequence: Sequence,
        in project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: edit.sequenceID) { parentSequence in
            let target = try validatedDecomposeTarget(edit, in: parentSequence)
            try validateDecomposableNestedTrackAutomation(
                in: targetSequence,
                compoundClipID: target.compoundClip.id
            )
            var videoTracks = parentSequence.videoTracks
            var audioTracks = parentSequence.audioTracks

            // Keep the referenced sequence. It may still be used by other compound instances,
            // and automatic orphan cleanup would be a separate explicit edit.
            let compoundTrack = track(
                at: target.location,
                videoTracks: videoTracks,
                audioTracks: audioTracks
            )
            var compoundItems = compoundTrack.items
            compoundItems.remove(at: target.itemIndex)
            setTrack(
                copying(compoundTrack, items: compoundItems),
                at: target.location,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )

            var expandedReferences: [ClipReference] = []
            expandedReferences += try insertDecomposedTracks(
                from: targetSequence.videoTracks,
                compoundClip: target.compoundClip,
                sequenceID: edit.sequenceID,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )
            expandedReferences += try insertDecomposedTracks(
                from: targetSequence.audioTracks,
                compoundClip: target.compoundClip,
                sequenceID: edit.sequenceID,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )
            let restoredMarkers = try decomposedMarkers(
                from: targetSequence,
                compoundClip: target.compoundClip,
                expandedReferences: Set(expandedReferences),
                parentMarkerIDs: Set(parentSequence.markers.map(\.id))
            )
            let restoredDucking = try restoredCompoundAudioDucking(
                from: targetSequence,
                expandedReferences: Set(expandedReferences),
                parentRules: parentSequence.audioDucking
            )

            return copying(
                parentSequence,
                videoTracks: videoTracks,
                audioTracks: audioTracks,
                markers: sortedMarkers(parentSequence.markers + restoredMarkers),
                audioDucking: parentSequence.audioDucking + restoredDucking
            )
        }
    }

    private static func validatedDecomposeTarget(
        _ edit: DecomposeCompoundClipEdit,
        in parentSequence: Sequence
    ) throws -> DecomposeCompoundTarget {
        let location = try locateTrack(edit.trackID, in: parentSequence)
        let compoundTrack = track(
            at: location,
            videoTracks: parentSequence.videoTracks,
            audioTracks: parentSequence.audioTracks
        )
        guard
            let itemIndex = clipIndex(edit.clipID, in: compoundTrack.items),
            case .clip(let compoundClip) = compoundTrack.items[itemIndex]
        else {
            throw EditReducerError.clipNotFound(
                sequenceID: edit.sequenceID,
                trackID: edit.trackID,
                clipID: edit.clipID
            )
        }
        guard case .sequence = compoundClip.source else {
            throw EditReducerError.invalidEdit(
                .decomposeRequiresCompoundClip(clipID: edit.clipID)
            )
        }
        try validateDecomposableCompoundAttributes(compoundClip)
        try validateMatchingDurations(
            clipID: compoundClip.id,
            sourceRange: compoundClip.sourceRange,
            timelineRange: compoundClip.timelineRange,
            speed: compoundClip.speed
        )
        return DecomposeCompoundTarget(
            location: location,
            itemIndex: itemIndex,
            compoundClip: compoundClip
        )
    }

    private static func insertDecomposedTracks(
        from nestedTracks: [Track],
        compoundClip: Clip,
        sequenceID: UUID,
        videoTracks: inout [Track],
        audioTracks: inout [Track]
    ) throws -> [ClipReference] {
        var expandedReferences: [ClipReference] = []
        for nestedTrack in nestedTracks {
            let clips = try decomposedClips(from: nestedTrack, compoundClip: compoundClip)
            guard !clips.isEmpty else {
                continue
            }

            try insertDecomposedClips(
                clips,
                nestedTrack: nestedTrack,
                sequenceID: sequenceID,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )
            expandedReferences += clips.map {
                ClipReference(trackID: nestedTrack.id, clipID: $0.id)
            }
        }
        return expandedReferences
    }

    private static func insertDecomposedClips(
        _ clips: [Clip],
        nestedTrack: Track,
        sequenceID: UUID,
        videoTracks: inout [Track],
        audioTracks: inout [Track]
    ) throws {
        guard let location = try existingTrackLocation(
            for: nestedTrack,
            sequenceID: sequenceID,
            videoTracks: videoTracks,
            audioTracks: audioTracks
        ) else {
            let replacement = copying(
                nestedTrack,
                items: sortedItems(clips.map { TimelineItem.clip($0) })
            )
            switch nestedTrack.kind {
            case .video:
                videoTracks.append(replacement)
            case .audio:
                audioTracks.append(replacement)
            }
            return
        }

        let parentTrack = track(at: location, videoTracks: videoTracks, audioTracks: audioTracks)
        var parentItems = parentTrack.items
        for clip in clips {
            if try items(parentItems, overlap: clip.timelineRange) {
                throw EditReducerError.invalidEdit(
                    .compoundDecomposeWouldOverlap(
                        sequenceID: sequenceID,
                        trackID: nestedTrack.id,
                        clipID: clip.id,
                        timelineRange: clip.timelineRange
                    )
                )
            }
            parentItems.append(.clip(clip))
        }
        setTrack(
            copying(parentTrack, items: sortedItems(parentItems)),
            at: location,
            videoTracks: &videoTracks,
            audioTracks: &audioTracks
        )
    }

    private static func existingTrackLocation(
        for nestedTrack: Track,
        sequenceID: UUID,
        videoTracks: [Track],
        audioTracks: [Track]
    ) throws -> TrackLocation? {
        let videoIndex = videoTracks.firstIndex { $0.id == nestedTrack.id }
        let audioIndex = audioTracks.firstIndex { $0.id == nestedTrack.id }

        switch (videoIndex, audioIndex, nestedTrack.kind) {
        case (.some(let index), .none, .video):
            return TrackLocation(collection: .video, index: index)
        case (.none, .some(let index), .audio):
            return TrackLocation(collection: .audio, index: index)
        case (.none, .none, _):
            return nil
        default:
            throw EditReducerError.duplicateTrackID(
                sequenceID: sequenceID,
                trackID: nestedTrack.id
            )
        }
    }
}
