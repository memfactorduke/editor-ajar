// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed failures while resolving a clip source against a project snapshot.
public enum ClipSourceResolutionError: Error, Equatable, Sendable {
    /// A media-backed clip points at a missing media reference.
    case missingMediaReference(UUID)

    /// A sequence-backed compound clip points at a missing sequence.
    case missingSequenceReference(UUID)

    /// Exact time math failed while deriving a sequence duration.
    case timeArithmeticFailed(RationalTimeError)
}

public extension Sequence {
    /// Returns the latest item end across all video and audio tracks.
    ///
    /// Empty sequences have zero duration. Compound clips resolve this at query time so edits to
    /// the referenced sequence are immediately reflected by every compound instance.
    func timelineDuration() throws -> RationalTime {
        var duration = RationalTime.zero

        for track in videoTracks + audioTracks {
            for item in track.items {
                do {
                    let itemEnd = try item.timelineRange.end()
                    if itemEnd > duration {
                        duration = itemEnd
                    }
                } catch let error as RationalTimeError {
                    throw ClipSourceResolutionError.timeArithmeticFailed(error)
                }
            }
        }

        return duration
    }
}

public extension Clip {
    /// Resolves the source's full duration against `project`.
    ///
    /// Media clips use probed media duration. Compound clips use the referenced sequence's current
    /// timeline duration rather than storing a copy on the clip.
    func resolvedSourceDuration(in project: Project) throws -> RationalTime {
        switch source {
        case .media(let mediaID):
            guard let media = project.mediaPool.first(where: { $0.id == mediaID }) else {
                throw ClipSourceResolutionError.missingMediaReference(mediaID)
            }
            return media.metadata.duration
        case .sequence(let sequenceID):
            guard let sequence = project.sequences.first(where: { $0.id == sequenceID }) else {
                throw ClipSourceResolutionError.missingSequenceReference(sequenceID)
            }
            return try sequence.timelineDuration()
        case .title:
            // Generators have no external media length; the placed sourceRange is the duration.
            return sourceRange.duration
        }
    }

    /// Resolves the source's native or conformed timebase when known.
    ///
    /// Sequence-backed compound clips always expose the referenced sequence timebase.
    func resolvedSourceTimebase(in project: Project) throws -> FrameRate? {
        switch source {
        case .media(let mediaID):
            guard let media = project.mediaPool.first(where: { $0.id == mediaID }) else {
                throw ClipSourceResolutionError.missingMediaReference(mediaID)
            }
            return media.metadata.conformedFrameRate ?? media.metadata.frameRate
        case .sequence(let sequenceID):
            guard let sequence = project.sequences.first(where: { $0.id == sequenceID }) else {
                throw ClipSourceResolutionError.missingSequenceReference(sequenceID)
            }
            return sequence.timebase
        case .title:
            // Title generators inherit the sequence timebase at placement; no intrinsic rate.
            return nil
        }
    }
}
