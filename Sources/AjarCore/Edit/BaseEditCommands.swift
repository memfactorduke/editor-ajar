// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    enum TrackCollection {
        case video
        case audio
    }

    struct TrackLocation {
        let collection: TrackCollection
        let index: Int
    }

    struct ClipLocation {
        let reference: ClipReference
        let trackLocation: TrackLocation
        let itemIndex: Int
        let clip: Clip
    }

    struct MoveClipEdit {
        let clipID: UUID
        let sequenceID: UUID
        let sourceTrackID: UUID
        let destinationTrackID: UUID
        let timelineRange: TimeRange
        let linkedClipEditMode: LinkedClipEditMode
    }

    struct TrimClipEdit {
        let clipID: UUID
        let sequenceID: UUID
        let trackID: UUID
        let sourceRange: TimeRange
        let timelineRange: TimeRange
        let linkedClipEditMode: LinkedClipEditMode
    }

    struct TrackStateEdit {
        let sequenceID: UUID
        let trackID: UUID
        let state: TrackStatePatch
    }

    static func addClip(
        _ clip: Clip,
        sequenceID: UUID,
        trackID: UUID,
        to project: Project
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            var items = track.items
            items.append(.clip(clip))
            return copying(track, items: sortedItems(items))
        }
    }

    static func removeClip(
        clipID: UUID,
        sequenceID: UUID,
        trackID: UUID,
        from project: Project
    ) throws -> Project {
        try replacingTrack(trackID, sequenceID: sequenceID, in: project) { track in
            var items = track.items
            guard let index = clipIndex(clipID, in: items) else {
                throw EditReducerError.clipNotFound(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID
                )
            }
            items.remove(at: index)
            return copying(track, items: items)
        }
    }

    static func moveClipWithoutLinkedPartners(
        _ edit: MoveClipEdit,
        in project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: edit.sequenceID) { sequence in
            var videoTracks = sequence.videoTracks
            var audioTracks = sequence.audioTracks
            let sourceLocation = try locateTrack(edit.sourceTrackID, in: sequence)
            let destinationLocation = try locateTrack(edit.destinationTrackID, in: sequence)
            let sourceTrack = track(
                at: sourceLocation,
                videoTracks: videoTracks,
                audioTracks: audioTracks
            )
            var sourceItems = sourceTrack.items

            guard
                let sourceItemIndex = clipIndex(edit.clipID, in: sourceItems),
                case .clip(let clip) = sourceItems[sourceItemIndex]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: edit.sequenceID,
                    trackID: edit.sourceTrackID,
                    clipID: edit.clipID
                )
            }

            sourceItems.remove(at: sourceItemIndex)
            setTrack(
                copying(sourceTrack, items: sourceItems),
                at: sourceLocation,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )

            let movedClip = copying(clip, timelineRange: edit.timelineRange)
            let destinationTrack = track(
                at: destinationLocation,
                videoTracks: videoTracks,
                audioTracks: audioTracks
            )
            var destinationItems = destinationTrack.items
            destinationItems.append(.clip(movedClip))
            setTrack(
                copying(destinationTrack, items: sortedItems(destinationItems)),
                at: destinationLocation,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )

            return copying(sequence, videoTracks: videoTracks, audioTracks: audioTracks)
        }
    }

    static func trimClipWithoutLinkedPartners(
        _ edit: TrimClipEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            var items = track.items
            guard
                let index = clipIndex(edit.clipID, in: items),
                case .clip(let clip) = items[index]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: edit.sequenceID,
                    trackID: edit.trackID,
                    clipID: edit.clipID
                )
            }

            items[index] = .clip(
                copying(
                    clip,
                    sourceRange: edit.sourceRange,
                    timelineRange: edit.timelineRange
                )
            )
            return copying(track, items: sortedItems(items))
        }
    }

    static func addTrack(
        _ track: Track,
        sequenceID: UUID,
        to project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            guard
                !sequence.videoTracks.contains(where: { $0.id == track.id }),
                !sequence.audioTracks.contains(where: { $0.id == track.id })
            else {
                throw EditReducerError.duplicateTrackID(sequenceID: sequenceID, trackID: track.id)
            }

            switch track.kind {
            case .video:
                return copying(sequence, videoTracks: sequence.videoTracks + [track])
            case .audio:
                return copying(sequence, audioTracks: sequence.audioTracks + [track])
            }
        }
    }

    static func removeTrack(
        trackID: UUID,
        sequenceID: UUID,
        from project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            var videoTracks = sequence.videoTracks
            var audioTracks = sequence.audioTracks
            let location = try locateTrack(trackID, in: sequence)

            switch location.collection {
            case .video:
                videoTracks.remove(at: location.index)
            case .audio:
                audioTracks.remove(at: location.index)
            }

            return copying(sequence, videoTracks: videoTracks, audioTracks: audioTracks)
        }
    }

    static func setTrackState(_ edit: TrackStateEdit, in project: Project) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            copying(track, state: edit.state)
        }
    }

    static func renameSequence(
        sequenceID: UUID,
        name: String,
        in project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            copying(sequence, name: name)
        }
    }

    static func addSequence(_ sequence: Sequence, to project: Project) throws -> Project {
        guard !project.sequences.contains(where: { $0.id == sequence.id }) else {
            throw EditReducerError.duplicateSequenceID(sequence.id)
        }

        return Project(
            schemaVersion: project.schemaVersion,
            settings: project.settings,
            mediaPool: project.mediaPool,
            sequences: project.sequences + [sequence]
        )
    }

    static func removeSequence(sequenceID: UUID, from project: Project) throws -> Project {
        guard let index = project.sequences.firstIndex(where: { $0.id == sequenceID }) else {
            throw EditReducerError.sequenceNotFound(sequenceID)
        }
        guard project.sequences.count > 1 else {
            throw EditReducerError.cannotRemoveLastSequence(sequenceID)
        }

        var sequences = project.sequences
        sequences.remove(at: index)
        return Project(
            schemaVersion: project.schemaVersion,
            settings: project.settings,
            mediaPool: project.mediaPool,
            sequences: sequences
        )
    }

    static func duplicateSequence(
        sourceSequenceID: UUID,
        duplicate: Sequence,
        in project: Project
    ) throws -> Project {
        guard let sourceIndex = project.sequences.firstIndex(
            where: { $0.id == sourceSequenceID }
        ) else {
            throw EditReducerError.sequenceNotFound(sourceSequenceID)
        }
        guard !project.sequences.contains(where: { $0.id == duplicate.id }) else {
            throw EditReducerError.duplicateSequenceID(duplicate.id)
        }

        var sequences = project.sequences
        sequences.insert(duplicate, at: sourceIndex + 1)
        return Project(
            schemaVersion: project.schemaVersion,
            settings: project.settings,
            mediaPool: project.mediaPool,
            sequences: sequences
        )
    }
}

