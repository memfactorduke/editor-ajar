// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    struct ClipSpeedEdit {
        let sequenceID: UUID
        let trackID: UUID
        let clipID: UUID
        let speed: RationalValue
    }

    static func applyClipSpeedCommand(
        _ command: EditCommand,
        to project: Project
    ) throws -> Project {
        switch command {
        case .setClipSpeed(let sequenceID, let trackID, let clipID, let speed):
            return try setClipSpeed(
                ClipSpeedEdit(
                    sequenceID: sequenceID,
                    trackID: trackID,
                    clipID: clipID,
                    speed: speed
                ),
                in: project
            )
        default:
            throw EditReducerError.validationFailed([])
        }
    }

    /// Retimes a clip at a constant rate (FR-SPD-001) and propagates the same speed to its
    /// FR-TL-009 linked partners so linked A/V stays sample-exact, mirroring how trim/ripple/
    /// slip/slide fan out through the link group. Each affected track ripples by the duration
    /// delta using the ripple-trim convention.
    static func setClipSpeed(_ edit: ClipSpeedEdit, in project: Project) throws -> Project {
        if let error = Clip.validateSpeed(edit.speed) {
            throw EditReducerError.invalidEdit(
                .invalidClipSpeed(clipID: edit.clipID, error: error)
            )
        }

        let sequence = try sequence(edit.sequenceID, in: project)
        let sourceLocation = try locateClip(
            ClipReference(trackID: edit.trackID, clipID: edit.clipID),
            in: sequence
        )
        var editedProject = try setClipSpeedWithoutLinkedPartners(edit, in: project)

        for linkedClip in linkedPartnerLocations(for: sourceLocation, in: sequence) {
            editedProject = try setClipSpeedWithoutLinkedPartners(
                ClipSpeedEdit(
                    sequenceID: edit.sequenceID,
                    trackID: linkedClip.reference.trackID,
                    clipID: linkedClip.clip.id,
                    speed: edit.speed
                ),
                in: editedProject
            )
        }

        return editedProject
    }

    /// Applies the retime to one clip and ripples later items on its track by the duration
    /// delta, matching `rippleTrimClipWithoutLinkedPartners`: slow-downs push later items
    /// right, speed-ups pull them left so no gap is introduced.
    static func setClipSpeedWithoutLinkedPartners(
        _ edit: ClipSpeedEdit,
        in project: Project
    ) throws -> Project {
        try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
            guard
                let clipIndex = clipIndex(edit.clipID, in: track.items),
                case .clip(let clip) = track.items[clipIndex]
            else {
                throw EditReducerError.clipNotFound(
                    sequenceID: edit.sequenceID,
                    trackID: edit.trackID,
                    clipID: edit.clipID
                )
            }

            let timelineDuration = try speedTimelineDuration(
                clipID: edit.clipID,
                sourceDuration: clip.sourceRange.duration,
                speed: edit.speed
            )
            guard timelineDuration > .zero else {
                throw EditReducerError.invalidEdit(.nonPositiveDuration(clipID: edit.clipID))
            }
            let timelineRange = try makeRange(
                start: clip.timelineRange.start,
                duration: timelineDuration
            )
            let oldEnd = try exactTime { try clip.timelineRange.end() }
            let newEnd = try exactTime { try timelineRange.end() }
            let downstreamOffset = try subtractTimes(newEnd, oldEnd)

            var items: [TimelineItem] = []
            for itemIndex in track.items.indices {
                let item = track.items[itemIndex]
                if itemIndex == clipIndex {
                    items.append(
                        .clip(copying(clip, timelineRange: timelineRange, speed: edit.speed))
                    )
                } else if item.timelineRange.start >= oldEnd {
                    items.append(try offsetItem(item, by: downstreamOffset))
                } else {
                    items.append(item)
                }
            }
            // ADR-0015 §8: the ripple keeps the cut abutting, so any pair is preserved
            // with its duration clamped to the retimed clip duration and the
            // speed-scaled tail handle (zero removes).
            return try maintainingCutEdgeMetadata(
                copying(track, items: sortedItems(items)),
                in: project
            )
        }
    }

    static func speedTimelineDuration(
        clipID: UUID,
        sourceDuration: RationalTime,
        speed: RationalValue
    ) throws -> RationalTime {
        do {
            return try Clip.timelineDuration(forSourceDuration: sourceDuration, speed: speed)
        } catch let error as ClipSpeedMappingError {
            throw editReducerError(clipID: clipID, speedMappingError: error)
        }
    }

    static func speedSourceDuration(
        clipID: UUID,
        timelineDuration: RationalTime,
        speed: RationalValue
    ) throws -> RationalTime {
        do {
            return try Clip.sourceDuration(forTimelineDuration: timelineDuration, speed: speed)
        } catch let error as ClipSpeedMappingError {
            throw editReducerError(clipID: clipID, speedMappingError: error)
        }
    }

    private static func editReducerError(
        clipID: UUID,
        speedMappingError: ClipSpeedMappingError
    ) -> EditReducerError {
        switch speedMappingError {
        case .invalidSpeed(let error):
            return .invalidEdit(.invalidClipSpeed(clipID: clipID, error: error))
        case .invalidTimeRemap(let error):
            return .invalidEdit(.invalidClipTimeRemap(clipID: clipID, error: error))
        case .timeArithmetic(let error):
            return .timeArithmeticFailed(error)
        }
    }
}
