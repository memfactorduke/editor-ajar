// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Result of validating a project model.
public enum ProjectValidationResult: Equatable, Sendable {
    /// The project satisfies the currently modelled invariants.
    case valid

    /// The project has one or more typed validation errors.
    case invalid([ProjectValidationError])

    /// Whether the validation result is valid.
    public var isValid: Bool {
        self == .valid
    }
}

/// Typed project validation error.
public enum ProjectValidationError: Equatable, Sendable {
    /// Two sequences use the same stable ID.
    case duplicateSequenceID(UUID)

    /// A track is stored in the wrong sequence track collection.
    case trackKindMismatch(sequenceID: UUID, trackID: UUID, expected: TrackKind, actual: TrackKind)

    /// A timeline item kind does not match its containing track.
    case itemKindMismatch(sequenceID: UUID, trackID: UUID, itemIndex: Int, itemKind: TrackKind)

    /// Track opacity is outside the normalized 0...1 range.
    case invalidTrackOpacity(sequenceID: UUID, trackID: UUID, value: RationalValue)

    /// A track opacity keyframe is outside the normalized 0...1 range.
    case invalidTrackOpacityKeyframe(
        sequenceID: UUID,
        trackID: UUID,
        time: RationalTime,
        value: RationalValue
    )

    /// Track audio gain or pan is outside the supported range.
    case invalidTrackAudioMix(sequenceID: UUID, trackID: UUID, error: AudioMixValidationError)

    /// Timeline items are not sorted by start time.
    case itemsNotSorted(sequenceID: UUID, trackID: UUID, previousIndex: Int, itemIndex: Int)

    /// Timeline items overlap.
    case itemsOverlap(sequenceID: UUID, trackID: UUID, previousIndex: Int, itemIndex: Int)

    /// Computing a time range failed.
    case invalidTimeRange(sequenceID: UUID, trackID: UUID, itemIndex: Int, error: RationalTimeError)

    /// A clip refers to a missing media reference.
    case missingMediaReference(sequenceID: UUID, trackID: UUID, clipID: UUID, mediaID: UUID)

    /// A clip refers to a missing sequence.
    case missingSequenceReference(sequenceID: UUID, trackID: UUID, clipID: UUID, targetID: UUID)

    /// Two markers in a sequence use the same stable ID.
    case duplicateMarkerID(sequenceID: UUID, markerID: UUID)

    /// Markers are not sorted by timeline time.
    case markersNotSorted(sequenceID: UUID, previousIndex: Int, markerIndex: Int)

    /// A clip-anchored marker refers to a missing track or clip.
    case missingMarkerClipReference(
        sequenceID: UUID,
        markerID: UUID,
        trackID: UUID,
        clipID: UUID
    )

    /// A clip transform is outside the valid project-frame range.
    case invalidClipTransform(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: ClipTransformValidationError
    )

    /// A transform keyframe time is outside its clip timeline range.
    case transformKeyframeTimeOutsideClip(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        parameter: ClipTransformParameter,
        time: RationalTime,
        clipRange: TimeRange
    )

    /// A transform keyframe value is outside the valid project-frame range.
    case invalidClipTransformKeyframe(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        parameter: ClipTransformParameter,
        time: RationalTime,
        error: ClipTransformValidationError
    )

    /// A clip effect is outside the valid normalized range.
    case invalidClipEffects(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: ClipEffectsValidationError
    )

    /// A clip audio mix is outside the supported range.
    case invalidClipAudioMix(
        sequenceID: UUID, trackID: UUID, clipID: UUID, error: AudioMixValidationError
    )

    /// A sequence ducking rule is outside the supported range or references invalid tracks.
    case invalidAudioDucking(sequenceID: UUID, ruleIndex: Int, error: AudioDuckingValidationError)
}

enum ProjectValidator {
    struct ValidationState {
        let mediaIDs: Set<UUID>
        let sequenceIDs: Set<UUID>
        let frame: PixelDimensions
        var errors: [ProjectValidationError] = []
    }

    struct TrackContext {
        let sequenceID: UUID
        let trackID: UUID
        let trackKind: TrackKind
    }

    private struct TrackItemState {
        var previousRange: TimeRange?
        var previousIndex: Int?
    }

    static func validate(project: Project) -> ProjectValidationResult {
        var state = ValidationState(
            mediaIDs: Set(project.mediaPool.map(\.id)),
            sequenceIDs: Set(project.sequences.map(\.id)),
            frame: project.settings.resolution
        )

        var seenSequenceIDs = Set<UUID>()

        for sequence in project.sequences {
            if seenSequenceIDs.contains(sequence.id) {
                state.errors.append(.duplicateSequenceID(sequence.id))
            } else {
                seenSequenceIDs.insert(sequence.id)
            }

            validateTracks(
                sequence.videoTracks,
                expectedKind: .video,
                sequenceID: sequence.id,
                state: &state
            )
            validateTracks(
                sequence.audioTracks,
                expectedKind: .audio,
                sequenceID: sequence.id,
                state: &state
            )
            validateMarkers(in: sequence, state: &state)
            validateAudioDucking(in: sequence, state: &state)
        }

        if state.errors.isEmpty {
            return .valid
        }
        return .invalid(state.errors)
    }

    private static func validateTracks(
        _ tracks: [Track],
        expectedKind: TrackKind,
        sequenceID: UUID,
        state: inout ValidationState
    ) {
        for track in tracks {
            let context = TrackContext(
                sequenceID: sequenceID,
                trackID: track.id,
                trackKind: track.kind
            )

            if track.kind != expectedKind {
                state.errors.append(
                    .trackKindMismatch(
                        sequenceID: sequenceID,
                        trackID: track.id,
                        expected: expectedKind,
                        actual: track.kind
                    )
                )
            }

            validateTrackCompositing(track, context: context, state: &state)
            validateTrackAudioMix(track, context: context, state: &state)
            validateTrackItems(
                track.items,
                context: context,
                state: &state
            )
        }
    }

