// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct InsertCompoundClipEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let targetSequenceID: UUID
        let timelineStart: RationalTime
        let kind: TrackKind
        let name: String
    }

    struct MakeCompoundClipEdit {
        let sequenceID: UUID
        let compoundSequenceID: UUID
        let compoundClipID: UUID
        let selectedClips: [ClipReference]
        let name: String
    }

    struct CompoundSelectionItem {
        let reference: ClipReference
        let trackLocation: TrackLocation
        let track: Track
        let clip: Clip
    }

    struct CompoundSelectionExtent {
        let start: RationalTime
        let duration: RationalTime

        var range: TimeRange {
            get throws {
                try makeRange(start: start, duration: duration)
            }
        }
    }

    struct CompoundNestedSequenceSpec {
        let id: UUID
        let name: String
        let sourceSequence: Sequence
        let selectedReferences: Set<ClipReference>
        let selectionStart: RationalTime
        let markers: [Marker]
        let audioDucking: [AudioDuckingRule]
    }

    struct CompoundReplacementSpec {
        let selectedReferences: Set<ClipReference>
        let destinationTrackID: UUID
        let compoundClip: Clip
        let markers: [Marker]
        let audioDucking: [AudioDuckingRule]
    }

    static func applyCompoundClipCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .insertCompoundClip(
            let sequenceID,
            let trackID,
            let clipID,
            let targetSequenceID,
            let timelineStart,
            let kind,
            let name
        ):
            return try insertCompoundClip(
                InsertCompoundClipEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    targetSequenceID: targetSequenceID,
                    timelineStart: timelineStart,
                    kind: kind,
                    name: name
                ),
                in: project
            )
        case .makeCompoundClip(
            let sequenceID,
            let compoundSequenceID,
            let compoundClipID,
            let selectedClips,
            let name
        ):
            return try makeCompoundClip(
                MakeCompoundClipEdit(
                    sequenceID: sequenceID,
                    compoundSequenceID: compoundSequenceID,
                    compoundClipID: compoundClipID,
                    selectedClips: selectedClips,
                    name: name
                ),
                in: project
            )
        case .decomposeCompoundClip(let sequenceID, let trackID, let clipID):
            return try decomposeCompoundClip(
                DecomposeCompoundClipEdit(
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

    static func insertCompoundClip(
        _ edit: InsertCompoundClipEdit,
        in project: Project
    ) throws -> Project {
        guard
            let targetSequence = project.sequences.first(
                where: { $0.id == edit.targetSequenceID }
            )
        else {
            throw EditReducerError.sequenceNotFound(edit.targetSequenceID)
        }

        let duration = try durationForCompoundInsert(targetSequence, clipID: edit.clipID)
        let clip = Clip(
            id: edit.clipID,
            source: .sequence(id: edit.targetSequenceID),
            sourceRange: try makeRange(start: .zero, duration: duration),
            timelineRange: try makeRange(start: edit.timelineStart, duration: duration),
            kind: edit.kind,
            name: edit.name
        )

        return try insertClip(
            clip,
            sequenceID: edit.sequenceID,
            trackID: edit.trackID,
            in: project
        )
    }

    private static func durationForCompoundInsert(
        _ targetSequence: Sequence,
        clipID: UUID
    ) throws -> RationalTime {
        let duration: RationalTime
        do {
            duration = try targetSequence.timelineDuration()
        } catch let error as ClipSourceResolutionError {
            switch error {
            case .timeArithmeticFailed(let timeError):
                throw EditReducerError.timeArithmeticFailed(timeError)
            case .missingMediaReference, .missingSequenceReference:
                throw EditReducerError.validationFailed([])
            }
        }

        guard duration > .zero else {
            throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: clipID))
        }
        return duration
    }

    static func makeCompoundClip(
        _ edit: MakeCompoundClipEdit,
        in project: Project
    ) throws -> Project {
        guard !project.sequences.contains(where: { $0.id == edit.compoundSequenceID }) else {
            throw EditReducerError.duplicateSequenceID(edit.compoundSequenceID)
        }
        guard
            let sequenceIndex = project.sequences.firstIndex(
                where: { $0.id == edit.sequenceID }
            )
        else {
            throw EditReducerError.sequenceNotFound(edit.sequenceID)
        }

        let sourceSequence = project.sequences[sequenceIndex]
        let selection = try compoundSelectionItems(for: edit, in: sourceSequence)
        let extent = try compoundSelectionExtent(selection, sequenceID: edit.sequenceID)
        let selectedReferences = Set(selection.map(\.reference))
        let destinationTrackID = try compoundDestinationTrackID(
            in: sourceSequence,
            selection: selection,
            selectedReferences: selectedReferences,
            extent: try extent.range
        )
        let markerSplit = try splitCompoundSelectionMarkers(
            in: sourceSequence,
            selectedReferences: selectedReferences,
            selectionStart: extent.start
        )
        let duckingSplit = try splitCompoundSelectionAudioDucking(
            in: sourceSequence,
            selectedReferences: selectedReferences
        )

        let nestedSequence = try compoundNestedSequence(
            CompoundNestedSequenceSpec(
                id: edit.compoundSequenceID,
                name: edit.name,
                sourceSequence: sourceSequence,
                selectedReferences: selectedReferences,
                selectionStart: extent.start,
                markers: markerSplit.nested,
                audioDucking: duckingSplit.nested
            )
        )
        let replacementSequence = try sourceSequenceReplacingCompoundSelection(
            sourceSequence,
            spec: CompoundReplacementSpec(
                selectedReferences: selectedReferences,
                destinationTrackID: destinationTrackID,
                compoundClip: try compoundReplacementClip(edit: edit, extent: extent),
                markers: markerSplit.outer,
                audioDucking: duckingSplit.outer
            )
        )

        var sequences = project.sequences
        sequences[sequenceIndex] = replacementSequence
        sequences.append(nestedSequence)
        return Project(
            schemaVersion: project.schemaVersion,
            settings: project.settings,
            mediaPool: project.mediaPool,
            sequences: sequences,
            looks: project.looks
        )
    }

    private static func compoundReplacementClip(
        edit: MakeCompoundClipEdit,
        extent: CompoundSelectionExtent
    ) throws -> Clip {
        Clip(
            id: edit.compoundClipID,
            source: .sequence(id: edit.compoundSequenceID),
            sourceRange: try makeRange(start: .zero, duration: extent.duration),
            timelineRange: try extent.range,
            kind: .video,
            name: edit.name
        )
    }

    private static func compoundSelectionItems(
        for edit: MakeCompoundClipEdit,
        in sequence: Sequence
    ) throws -> [CompoundSelectionItem] {
        guard !edit.selectedClips.isEmpty else {
            throw EditReducerError.invalidEdit(
                .compoundSelectionEmpty(sequenceID: edit.sequenceID)
            )
        }

        var seenReferences = Set<ClipReference>()
        var selection: [CompoundSelectionItem] = []
        for reference in edit.selectedClips {
            guard seenReferences.insert(reference).inserted else {
                throw EditReducerError.invalidEdit(
                    .duplicateCompoundSelectionReference(
                        trackID: reference.trackID,
                        clipID: reference.clipID
                    )
                )
            }

            let trackLocation = try locateTrack(reference.trackID, in: sequence)
            let selectedTrack = track(
                at: trackLocation,
                videoTracks: sequence.videoTracks,
                audioTracks: sequence.audioTracks
            )
            guard
                let itemIndex = clipIndex(reference.clipID, in: selectedTrack.items),
                case .clip(let clip) = selectedTrack.items[itemIndex]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: edit.sequenceID,
                    trackID: reference.trackID,
                    clipID: reference.clipID
                )
            }

            selection.append(
                CompoundSelectionItem(
                    reference: reference,
                    trackLocation: trackLocation,
                    track: selectedTrack,
                    clip: clip
                )
            )
        }
        return selection
    }

    private static func compoundSelectionExtent(
        _ selection: [CompoundSelectionItem],
        sequenceID: UUID
    ) throws -> CompoundSelectionExtent {
        var selectionStart: RationalTime?
        var selectionEnd: RationalTime?

        for item in selection {
            let range = item.clip.timelineRange
            selectionStart = min(selectionStart ?? range.start, range.start)
            let rangeEnd = try exactTime { try range.end() }
            selectionEnd = max(selectionEnd ?? rangeEnd, rangeEnd)
        }

        guard let start = selectionStart, let end = selectionEnd else {
            throw EditReducerError.invalidEdit(.compoundSelectionEmpty(sequenceID: sequenceID))
        }

        let duration = try exactTime { try end.subtracting(start) }
        guard duration > .zero else {
            throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: selection[0].clip.id))
        }
        return CompoundSelectionExtent(start: start, duration: duration)
    }

    private static func compoundDestinationTrackID(
        in sequence: Sequence,
        selection: [CompoundSelectionItem],
        selectedReferences: Set<ClipReference>,
        extent: TimeRange
    ) throws -> UUID {
        let videoSelections = selection.filter { $0.clip.kind == .video }
        guard !videoSelections.isEmpty else {
            throw EditReducerError.invalidEdit(
                .compoundSelectionRequiresVideo(sequenceID: sequence.id)
            )
        }

        for candidate in videoSelections.sorted(by: { left, right in
            left.trackLocation.index < right.trackLocation.index
        }) {
            let remainingItems = itemsAfterRemovingSelection(
                from: candidate.track,
                trackID: candidate.reference.trackID,
                selectedReferences: selectedReferences
            )
            if try !items(remainingItems, overlap: extent) {
                return candidate.reference.trackID
            }
        }

        throw EditReducerError.invalidEdit(
            .compoundSelectionNeedsDestinationTrack(sequenceID: sequence.id)
        )
    }

    private static func compoundNestedSequence(
        _ spec: CompoundNestedSequenceSpec
    ) throws -> Sequence {
        let videoTracks = try spec.sourceSequence.videoTracks.compactMap { track in
            try compoundNestedTrack(
                from: track,
                selectedReferences: spec.selectedReferences,
                selectionStart: spec.selectionStart
            )
        }
        let audioTracks = try spec.sourceSequence.audioTracks.compactMap { track in
            try compoundNestedTrack(
                from: track,
                selectedReferences: spec.selectedReferences,
                selectionStart: spec.selectionStart
            )
        }

        return Sequence(
            id: spec.id,
            name: spec.name,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            markers: sortedMarkers(spec.markers),
            audioDucking: spec.audioDucking,
            timebase: spec.sourceSequence.timebase
        )
    }

    private static func compoundNestedTrack(
        from track: Track,
        selectedReferences: Set<ClipReference>,
        selectionStart: RationalTime
    ) throws -> Track? {
        var selectedItems: [TimelineItem] = []
        for item in track.items {
            guard case .clip(let clip) = item else {
                continue
            }
            let reference = ClipReference(trackID: track.id, clipID: clip.id)
            guard selectedReferences.contains(reference) else {
                continue
            }
            selectedItems.append(
                .clip(
                    copying(
                        clip,
                        timelineRange: try makeRange(
                            start: try exactTime {
                                try clip.timelineRange.start.subtracting(selectionStart)
                            },
                            duration: clip.timelineRange.duration
                        )
                    )
                )
            )
        }

        guard !selectedItems.isEmpty else {
            return nil
        }
        return copying(track, items: sortedItems(selectedItems))
    }

    private static func sourceSequenceReplacingCompoundSelection(
        _ sourceSequence: Sequence,
        spec: CompoundReplacementSpec
    ) throws -> Sequence {
        let videoTracks = try sourceSequence.videoTracks.map { track in
            try sourceTrackReplacingCompoundSelection(
                track,
                selectedReferences: spec.selectedReferences,
                destinationTrackID: spec.destinationTrackID,
                compoundClip: spec.compoundClip
            )
        }
        let audioTracks = sourceSequence.audioTracks.map { track in
            copying(
                track,
                items: itemsAfterRemovingSelection(
                    from: track,
                    trackID: track.id,
                    selectedReferences: spec.selectedReferences
                )
            )
        }

        return Sequence(
            id: sourceSequence.id,
            name: sourceSequence.name,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            markers: sortedMarkers(spec.markers),
            audioDucking: spec.audioDucking,
            timebase: sourceSequence.timebase
        )
    }

    private static func sourceTrackReplacingCompoundSelection(
        _ track: Track,
        selectedReferences: Set<ClipReference>,
        destinationTrackID: UUID,
        compoundClip: Clip
    ) throws -> Track {
        var items = itemsAfterRemovingSelection(
            from: track,
            trackID: track.id,
            selectedReferences: selectedReferences
        )
        if track.id == destinationTrackID {
            items.append(.clip(compoundClip))
        }
        return copying(track, items: sortedItems(items))
    }

    private static func itemsAfterRemovingSelection(
        from track: Track,
        trackID: UUID,
        selectedReferences: Set<ClipReference>
    ) -> [TimelineItem] {
        track.items.filter { item in
            guard case .clip(let clip) = item else {
                return true
            }
            return !selectedReferences.contains(
                ClipReference(trackID: trackID, clipID: clip.id)
            )
        }
    }

    static func items(_ items: [TimelineItem], overlap range: TimeRange) throws -> Bool {
        try items.contains { try rangesIntersect($0.timelineRange, range) }
    }
}
