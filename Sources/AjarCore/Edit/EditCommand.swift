// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A deterministic edit operation applied to an immutable `Project`.
public enum EditCommand: Codable, Equatable, Sendable {
    /// Adds a clip to an existing track.
    case addClip(sequenceID: UUID, trackID: UUID, clip: Clip)

    /// Inserts a clip and pushes later items right by the clip duration.
    case insertClip(sequenceID: UUID, trackID: UUID, clip: Clip)

    /// Overwrites the clip's timeline range without rippling later items.
    case overwriteClip(sequenceID: UUID, trackID: UUID, clip: Clip)

    /// Appends a clip after the last item on an existing track.
    case appendClip(sequenceID: UUID, trackID: UUID, clip: Clip)

    /// Removes a clip from an existing track.
    case removeClip(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// Swaps a clip source while keeping its timeline placement.
    case replaceClipSource(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        source: ClipSource,
        sourceRange: TimeRange
    )

    /// Places a source in/out range at a timeline target as an insert or overwrite edit.
    case threePointEdit(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        source: ClipSource,
        sourceRange: TimeRange,
        timelineStart: RationalTime,
        kind: TrackKind,
        name: String,
        mode: ThreePointEditMode
    )

    /// Moves a clip to a new track/range.
    case moveClip(
        sequenceID: UUID,
        sourceTrackID: UUID,
        clipID: UUID,
        destinationTrackID: UUID,
        timelineRange: TimeRange
    )

    /// Updates a clip's source and timeline ranges.
    case trimClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        sourceRange: TimeRange,
        timelineRange: TimeRange
    )

    /// Adds a video or audio track to a sequence.
    case addTrack(sequenceID: UUID, track: Track)

    /// Removes a track from a sequence.
    case removeTrack(sequenceID: UUID, trackID: UUID)

    /// Renames a sequence.
    case renameSequence(sequenceID: UUID, name: String)

    /// Replaces project-wide settings.
    case setProjectSettings(ProjectSettings)
}

/// Typed failures from the edit reducer.
public enum EditReducerError: Error, Equatable, Sendable {
    /// The command references a missing sequence.
    case sequenceNotFound(UUID)

    /// The command references a missing track.
    case trackNotFound(sequenceID: UUID, trackID: UUID)

    /// The command references a missing clip.
    case clipNotFound(sequenceID: UUID, trackID: UUID, clipID: UUID)

    /// The command would create duplicate track IDs inside a sequence.
    case duplicateTrackID(sequenceID: UUID, trackID: UUID)

    /// Exact timeline arithmetic failed while applying the command.
    case timeArithmeticFailed(RationalTimeError)

    /// The command produced a project that failed central validation.
    case validationFailed([ProjectValidationError])
}

/// Pure reducer entry point required by ADR-0008.
public func apply(_ command: EditCommand, to project: Project) throws -> Project {
    try EditReducer.apply(command, to: project)
}

/// Pure project edit reducer.
public enum EditReducer {
    /// Applies `command` to `project`, returning a new validated project.
    public static func apply(_ command: EditCommand, to project: Project) throws -> Project {
        try validated(try applyUnchecked(command, to: project))
    }
}

extension EditReducer {
    static func applyUnchecked(_ command: EditCommand, to project: Project) throws -> Project {
        switch command {
        case .addClip, .insertClip, .overwriteClip, .appendClip,
            .removeClip, .replaceClipSource, .threePointEdit, .moveClip, .trimClip:
            return try applyClipCommand(command, to: project)
        case .addTrack(let sequenceID, let track):
            return try addTrack(track, sequenceID: sequenceID, to: project)
        case .removeTrack(let sequenceID, let trackID):
            return try removeTrack(trackID: trackID, sequenceID: sequenceID, from: project)
        case .renameSequence(let sequenceID, let name):
            return try renameSequence(sequenceID: sequenceID, name: name, in: project)
        case .setProjectSettings(let settings):
            return Project(
                schemaVersion: project.schemaVersion,
                settings: settings,
                mediaPool: project.mediaPool,
                sequences: project.sequences
            )
        }
    }
}

extension EditReducer {
    enum TrackCollection {
        case video
        case audio
    }

    struct TrackLocation {
        let collection: TrackCollection
        let index: Int
    }

    struct MoveClipEdit {
        let clipID: UUID
        let sequenceID: UUID
        let sourceTrackID: UUID
        let destinationTrackID: UUID
        let timelineRange: TimeRange
    }

    struct TrimClipEdit {
        let clipID: UUID
        let sequenceID: UUID
        let trackID: UUID
        let sourceRange: TimeRange
        let timelineRange: TimeRange
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

    static func moveClip(
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

    static func trimClip(
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

    static func renameSequence(
        sequenceID: UUID,
        name: String,
        in project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            copying(sequence, name: name)
        }
    }

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
        Track(
            id: track.id,
            kind: track.kind,
            items: items,
            enabled: track.enabled,
            locked: track.locked,
            muted: track.muted,
            solo: track.solo,
            hidden: track.hidden
        )
    }

    static func copying(
        _ sequence: Sequence,
        name: String? = nil,
        videoTracks: [Track]? = nil,
        audioTracks: [Track]? = nil
    ) -> Sequence {
        Sequence(
            id: sequence.id,
            name: name ?? sequence.name,
            videoTracks: videoTracks ?? sequence.videoTracks,
            audioTracks: audioTracks ?? sequence.audioTracks,
            markers: sequence.markers,
            timebase: sequence.timebase
        )
    }

    static func copying(
        _ clip: Clip,
        source: ClipSource? = nil,
        sourceRange: TimeRange? = nil,
        timelineRange: TimeRange? = nil,
        name: String? = nil
    ) -> Clip {
        Clip(
            id: clip.id,
            source: source ?? clip.source,
            sourceRange: sourceRange ?? clip.sourceRange,
            timelineRange: timelineRange ?? clip.timelineRange,
            kind: clip.kind,
            name: name ?? clip.name
        )
    }
}
