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
    /// A track is stored in the wrong sequence track collection.
    case trackKindMismatch(sequenceID: UUID, trackID: UUID, expected: TrackKind, actual: TrackKind)

    /// A timeline item kind does not match its containing track.
    case itemKindMismatch(sequenceID: UUID, trackID: UUID, itemIndex: Int, itemKind: TrackKind)

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
}

enum ProjectValidator {
    private struct ValidationState {
        let mediaIDs: Set<UUID>
        let sequenceIDs: Set<UUID>
        var errors: [ProjectValidationError] = []
    }

    private struct TrackContext {
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
            sequenceIDs: Set(project.sequences.map(\.id))
        )

        for sequence in project.sequences {
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
