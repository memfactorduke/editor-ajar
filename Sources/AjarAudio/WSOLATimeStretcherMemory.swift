// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

private struct WSOLAWorkingSetContext {
    let inputFrameCount: Int
    let channelCount: Int
    let speed: RationalValue

    var overflowError: WSOLATimeStretchError {
        .workingSetByteCountOverflow(
            inputFrameCount: inputFrameCount,
            channelCount: channelCount,
            speed: speed
        )
    }
}

extension WSOLATimeStretcher {
    /// Hard ceiling for all temporary arrays retained together by one stretch.
    ///
    /// The estimate includes the extracted interleaved Float input, mono Double analysis
    /// signal, Hann window, padded overlap-add Double samples and window sums, and the final
    /// interleaved Float output. Keeping this independent from caller chunk size prevents a
    /// long pitch-corrected clip from turning each bounded export chunk into an unbounded
    /// whole-clip allocation. Exact streaming WSOLA can replace this refusal once its lag and
    /// overlap state are carried across adjacent render chunks.
    public static let maximumWorkingSetByteCount = 64 * 1_024 * 1_024

    /// Refuses a stretch whose simultaneously-live temporary arrays exceed the fixed budget.
    ///
    /// Callers that must first extract a source subrange invoke this before allocating that
    /// extraction; `stretch` invokes it again as defense in depth for direct callers.
    static func validateWorkingSet(
        inputFrameCount: Int,
        channelCount: Int,
        sampleRate: Int,
        speed: RationalValue
    ) throws {
        let estimatedByteCount = try estimatedWorkingSetByteCount(
            inputFrameCount: inputFrameCount,
            channelCount: channelCount,
            sampleRate: sampleRate,
            speed: speed
        )
        guard estimatedByteCount <= maximumWorkingSetByteCount else {
            throw WSOLATimeStretchError.workingSetLimitExceeded(
                estimatedByteCount: estimatedByteCount,
                maximumByteCount: maximumWorkingSetByteCount
            )
        }
    }

    /// Overflow-safe peak byte estimate for the arrays retained by `stretch`.
    static func estimatedWorkingSetByteCount(
        inputFrameCount: Int,
        channelCount: Int,
        sampleRate: Int,
        speed: RationalValue
    ) throws -> Int {
        guard channelCount > 0 else {
            throw WSOLATimeStretchError.invalidChannelCount(channelCount)
        }
        guard sampleRate > 0 else {
            throw WSOLATimeStretchError.invalidSampleRate(sampleRate)
        }
        guard speed.numerator > 0, speed.denominator > 0 else {
            throw WSOLATimeStretchError.nonPositiveSpeed(speed)
        }
        let context = WSOLAWorkingSetContext(
            inputFrameCount: inputFrameCount,
            channelCount: channelCount,
            speed: speed
        )
        let inputFactors = [inputFrameCount, channelCount, MemoryLayout<Float>.size]
        guard speed != .one, inputFrameCount > 0 else {
            return try workingSetProduct(inputFactors, context: context)
        }

        let outputFrameCount = try stretchedFrameCount(frameCount: inputFrameCount, speed: speed)
        let windowFrameCount = analysisWindowFrameCount(sampleRate: sampleRate)
        let paddedFrameCount = try workingSetSum(
            outputFrameCount,
            windowFrameCount,
            context: context
        )
        let allocationFactors = [
            inputFactors,
            [inputFrameCount, MemoryLayout<Double>.size],
            [windowFrameCount, MemoryLayout<Double>.size],
            [paddedFrameCount, channelCount, MemoryLayout<Double>.size],
            [paddedFrameCount, MemoryLayout<Double>.size],
            [outputFrameCount, channelCount, MemoryLayout<Float>.size]
        ]
        return try allocationFactors.reduce(0) { total, factors in
            try workingSetSum(
                total,
                workingSetProduct(factors, context: context),
                context: context
            )
        }
    }
}

private extension WSOLATimeStretcher {
    static func workingSetProduct(
        _ factors: [Int],
        context: WSOLAWorkingSetContext
    ) throws -> Int {
        try factors.reduce(1) { product, factor in
            let result = product.multipliedReportingOverflow(by: factor)
            guard factor >= 0, !result.overflow else {
                throw context.overflowError
            }
            return result.partialValue
        }
    }

    static func workingSetSum(
        _ left: Int,
        _ right: Int,
        context: WSOLAWorkingSetContext
    ) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard left >= 0, right >= 0, !result.overflow else {
            throw context.overflowError
        }
        return result.partialValue
    }
}
