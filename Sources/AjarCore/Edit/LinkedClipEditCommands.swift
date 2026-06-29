// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct LinkedRangeDelta {
        let sourceStart: RationalTime
        let timelineStart: RationalTime
        let duration: RationalTime
    }

    static func moveClip(
        _ edit: MoveClipEdit,
        in project: Project
    ) throws -> Project {
        guard edit.linkedClipEditMode == .linked else {
            return try moveClipWithoutLinkedPartners(edit, in: project)
        }

        let sequence = try sequence(edit.sequenceID, in: project)
        let sourceLocation = try locateClip(
            ClipReference(trackID: edit.sourceTrackID, clipID: edit.clipID),
            in: sequence
        )
        let timelineStartDelta = try subtractTimes(
            edit.timelineRange.start,
            sourceLocation.clip.timelineRange.start
        )
        var editedProject = try moveClipWithoutLinkedPartners(edit, in: project)

        for linkedClip in linkedPartnerLocations(for: sourceLocation, in: sequence) {
            editedProject = try moveClipWithoutLinkedPartners(
                MoveClipEdit(
                    clipID: linkedClip.clip.id,
                    sequenceID: edit.sequenceID,
                    sourceTrackID: linkedClip.reference.trackID,
                    destinationTrackID: linkedClip.reference.trackID,
                    timelineRange: try offsetRange(
                        linkedClip.clip.timelineRange,
                        by: timelineStartDelta
                    ),
                    linkedClipEditMode: .unlinked
                ),
                in: editedProject
            )
        }

        return editedProject
    }

    static func trimClip(
        _ edit: TrimClipEdit,
        in project: Project
    ) throws -> Project {
        guard edit.linkedClipEditMode == .linked else {
            return try trimClipWithoutLinkedPartners(edit, in: project)
        }

        let sequence = try sequence(edit.sequenceID, in: project)
        let sourceLocation = try locateClip(
            ClipReference(trackID: edit.trackID, clipID: edit.clipID),
            in: sequence
        )
        let delta = try linkedRangeDelta(
            clip: sourceLocation.clip,
            sourceRange: edit.sourceRange,
            timelineRange: edit.timelineRange
        )
        var editedProject = try trimClipWithoutLinkedPartners(edit, in: project)

        for linkedClip in linkedPartnerLocations(for: sourceLocation, in: sequence) {
            let ranges = try shiftedLinkedRanges(clip: linkedClip.clip, delta: delta)
            editedProject = try trimClipWithoutLinkedPartners(
                TrimClipEdit(
                    clipID: linkedClip.clip.id,
                    sequenceID: edit.sequenceID,
                    trackID: linkedClip.reference.trackID,
                    sourceRange: ranges.sourceRange,
                    timelineRange: ranges.timelineRange,
                    linkedClipEditMode: .unlinked
                ),
                in: editedProject
            )
        }

        return editedProject
    }

    static func rippleTrimClip(
        _ edit: RippleTrimClipEdit,
        in project: Project
    ) throws -> Project {
        guard edit.linkedClipEditMode == .linked else {
            return try rippleTrimClipWithoutLinkedPartners(edit, in: project)
        }

        let sequence = try sequence(edit.sequenceID, in: project)
        let sourceLocation = try locateClip(
            ClipReference(trackID: edit.trackID, clipID: edit.clipID),
            in: sequence
        )
        let delta = try linkedRangeDelta(
            clip: sourceLocation.clip,
            sourceRange: edit.sourceRange,
            timelineRange: edit.timelineRange
        )
        var editedProject = try rippleTrimClipWithoutLinkedPartners(edit, in: project)

        for linkedClip in linkedPartnerLocations(for: sourceLocation, in: sequence) {
            let ranges = try shiftedLinkedRanges(clip: linkedClip.clip, delta: delta)
            editedProject = try rippleTrimClipWithoutLinkedPartners(
                RippleTrimClipEdit(
                    sequenceID: edit.sequenceID,
                    trackID: linkedClip.reference.trackID,
                    clipID: linkedClip.clip.id,
                    sourceRange: ranges.sourceRange,
                    timelineRange: ranges.timelineRange,
                    linkedClipEditMode: .unlinked
                ),
                in: editedProject
            )
        }

        return editedProject
    }

    static func slipClip(_ edit: SlipClipEdit, in project: Project) throws -> Project {
        guard edit.linkedClipEditMode == .linked else {
            return try slipClipWithoutLinkedPartners(edit, in: project)
        }

        let sequence = try sequence(edit.sequenceID, in: project)
        let sourceLocation = try locateClip(
            ClipReference(trackID: edit.trackID, clipID: edit.clipID),
            in: sequence
        )
        let sourceStartDelta = try subtractTimes(
            edit.sourceRange.start,
            sourceLocation.clip.sourceRange.start
        )
        let durationDelta = try subtractTimes(
            edit.sourceRange.duration,
            sourceLocation.clip.sourceRange.duration
        )
        var editedProject = try slipClipWithoutLinkedPartners(edit, in: project)

        for linkedClip in linkedPartnerLocations(for: sourceLocation, in: sequence) {
            let sourceStart = try addTimes(linkedClip.clip.sourceRange.start, sourceStartDelta)
            let sourceDuration = try addTimes(linkedClip.clip.sourceRange.duration, durationDelta)
            editedProject = try slipClipWithoutLinkedPartners(
                SlipClipEdit(
                    sequenceID: edit.sequenceID,
                    trackID: linkedClip.reference.trackID,
                    clipID: linkedClip.clip.id,
                    sourceRange: try makeRange(start: sourceStart, duration: sourceDuration),
                    linkedClipEditMode: .unlinked
                ),
                in: editedProject
            )
        }

        return editedProject
    }

    static func slideClip(_ edit: SlideClipEdit, in project: Project) throws -> Project {
        guard edit.linkedClipEditMode == .linked else {
            return try slideClipWithoutLinkedPartners(edit, in: project)
        }

        let sequence = try sequence(edit.sequenceID, in: project)
        let sourceLocation = try locateClip(
            ClipReference(trackID: edit.trackID, clipID: edit.clipID),
            in: sequence
        )
        let timelineStartDelta = try subtractTimes(
            edit.timelineRange.start,
            sourceLocation.clip.timelineRange.start
        )
        let durationDelta = try subtractTimes(
            edit.timelineRange.duration,
            sourceLocation.clip.timelineRange.duration
        )
        var editedProject = try slideClipWithoutLinkedPartners(edit, in: project)

        for linkedClip in linkedPartnerLocations(for: sourceLocation, in: sequence) {
            let timelineStart = try addTimes(
                linkedClip.clip.timelineRange.start,
                timelineStartDelta
            )
            let timelineDuration = try addTimes(
                linkedClip.clip.timelineRange.duration,
                durationDelta
            )
            editedProject = try slideClipWithoutLinkedPartners(
                SlideClipEdit(
                    sequenceID: edit.sequenceID,
                    trackID: linkedClip.reference.trackID,
                    clipID: linkedClip.clip.id,
                    timelineRange: try makeRange(
                        start: timelineStart,
                        duration: timelineDuration
                    ),
                    linkedClipEditMode: .unlinked
                ),
                in: editedProject
            )
        }

        return editedProject
    }

    static func linkClips(
        sequenceID: UUID,
        linkGroupID: UUID,
        clips: [ClipReference],
        in project: Project
    ) throws -> Project {
        guard clips.count >= 2 else {
            throw EditReducerError.invalidEdit(
                .linkRequiresAtLeastTwoClips(linkGroupID: linkGroupID)
            )
        }
        if let duplicate = duplicateReference(in: clips) {
            throw EditReducerError.invalidEdit(
                .duplicateClipLinkReference(
                    trackID: duplicate.trackID,
                    clipID: duplicate.clipID
                )
            )
        }

        let sequence = try sequence(sequenceID, in: project)
        let locations = try clips.map { try locateClip($0, in: sequence) }
        let hasVideo = locations.contains { $0.clip.kind == .video }
        let hasAudio = locations.contains { $0.clip.kind == .audio }
        guard hasVideo, hasAudio else {
            throw EditReducerError.invalidEdit(
                .linkRequiresVideoAndAudio(linkGroupID: linkGroupID)
            )
        }

        for location in locations {
            if let existingLinkGroupID = location.clip.linkGroupID,
                existingLinkGroupID != linkGroupID {
                throw EditReducerError.invalidEdit(
                    .clipAlreadyLinked(
                        clipID: location.clip.id,
                        linkGroupID: existingLinkGroupID
                    )
                )
            }
        }

        return try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            var videoTracks = sequence.videoTracks
            var audioTracks = sequence.audioTracks
            for location in locations {
                setClip(
                    copying(location.clip, linkGroupID: .some(.some(linkGroupID))),
                    at: location,
                    videoTracks: &videoTracks,
                    audioTracks: &audioTracks
                )
            }
            return copying(sequence, videoTracks: videoTracks, audioTracks: audioTracks)
        }
    }

    static func unlinkClips(
        sequenceID: UUID,
        linkGroupID: UUID,
        in project: Project
    ) throws -> Project {
        let sequence = try sequence(sequenceID, in: project)
        let locations = clipLocations(in: sequence, linkGroupID: linkGroupID)
        guard !locations.isEmpty else {
            throw EditReducerError.linkGroupNotFound(
                sequenceID: sequenceID,
                linkGroupID: linkGroupID
            )
        }

        return try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            var videoTracks = sequence.videoTracks
            var audioTracks = sequence.audioTracks
            for location in locations {
                setClip(
                    copying(location.clip, linkGroupID: .some(nil)),
                    at: location,
                    videoTracks: &videoTracks,
                    audioTracks: &audioTracks
                )
            }
            return copying(sequence, videoTracks: videoTracks, audioTracks: audioTracks)
        }
    }

    private static func duplicateReference(in clips: [ClipReference]) -> ClipReference? {
        var seen: Set<ClipReference> = []
        for clip in clips {
            if seen.contains(clip) {
                return clip
            }
            seen.insert(clip)
        }
        return nil
    }

    static func linkedRangeDelta(
        clip: Clip,
        sourceRange: TimeRange,
        timelineRange: TimeRange
    ) throws -> LinkedRangeDelta {
        LinkedRangeDelta(
            sourceStart: try subtractTimes(sourceRange.start, clip.sourceRange.start),
            timelineStart: try subtractTimes(timelineRange.start, clip.timelineRange.start),
            duration: try subtractTimes(timelineRange.duration, clip.timelineRange.duration)
        )
    }

    static func shiftedLinkedRanges(
        clip: Clip,
        delta: LinkedRangeDelta
    ) throws -> (sourceRange: TimeRange, timelineRange: TimeRange) {
        let sourceStart = try addTimes(clip.sourceRange.start, delta.sourceStart)
        let timelineStart = try addTimes(clip.timelineRange.start, delta.timelineStart)
        let timelineDuration = try addTimes(clip.timelineRange.duration, delta.duration)
        let sourceDuration = try speedSourceDuration(
            clipID: clip.id,
            timelineDuration: timelineDuration,
            speed: clip.speed
        )
        return (
            sourceRange: try makeRange(start: sourceStart, duration: sourceDuration),
            timelineRange: try makeRange(start: timelineStart, duration: timelineDuration)
        )
    }

    static func sequence(_ sequenceID: UUID, in project: Project) throws -> Sequence {
        guard let sequence = project.sequences.first(where: { $0.id == sequenceID }) else {
            throw EditReducerError.sequenceNotFound(sequenceID)
        }
        return sequence
    }

    static func locateClip(
        _ reference: ClipReference,
        in sequence: Sequence
    ) throws -> ClipLocation {
        let trackLocation = try locateTrack(reference.trackID, in: sequence)
        let foundTrack = track(
            at: trackLocation,
            videoTracks: sequence.videoTracks,
            audioTracks: sequence.audioTracks
        )
        guard
            let itemIndex = clipIndex(reference.clipID, in: foundTrack.items),
            case .clip(let clip) = foundTrack.items[itemIndex]
        else {
            throw EditReducerError.clipNotFound(
                sequenceID: sequence.id,
                trackID: reference.trackID,
                clipID: reference.clipID
            )
        }

        return ClipLocation(
            reference: reference,
            trackLocation: trackLocation,
            itemIndex: itemIndex,
            clip: clip
        )
    }

    static func clipLocations(in sequence: Sequence, linkGroupID: UUID) -> [ClipLocation] {
        var locations: [ClipLocation] = []
        for (trackIndex, track) in sequence.videoTracks.enumerated() {
            let trackLocation = TrackLocation(collection: .video, index: trackIndex)
            locations.append(
                contentsOf: clipLocations(
                    in: track,
                    trackLocation: trackLocation,
                    linkGroupID: linkGroupID
                )
            )
        }
        for (trackIndex, track) in sequence.audioTracks.enumerated() {
            let trackLocation = TrackLocation(collection: .audio, index: trackIndex)
            locations.append(
                contentsOf: clipLocations(
                    in: track,
                    trackLocation: trackLocation,
                    linkGroupID: linkGroupID
                )
            )
        }
        return locations
    }

    static func clipLocations(
        in track: Track,
        trackLocation: TrackLocation,
        linkGroupID: UUID
    ) -> [ClipLocation] {
        track.items.indices.compactMap { itemIndex in
            guard case .clip(let clip) = track.items[itemIndex],
                clip.linkGroupID == linkGroupID
            else {
                return nil
            }
            return ClipLocation(
                reference: ClipReference(trackID: track.id, clipID: clip.id),
                trackLocation: trackLocation,
                itemIndex: itemIndex,
                clip: clip
            )
        }
    }

    static func linkedPartnerLocations(
        for location: ClipLocation,
        in sequence: Sequence
    ) -> [ClipLocation] {
        guard let linkGroupID = location.clip.linkGroupID else {
            return []
        }

        return clipLocations(in: sequence, linkGroupID: linkGroupID)
            .filter { $0.reference != location.reference }
    }

    static func setClip(
        _ clip: Clip,
        at location: ClipLocation,
        videoTracks: inout [Track],
        audioTracks: inout [Track]
    ) {
        let foundTrack = track(
            at: location.trackLocation,
            videoTracks: videoTracks,
            audioTracks: audioTracks
        )
        var items = foundTrack.items
        items[location.itemIndex] = .clip(clip)
        setTrack(
            copying(foundTrack, items: sortedItems(items)),
            at: location.trackLocation,
            videoTracks: &videoTracks,
            audioTracks: &audioTracks
        )
    }
}
