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

    static func endTime(for duration: RationalTime) throws -> CMTime {
        guard duration.timescale <= Int64(Int32.max) else {
            throw ExportError.timeArithmeticFailed(
                "export duration timescale exceeds Core Media's Int32 limit"
            )
        }
        return CMTime(value: duration.value, timescale: Int32(duration.timescale))
    }
}