extension EditReducer {
    static func replacingTrack(
        _ trackID: UUID,
        sequenceID: UUID,
        in project: Project,
        transform: (Track) throws -> Track
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            var videoTracks = sequence.videoTracks
            var audioTracks = sequence.audioTracks
            let location = try locateTrack(trackID, in: sequence)
            let track = track(at: location, videoTracks: videoTracks, audioTracks: audioTracks)
            let replacement = try transform(track)
            setTrack(
                replacement,
                at: location,
                videoTracks: &videoTracks,
                audioTracks: &audioTracks
            )
            return copying(sequence, videoTracks: videoTracks, audioTracks: audioTracks)
        }
    }

    static func replacingSequence(
        in project: Project,
        sequenceID: UUID,
        transform: (Sequence) throws -> Sequence
    ) throws -> Project {
        guard let index = project.sequences.firstIndex(where: { $0.id == sequenceID }) else {
            throw EditReducerError.sequenceNotFound(sequenceID)
        }

        var sequences = project.sequences
        sequences[index] = try transform(sequences[index])
        return Project(
            schemaVersion: project.schemaVersion,
            settings: project.settings,
            mediaPool: project.mediaPool,
            sequences: sequences
        )
    }

    static func locateTrack(_ trackID: UUID, in sequence: Sequence) throws -> TrackLocation {
        let videoIndex = sequence.videoTracks.firstIndex { $0.id == trackID }
        let audioIndex = sequence.audioTracks.firstIndex { $0.id == trackID }

        switch (videoIndex, audioIndex) {
        case (.some, .some):
            throw EditReducerError.duplicateTrackID(sequenceID: sequence.id, trackID: trackID)
        case (.some(let index), .none):
            return TrackLocation(collection: .video, index: index)
        case (.none, .some(let index)):
            return TrackLocation(collection: .audio, index: index)
        case (.none, .none):
            throw EditReducerError.trackNotFound(sequenceID: sequence.id, trackID: trackID)
        }
    }

    static func track(
        at location: TrackLocation,
        videoTracks: [Track],
        audioTracks: [Track]
    ) -> Track {
        switch location.collection {
        case .video:
            return videoTracks[location.index]
        case .audio:
            return audioTracks[location.index]
        }
    }

    static func setTrack(
        _ track: Track,
        at location: TrackLocation,
        videoTracks: inout [Track],
        audioTracks: inout [Track]
    ) {
        switch location.collection {
        case .video:
            videoTracks[location.index] = track
        case .audio:
            audioTracks[location.index] = track
        }
    }
}

