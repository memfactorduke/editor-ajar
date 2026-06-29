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

    private static func decomposeCompoundClip(
        _ edit: DecomposeCompoundClipEdit,
        targetSequence: Sequence,
        in project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: edit.sequenceID) { parentSequence in
            var videoTracks = parentSequence.videoTracks
            var audioTracks = parentSequence.audioTracks
            let compoundLocation = try locateTrack(edit.trackID, in: parentSequence)
            let compoundTrack = track(
                at: compoundLocation,
                videoTracks: videoTracks,
                audioTracks: audioTracks
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

            // Keep the referenced sequence. It may still be used by other compound instances,
            // and automatic orphan cleanup would be a separate explicit edit.
            var compoundItems = compoundTrack.items
            compoundItems.remove(at: itemIndex)
            setTrack(
                copying(compoundTrack, items: compoundItems),
                at: compoundLocation,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )

            try insertDecomposedTracks(
                from: targetSequence.videoTracks,
                compoundClip: compoundClip,
                sequenceID: edit.sequenceID,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )
            try insertDecomposedTracks(
                from: targetSequence.audioTracks,
                compoundClip: compoundClip,
                sequenceID: edit.sequenceID,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )

            return copying(parentSequence, videoTracks: videoTracks, audioTracks: audioTracks)
        }
    }

    private static func insertDecomposedTracks(
        from nestedTracks: [Track],
        compoundClip: Clip,
        sequenceID: UUID,
        videoTracks: inout [Track],
        audioTracks: inout [Track]
    ) throws {
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
        }
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

    private static func decomposedClips(
        from nestedTrack: Track,
        compoundClip: Clip
    ) throws -> [Clip] {
        var clips: [Clip] = []
        for item in nestedTrack.items {
            guard case .clip(let clip) = item else {
                continue
            }
            clips.append(
                copying(
                    clip,
                    timelineRange: try decomposedTimelineRange(
                        for: clip,
                        compoundClip: compoundClip
                    ),
                    speed: try combinedSpeed(clip.speed, compoundClip.speed)
                )
            )
        }
        return clips
    }

    private static func decomposedTimelineRange(
        for clip: Clip,
        compoundClip: Clip
    ) throws -> TimeRange {
        let nestedStartOffset = try exactTime {
            try clip.timelineRange.start.subtracting(compoundClip.sourceRange.start)
        }
        let parentStartOffset = try speedTimelineDuration(
            clipID: compoundClip.id,
            sourceDuration: nestedStartOffset,
            speed: compoundClip.speed
        )
        let parentStart = try exactTime {
            try compoundClip.timelineRange.start.adding(parentStartOffset)
        }
        let parentDuration = try speedTimelineDuration(
            clipID: compoundClip.id,
            sourceDuration: clip.timelineRange.duration,
            speed: compoundClip.speed
        )

        return try makeRange(start: parentStart, duration: parentDuration)
    }

    private static func combinedSpeed(
        _ clipSpeed: RationalValue,
        _ compoundSpeed: RationalValue
    ) throws -> RationalValue {
        do {
            let numerator = try RationalTime.multiplied(
                clipSpeed.numerator,
                by: compoundSpeed.numerator
            )
            let denominator = try RationalTime.multiplied(
                clipSpeed.denominator,
                by: compoundSpeed.denominator
            )
            return try RationalValue(numerator: numerator, denominator: denominator)
        } catch let error as RationalTimeError {
            throw EditReducerError.timeArithmeticFailed(error)
        }
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
