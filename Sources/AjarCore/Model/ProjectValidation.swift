// SPDX-License-Identifier: GPL-3.0-or-later
// swiftlint:disable file_length

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
    /// Two media references use the same stable ID.
    case duplicateMediaReferenceID(UUID)

    /// Two project looks use the same stable ID.
    case duplicateLookID(UUID)

    /// Two project looks use the same trimmed name, ignoring case.
    case duplicateLookName(String)

    /// A project look violates an FR-COL-007 model invariant.
    case invalidLook(lookID: UUID, error: ProjectLookValidationError)

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

    /// A compound clip would make a sequence contain itself directly or transitively.
    case compoundSequenceCycle(sequenceID: UUID, trackID: UUID, clipID: UUID, targetID: UUID)

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

    /// A clip effects stack violates FR-FX-003 / ADR-0016 invariants.
    case invalidClipEffectStack(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: ClipEffectStackValidationError
    )

    /// A clip audio mix is outside the supported range.
    case invalidClipAudioMix(
        sequenceID: UUID, trackID: UUID, clipID: UUID, error: AudioMixValidationError
    )

    /// A clip audio crossfade violates the ADR-0015 pair or source-handle contract.
    case invalidClipAudioCrossfade(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: AudioCrossfadeValidationError
    )

    /// A clip video transition violates the ADR-0016 §5 pair or source-handle contract.
    case invalidClipVideoTransition(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: VideoTransitionValidationError
    )

    /// A clip speed is zero or negative.
    case invalidClipSpeed(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: ClipSpeedValidationError
    )

    /// A clip time-remap curve violates an FR-SPD-002 invariant.
    case invalidClipTimeRemap(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: ClipTimeRemapValidationError
    )

    /// A clip audio retime mode violates the FR-SPD-001 composition policy.
    case invalidClipAudioRetime(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: ClipAudioRetimeValidationError
    )

    /// A sequence ducking rule is outside the supported range or references invalid tracks.
    case invalidAudioDucking(sequenceID: UUID, ruleIndex: Int, error: AudioDuckingValidationError)

    /// A title generator source failed FR-TXT-001 semantic validation.
    case invalidTitleSource(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        error: TitleSourceValidationError
    )

    /// A title generator was placed on a non-video track.
    case titleRequiresVideoTrack(
        sequenceID: UUID,
        trackID: UUID,
        clipID: UUID,
        trackKind: TrackKind
    )
}

enum ProjectValidator {
    struct ValidationState {
        let mediaIDs: Set<UUID>
        let sequenceIDs: Set<UUID>
        let sequenceReferencesBySource: [UUID: [SequenceReferenceEdge]]
        let mediaDurationsByID: [UUID: RationalTime]
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
            sequenceReferencesBySource: sequenceReferenceGraph(in: project),
            mediaDurationsByID: Dictionary(
                project.mediaPool.map { ($0.id, $0.metadata.duration) },
                uniquingKeysWith: { first, _ in first }
            ),
            frame: project.settings.resolution
        )

        var seenSequenceIDs = Set<UUID>()

        validateMediaReferences(project.mediaPool, state: &state)
        validateLooks(project.looks, state: &state)

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

    private static func validateMediaReferences(
        _ media: [MediaRef],
        state: inout ValidationState
    ) {
        var seenIDs = Set<UUID>()
        for reference in media where !seenIDs.insert(reference.id).inserted {
            state.errors.append(.duplicateMediaReferenceID(reference.id))
        }
    }

    private static func validateLooks(_ looks: [ProjectLook], state: inout ValidationState) {
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        for look in looks {
            if !seenIDs.insert(look.id).inserted {
                state.errors.append(.duplicateLookID(look.id))
            }

            let normalizedName = ProjectLookValidator.normalizedName(look.name)
            if !normalizedName.isEmpty && !seenNames.insert(normalizedName).inserted {
                state.errors.append(.duplicateLookName(look.name))
            }

            for error in ProjectLookValidator.errors(for: look) {
                state.errors.append(.invalidLook(lookID: look.id, error: error))
            }
        }
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
            validateTrackCrossfades(track, context: context, state: &state)
            validateTrackVideoTransitions(track, context: context, state: &state)
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
            validateClipSpeed(item, context: context, state: &state)
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
            if sequenceReferenceCreatesCycle(
                sourceID: context.sequenceID,
                targetID: targetID,
                referencesBySource: state.sequenceReferencesBySource
            ) {
                state.errors.append(
                    .compoundSequenceCycle(
                        sequenceID: context.sequenceID,
                        trackID: context.trackID,
                        clipID: clip.id,
                        targetID: targetID
                    )
                )
            }
        case .title(let title):
            appendTitleSourceErrors(title, clip: clip, context: context, state: &state)
        }
    }

    private static func appendTitleSourceErrors(
        _ title: TitleSource,
        clip: Clip,
        context: TrackContext,
        state: inout ValidationState
    ) {
        if context.trackKind != .video || clip.kind != .video {
            state.errors.append(
                .titleRequiresVideoTrack(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    trackKind: context.trackKind
                )
            )
        }
        if let error = title.validate() {
            state.errors.append(
                .invalidTitleSource(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
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

// MARK: - Marker validation

private extension ProjectValidator {
    static func validateMarkers(
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

    static func validateMarkerAnchor(
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

    static func markerSortPrecedes(_ marker: Marker, _ previousMarker: Marker) -> Bool {
        if marker.time == previousMarker.time {
            return marker.id.uuidString < previousMarker.id.uuidString
        }
        return marker.time < previousMarker.time
    }

    static func clipExists(trackID: UUID, clipID: UUID, in sequence: Sequence) -> Bool {
        for track in sequence.videoTracks + sequence.audioTracks where track.id == trackID {
            for item in track.items {
                if case .clip(let clip) = item, clip.id == clipID {
                    return true
                }
            }
        }
        return false
    }
}
