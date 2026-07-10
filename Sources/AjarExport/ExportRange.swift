// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// How the user (or CLI) selects the half-open timeline span to export (FR-EXP-004).
public enum ExportRangeSelection: Equatable, Sendable {
    /// Export the entire sequence timeline (`[0, timelineDuration)`).
    case wholeTimeline

    /// Export the half-open span between in and out marks.
    ///
    /// Marks are timeline times. `outPoint` must be strictly greater than `inPoint`; equal or
    /// inverted pairs are a typed validation failure.
    case inOut(inPoint: RationalTime, outPoint: RationalTime)
}

/// Resolves a UI/CLI range selection into a validated `TimeRange` for `ExportRequest`.
public enum ExportRangeResolver {
    /// Converts `selection` into a half-open range bounded by the sequence timeline.
    ///
    /// - Throws: `ExportError.emptyOrInvertedRange` when in/out is empty or inverted;
    ///   `ExportError.invalidRange` when the span lies outside the sequence;
    ///   `ExportError.timeArithmeticFailed` on exact-time math failure.
    public static func resolve(
        _ selection: ExportRangeSelection,
        sequence: Sequence
    ) throws -> TimeRange {
        let timelineDuration: RationalTime
        do {
            timelineDuration = try sequence.timelineDuration()
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }

        switch selection {
        case .wholeTimeline:
            guard timelineDuration > .zero else {
                throw ExportError.emptyOrInvertedRange(start: .zero, end: .zero)
            }
            do {
                return try TimeRange(start: .zero, duration: timelineDuration)
            } catch {
                throw ExportError.timeArithmeticFailed(String(describing: error))
            }

        case .inOut(let inPoint, let outPoint):
            return try resolveInOut(
                inPoint: inPoint,
                outPoint: outPoint,
                timelineDuration: timelineDuration
            )
        }
    }

    private static func resolveInOut(
        inPoint: RationalTime,
        outPoint: RationalTime,
        timelineDuration: RationalTime
    ) throws -> TimeRange {
        guard outPoint > inPoint else {
            throw ExportError.emptyOrInvertedRange(start: inPoint, end: outPoint)
        }
        guard inPoint >= .zero else {
            let duration: RationalTime
            do {
                duration = try outPoint.subtracting(inPoint)
            } catch {
                throw ExportError.timeArithmeticFailed(String(describing: error))
            }
            do {
                throw ExportError.invalidRange(
                    try TimeRange(start: inPoint, duration: duration)
                )
            } catch let error as ExportError {
                throw error
            } catch {
                throw ExportError.timeArithmeticFailed(String(describing: error))
            }
        }
        guard outPoint <= timelineDuration else {
            let duration: RationalTime
            do {
                duration = try outPoint.subtracting(inPoint)
            } catch {
                throw ExportError.timeArithmeticFailed(String(describing: error))
            }
            do {
                throw ExportError.invalidRange(
                    try TimeRange(start: inPoint, duration: duration)
                )
            } catch let error as ExportError {
                throw error
            } catch {
                throw ExportError.timeArithmeticFailed(String(describing: error))
            }
        }

        let duration: RationalTime
        do {
            duration = try outPoint.subtracting(inPoint)
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
        guard duration > .zero else {
            throw ExportError.emptyOrInvertedRange(start: inPoint, end: outPoint)
        }
        do {
            return try TimeRange(start: inPoint, duration: duration)
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
    }
}
