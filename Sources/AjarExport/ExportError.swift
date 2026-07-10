// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Media stream associated with an export writer failure.
public enum ExportMediaKind: String, Equatable, Sendable {
    /// Encoded video stream.
    case video

    /// Encoded audio stream.
    case audio
}

/// Typed state of one queue-drivable export session (FR-EXP-005).
public enum ExportSessionState: String, Equatable, Sendable {
    /// The session has not started.
    case ready

    /// Settings, audio, and the same-directory output transaction are being prepared.
    case preparing

    /// Frames and samples are being appended.
    case writing

    /// Inputs are closed and the container is being finalized.
    case finishing

    /// Cancellation was requested and cleanup is pending.
    case cancelling

    /// The completed temporary file was atomically published.
    case completed

    /// Cancellation completed with no partial destination file.
    case cancelled

    /// The session failed and removed its temporary output.
    case failed
}

/// Typed failures surfaced by the export boundary.
public enum ExportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Persisted or programmatic settings are invalid.
    case invalidSettings(ExportSettingsValidationError)

    /// The project does not contain the requested sequence.
    case sequenceNotFound(UUID)

    /// The requested timeline range is empty, negative, or outside the sequence.
    case invalidRange(TimeRange)

    /// In/out marks form an empty or inverted half-open span (FR-EXP-004).
    case emptyOrInvertedRange(start: RationalTime, end: RationalTime)

    /// Still-frame export time is outside the sequence timeline (FR-EXP-004).
    case stillFrameTimeOutOfRange(RationalTime)

    /// Still-frame image encoding failed.
    case stillFrameWriteFailed(String)

    /// Audio-only export failed before or during container write.
    case audioOnlyExportFailed(String)

    /// The graph delivery space and the writer tag would disagree.
    case colorSpaceMismatch(project: MediaColorSpace, export: ExportColorSpace)

    /// Audio export was enabled without an offline-mixer source provider.
    case missingAudioSourceProvider

    /// Export audio must use the captured project's deterministic mix sample rate.
    case audioSampleRateMismatch(project: Int, export: Int)

    /// Export destinations must be local file URLs.
    case destinationMustBeFileURL(URL)

    /// The destination's parent directory is missing or not a directory.
    case destinationDirectoryUnavailable(URL)

    /// AVAssetWriter could not be constructed.
    case writerCreationFailed(String)

    /// AVFoundation or VideoToolbox refused a requested encoder/profile.
    case encoderRefused(codec: ExportVideoCodec, reason: String)

    /// AVAssetWriter refused a video or audio input.
    case inputConfigurationFailed(ExportMediaKind, String)

    /// The asset writer could not enter its writing state.
    case writerStartFailed(String)

    /// Core Video could not create the configured encoder pixel-buffer pool.
    case pixelBufferPoolCreationFailed(Int32)

    /// Core Video could not allocate an encoder pixel buffer.
    case pixelBufferCreationFailed(Int32)

    /// Exact frame or sample timestamp arithmetic failed.
    case timeArithmeticFailed(String)

    /// A render graph or frame source failed before append.
    case frameRenderFailed(frameIndex: Int64, reason: String)

    /// The deterministic offline mixer failed.
    case audioMixFailed(String)

    /// Core Media could not package PCM for the writer input.
    case audioSampleBufferFailed(Int32)

    /// An encoder or writer refused an append operation.
    case appendRefused(
        ExportMediaKind,
        reason: String,
        underlyingError: NSError?
    )

    /// The writer failed after it started.
    case writerFailed(String)

    /// The output volume ran out of free space.
    case diskFull(URL)

    /// A complete temporary movie could not be atomically published.
    case finalizationFailed(String)

    /// A failed or cancelled session could not remove its temporary file.
    ///
    /// Carries both the original export failure that triggered cleanup and the cleanup failure
    /// itself so neither is discarded (NFR-STAB). `indirect` because the payload nests
    /// another `ExportError`.
    indirect case cleanupFailed(rootCause: ExportError, temporaryURL: URL, reason: String)

    /// Export was cancelled before atomic publication.
    case cancelled

    /// A session may run exactly once.
    case invalidSessionState(ExportSessionState)

    /// A human-readable export failure.
    public var description: String {
        switch self {
        case .invalidSettings(let error):
            "invalid export settings: \(error)"
        case .sequenceNotFound(let id):
            "export sequence \(id) was not found"
        case .invalidRange(let range):
            "invalid export range [\(range.start), +\(range.duration))"
        case .emptyOrInvertedRange(let start, let end):
            "export range is empty or inverted [\(start), \(end))"
        case .stillFrameTimeOutOfRange(let time):
            "still-frame time \(time) is outside the sequence timeline"
        case .stillFrameWriteFailed(let reason):
            "still-frame write failed: \(reason)"
        case .audioOnlyExportFailed(let reason):
            "audio-only export failed: \(reason)"
        case .colorSpaceMismatch(let project, let export):
            "render output \(project.rawValue) cannot be tagged as \(export.rawValue)"
        case .missingAudioSourceProvider:
            "audio export requires an offline audio source provider"
        case .audioSampleRateMismatch(let project, let export):
            "audio sample rate \(export) does not match project mix rate \(project)"
        case .destinationMustBeFileURL(let url):
            "export destination must be a file URL: \(url)"
        case .destinationDirectoryUnavailable(let url):
            "export destination directory is unavailable: \(url.path)"
        case .writerCreationFailed(let reason):
            "asset writer creation failed: \(reason)"
        case .encoderRefused(let codec, let reason):
            "\(codec.rawValue) encoder refused export: \(reason)"
        case .inputConfigurationFailed(let kind, let reason):
            "\(kind.rawValue) writer input configuration failed: \(reason)"
        case .writerStartFailed(let reason):
            "asset writer could not start: \(reason)"
        case .pixelBufferPoolCreationFailed(let status):
            "encoder pixel-buffer pool creation failed with status \(status)"
        case .pixelBufferCreationFailed(let status):
            "encoder pixel-buffer allocation failed with status \(status)"
        case .timeArithmeticFailed(let reason):
            "export time arithmetic failed: \(reason)"
        case .frameRenderFailed(let frameIndex, let reason):
            "export frame \(frameIndex) failed: \(reason)"
        case .audioMixFailed(let reason):
            "offline audio mix failed: \(reason)"
        case .audioSampleBufferFailed(let status):
            "audio sample-buffer creation failed with status \(status)"
        case .appendRefused(let kind, let reason, _):
            "\(kind.rawValue) append was refused: \(reason)"
        case .writerFailed(let reason):
            "asset writer failed: \(reason)"
        case .diskFull(let url):
            "export volume is full near \(url.path)"
        case .finalizationFailed(let reason):
            "export finalization failed: \(reason)"
        case .cleanupFailed(let rootCause, let url, let reason):
            "could not remove partial export \(url.path) after \(rootCause): \(reason)"
        case .cancelled:
            "export cancelled"
        case .invalidSessionState(let state):
            "export session cannot start from \(state.rawValue)"
        }
    }
}

/// Frame-level export progress for the FR-EXP-005 queue driver.
public struct ExportProgress: Equatable, Sendable {
    /// Sequential video frames successfully appended so far.
    public let framesWritten: Int64

    /// Total video frames planned for this session.
    public let totalFrames: Int64

    /// Creates progress counters.
    public init(framesWritten: Int64, totalFrames: Int64) {
        self.framesWritten = framesWritten
        self.totalFrames = totalFrames
    }

    /// Fraction in `0...1` of video frames written. Zero when no frames are planned.
    public var fractionCompleted: Double {
        guard totalFrames > 0 else {
            return 0
        }
        return Double(framesWritten) / Double(totalFrames)
    }
}