extension EditReducer {
    static func clipIndex(_ clipID: UUID, in items: [TimelineItem]) -> Int? {
        items.firstIndex { item in
            if case .clip(let clip) = item {
                return clip.id == clipID
            }
            return false
        }
    }

    static func sortedItems(_ items: [TimelineItem]) -> [TimelineItem] {
        items.sorted { left, right in
            if left.timelineRange.start == right.timelineRange.start {
                return sortKey(for: left) < sortKey(for: right)
            }
            return left.timelineRange.start < right.timelineRange.start
        }
    }

    static func sortedMarkers(_ markers: [Marker]) -> [Marker] {
        markers.sorted { left, right in
            if left.time == right.time {
                return left.id.uuidString < right.id.uuidString
            }
            return left.time < right.time
        }
    }

    static func sortKey(for item: TimelineItem) -> String {
        switch item {
        case .clip(let clip):
            return "clip-\(clip.id.uuidString)"
        case .gap(let range):
            return "gap-\(range.start.value)-\(range.duration.value)"
        case .transition(let transition):
            return "transition-\(transition.id.uuidString)"
        }
    }

    static func validated(_ project: Project) throws -> Project {
        switch project.validate() {
        case .valid:
            return project
        case .invalid(let errors):
            throw EditReducerError.validationFailed(errors)
        }
    }

    static func copying(_ track: Track, items: [TimelineItem]) -> Track {
        copying(track, items: items, state: TrackStatePatch())
    }

    static func copying(
        _ track: Track,
        items: [TimelineItem]? = nil,
        state: TrackStatePatch
    ) -> Track {
        Track(
            id: track.id,
            kind: track.kind,
            items: items ?? track.items,
            enabled: state.enabled ?? track.enabled,
            locked: state.locked ?? track.locked,
            muted: state.muted ?? track.muted,
            solo: state.solo ?? track.solo,
            hidden: state.hidden ?? track.hidden
        )
    }

    static func copying(
        _ sequence: Sequence,
        name: String? = nil,
        videoTracks: [Track]? = nil,
        audioTracks: [Track]? = nil,
        markers: [Marker]? = nil
    ) -> Sequence {
        Sequence(
            id: sequence.id,
            name: name ?? sequence.name,
            videoTracks: videoTracks ?? sequence.videoTracks,
            audioTracks: audioTracks ?? sequence.audioTracks,
            markers: markers ?? sequence.markers,
            timebase: sequence.timebase
        )
    }

    static func copying(
        _ clip: Clip,
        source: ClipSource? = nil,
        sourceRange: TimeRange? = nil,
        timelineRange: TimeRange? = nil,
        name: String? = nil,
        linkGroupID: UUID?? = nil,
        transform: ClipTransform? = nil,
        transformAnimation: AnimatableClipTransform? = nil,
        effects: ClipEffects? = nil,
        effectsAnimation: AnimatableClipEffects? = nil
    ) -> Clip {
        let replacementTransform = transform ?? clip.transform
        let replacementAnimation = transformAnimation
            ?? (transform == nil ? clip.transformAnimation : .constant(replacementTransform))
        let replacementEffects = effects ?? clip.effects
        let replacementEffectsAnimation = effectsAnimation
            ?? (effects == nil ? clip.effectsAnimation : .constant(replacementEffects))
        return Clip(
            id: clip.id,
            source: source ?? clip.source,
            sourceRange: sourceRange ?? clip.sourceRange,
            timelineRange: timelineRange ?? clip.timelineRange,
            kind: clip.kind,
            name: name ?? clip.name,
            linkGroupID: linkGroupID ?? clip.linkGroupID,
            transform: replacementTransform,
            transformAnimation: replacementAnimation,
            effects: replacementEffects,
            effectsAnimation: replacementEffectsAnimation
        )
    }
}