    private static func validateTrackItems(
        _ items: [TimelineItem],
        context: TrackContext,
        state: inout ValidationState
    ) {
        var itemState = TrackItemState()

        for itemIndex in items.indices {
            let item = items[itemIndex]
            validateItemKind(
                item,
                itemIndex: itemIndex,
                context: context,
                state: &state
            )
            validateClipSource(item, context: context, state: &state)
            validateClipTransform(item, context: context, state: &state)
            validateClipEffects(item, context: context, state: &state)
            validateClipAudioMix(item, context: context, state: &state)
            validateItemOrder(
                item,
                itemIndex: itemIndex,
                itemState: &itemState,
                context: context,
                state: &state
            )
        }
    }

    private static func validateMarkers(
        in sequence: Sequence,
        state: inout ValidationState
    ) {
        var seenIDs = Set<UUID>()
        var previousMarker: Marker?
        var previousIndex: Int?

        for markerIndex in sequence.markers.indices {
            let marker = sequence.markers[markerIndex]
            if seenIDs.contains(marker.id) {
                state.errors.append(
                    .duplicateMarkerID(sequenceID: sequence.id, markerID: marker.id)
                )
            } else {
                seenIDs.insert(marker.id)
            }

            if let previousMarker, let previousIndex {
                if markerSortPrecedes(marker, previousMarker) {
                    state.errors.append(
                        .markersNotSorted(
                            sequenceID: sequence.id,
                            previousIndex: previousIndex,
                            markerIndex: markerIndex
                        )
                    )
                }
            }

            validateMarkerAnchor(marker, in: sequence, state: &state)
            previousMarker = marker
            previousIndex = markerIndex
        }
    }

    private static func validateMarkerAnchor(
        _ marker: Marker,
        in sequence: Sequence,
        state: inout ValidationState
    ) {
        guard case .clip(let trackID, let clipID) = marker.anchor else {
            return
        }

        if !clipExists(trackID: trackID, clipID: clipID, in: sequence) {
            state.errors.append(
                .missingMarkerClipReference(
                    sequenceID: sequence.id,
                    markerID: marker.id,
                    trackID: trackID,
                    clipID: clipID
                )
            )
        }
    }

    private static func markerSortPrecedes(_ marker: Marker, _ previousMarker: Marker) -> Bool {
        if marker.time == previousMarker.time {
            return marker.id.uuidString < previousMarker.id.uuidString
        }
        return marker.time < previousMarker.time
    }

    private static func clipExists(trackID: UUID, clipID: UUID, in sequence: Sequence) -> Bool {
        for track in sequence.videoTracks + sequence.audioTracks where track.id == trackID {
            for item in track.items {
                if case .clip(let clip) = item, clip.id == clipID {
                    return true
                }
            }
        }
        return false
    }

    private static func validateItemKind(
        _ item: TimelineItem,
        itemIndex: Int,
        context: TrackContext,
        state: inout ValidationState
    ) {
        guard let itemKind = item.kind, itemKind != context.trackKind else {
            return
        }

        state.errors.append(
            .itemKindMismatch(
                sequenceID: context.sequenceID,
                trackID: context.trackID,
                itemIndex: itemIndex,
                itemKind: itemKind
            )
        )
    }

    private static func validateClipSource(
        _ item: TimelineItem,
        context: TrackContext,
        state: inout ValidationState
    ) {
        guard case .clip(let clip) = item else {
            return
        }

        switch clip.source {
        case .media(let mediaID):
            if !state.mediaIDs.contains(mediaID) {
                state.errors.append(
                    .missingMediaReference(
                        sequenceID: context.sequenceID,
                        trackID: context.trackID,
                        clipID: clip.id,
                        mediaID: mediaID
                    )
                )
            }
        case .sequence(let targetID):
            if !state.sequenceIDs.contains(targetID) {
                state.errors.append(
                    .missingSequenceReference(
                        sequenceID: context.sequenceID,
                        trackID: context.trackID,
                        clipID: clip.id,
                        targetID: targetID
                    )
                )
            }
        }
    }

    private static func validateItemOrder(
        _ item: TimelineItem,
        itemIndex: Int,
        itemState: inout TrackItemState,
        context: TrackContext,
        state: inout ValidationState
    ) {
        let currentRange = item.timelineRange
        defer {
            itemState.previousRange = currentRange
            itemState.previousIndex = itemIndex
        }

        guard
            let lastRange = itemState.previousRange,
            let lastIndex = itemState.previousIndex
        else {
            return
        }

        if currentRange.start < lastRange.start {
            state.errors.append(
                .itemsNotSorted(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    previousIndex: lastIndex,
                    itemIndex: itemIndex
                )
            )
        }

        do {
            if currentRange.start < (try lastRange.end()) {
                state.errors.append(
                    .itemsOverlap(
                        sequenceID: context.sequenceID,
                        trackID: context.trackID,
                        previousIndex: lastIndex,
                        itemIndex: itemIndex
                    )
                )
            }
        } catch let error as RationalTimeError {
            state.errors.append(
                .invalidTimeRange(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    itemIndex: lastIndex,
                    error: error
                )
            )
        } catch {
            state.errors.append(
                .invalidTimeRange(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    itemIndex: lastIndex,
                    error: .arithmeticOverflow
                )
            )
        }
    }
}
