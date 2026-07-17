// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Immutable inputs captured by a deterministic export session.
public struct ExportRequest: Sendable {
    /// Project snapshot used for every frame and audio sample.
    public let project: Project

    /// Sequence in the project snapshot to export.
    public let sequenceID: UUID

    /// Captured sequence value resolved during validation.
    public let sequence: Sequence

    /// Half-open timeline range to export.
    public let range: TimeRange

    /// Final destination, published only after successful writer finalization.
    public let destinationURL: URL

    /// Validated encoder, container, color, and audio settings.
    public let settings: ExportSettings

    /// Creates and validates a captured export request.
    public init(
        project: Project,
        sequenceID: UUID,
        range: TimeRange,
        destinationURL: URL,
        settings: ExportSettings
    ) throws {
        do {
            try settings.validate()
        } catch let error as ExportSettingsValidationError {
            throw ExportError.invalidSettings(error)
        }

        guard let sequence = project.sequences.first(where: { $0.id == sequenceID }) else {
            throw ExportError.sequenceNotFound(sequenceID)
        }
        guard range.start >= .zero, range.duration > .zero else {
            throw ExportError.invalidRange(range)
        }
        do {
            guard try range.end() <= sequence.timelineDuration() else {
                throw ExportError.invalidRange(range)
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
        guard project.settings.colorSpace == settings.video.colorSpace.mediaColorSpace else {
            throw ExportError.colorSpaceMismatch(
                project: project.settings.colorSpace,
                export: settings.video.colorSpace
            )
        }
        if let audio = settings.audio,
            audio.sampleRate != project.settings.audioSampleRate {
            throw ExportError.audioSampleRateMismatch(
                project: project.settings.audioSampleRate,
                export: audio.sampleRate
            )
        }
        guard destinationURL.isFileURL else {
            throw ExportError.destinationMustBeFileURL(destinationURL)
        }

        self.project = project
        self.sequenceID = sequenceID
        self.sequence = sequence
        self.range = range
        self.destinationURL = destinationURL
        self.settings = settings
    }

    func videoFrameCount() throws -> Int64 {
        do {
            return try range.duration.frameIndex(
                at: settings.video.frameRate,
                rounding: .up
            )
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
    }

    func timelineTime(forFrame index: Int64) throws -> RationalTime {
        do {
            return try range.start.adding(
                settings.video.frameRate.duration(ofFrames: index)
            )
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
    }
}

/// Successful export summary returned to the FR-EXP-005 queue.
public struct ExportResult: Equatable, Sendable {
    /// Atomically published output URL.
    public let destinationURL: URL

    /// Exact exported timeline duration.
    public let duration: RationalTime

    /// Number of sequential video frames appended.
    public let videoFrameCount: Int64

    /// Number of offline-mixed audio frames appended.
    public let audioFrameCount: Int

    /// Number of executed per-frame source selections observed by the render graph.
    public let sourceSelectionRecordCount: Int

    /// Whether any executed source selection used proxy media (must stay false in production).
    public let usedProxyMedia: Bool

    /// Creates an export result.
    public init(
        destinationURL: URL,
        duration: RationalTime,
        videoFrameCount: Int64,
        audioFrameCount: Int,
        sourceSelectionRecordCount: Int = 0,
        usedProxyMedia: Bool = false
    ) {
        self.destinationURL = destinationURL
        self.duration = duration
        self.videoFrameCount = videoFrameCount
        self.audioFrameCount = audioFrameCount
        self.sourceSelectionRecordCount = sourceSelectionRecordCount
        self.usedProxyMedia = usedProxyMedia
    }
}
