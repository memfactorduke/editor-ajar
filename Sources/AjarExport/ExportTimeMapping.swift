// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreMedia
import Foundation

enum ExportTimeMapping {
    static func presentationTime(
        forFrame index: Int64,
        frameRate: FrameRate
    ) throws -> CMTime {
        guard frameRate.frames <= Int64(Int32.max) else {
            throw ExportError.timeArithmeticFailed("frame-rate timescale exceeds Int32")
        }
        let multiplied = index.multipliedReportingOverflow(by: frameRate.seconds)
        guard !multiplied.overflow else {
            throw ExportError.timeArithmeticFailed("video presentation timestamp overflow")
        }
        return CMTime(value: multiplied.partialValue, timescale: Int32(frameRate.frames))
    }

    /// Session end time for `AVAssetWriter.endSession(atSourceTime:)`.
    ///
    /// When `duration` is an exact whole number of frames at `frameRate`, the result uses the
    /// **same CMTime timescale as** ``presentationTime(forFrame:frameRate:)`` (frame-rate
    /// numerator). `RationalTime` normalizes `12/30` → `2/5`; ending the session at
    /// `CMTime(value: 2, timescale: 5)` while samples are stamped `k/30` has been observed to
    /// drop or blank the last sample at the end-session boundary (export golden frame N-1).
    /// Non-frame-aligned durations keep the exact rational representation so a rounded-up final
    /// frame can still be trimmed (ADR-0019).
    static func endTime(for duration: RationalTime, frameRate: FrameRate) throws -> CMTime {
        let wholeFrames: Int64
        do {
            wholeFrames = try duration.frameIndex(at: frameRate, rounding: .towardZero)
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
        let wholeDuration: RationalTime
        do {
            wholeDuration = try frameRate.duration(ofFrames: wholeFrames)
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
        if wholeDuration == duration {
            return try presentationTime(forFrame: wholeFrames, frameRate: frameRate)
        }
        guard duration.timescale <= Int64(Int32.max) else {
            throw ExportError.timeArithmeticFailed(
                "export duration timescale exceeds Core Media's Int32 limit"
            )
        }
        return CMTime(value: duration.value, timescale: Int32(duration.timescale))
    }

    /// Exact rational duration as CMTime (audio-only / callers without a video frame rate).
    static func endTime(for duration: RationalTime) throws -> CMTime {
        guard duration.timescale <= Int64(Int32.max) else {
            throw ExportError.timeArithmeticFailed(
                "export duration timescale exceeds Core Media's Int32 limit"
            )
        }
        return CMTime(value: duration.value, timescale: Int32(duration.timescale))
    }
}
