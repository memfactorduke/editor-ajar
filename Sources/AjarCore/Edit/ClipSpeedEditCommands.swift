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

    static func setClipSpeed(_ edit: ClipSpeedEdit, in project: Project) throws -> Project {
        if let error = Clip.validateSpeed(edit.speed) {
            throw EditReducerError.invalidEdit(
                .invalidClipSpeed(clipID: edit.clipID, error: error)
            )
        }

        return try replacingTrack(edit.trackID, sequenceID: edit.sequenceID, in: project) { track in
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
            items[index] = .clip(
                copying(
                    clip,
                    timelineRange: timelineRange,
                    speed: edit.speed
                )
            )
            return copying(track, items: sortedItems(items))
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
