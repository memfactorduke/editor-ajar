// SPDX-License-Identifier: GPL-3.0-or-later

/// Validation errors for constant-rate clip speed.
public enum ClipSpeedValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Speed must be greater than zero.
    case nonPositiveSpeed(RationalValue)

    /// A human-readable description of the speed validation failure.
    public var description: String {
        switch self {
        case .nonPositiveSpeed(let speed):
            "clip speed \(speed.numerator)/\(speed.denominator) must be greater than zero"
        }
    }
}

/// Errors produced while mapping timeline time through a clip speed/remap.
public enum ClipSpeedMappingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The speed value is invalid.
    case invalidSpeed(ClipSpeedValidationError)

    /// Exact time arithmetic failed.
    case timeArithmetic(RationalTimeError)

    /// A human-readable description of the mapping failure.
    public var description: String {
        switch self {
        case .invalidSpeed(let error):
            error.description
        case .timeArithmetic(let error):
            "clip speed/remap time mapping failed: \(error)"
        }
    }
}

public extension Clip {
    /// Returns a validation error when `speed` is not a supported constant rate.
    static func validateSpeed(_ speed: RationalValue) -> ClipSpeedValidationError? {
        guard speed.numerator > 0 else {
            return .nonPositiveSpeed(speed)
        }
        return nil
    }

    /// Returns timeline duration for a source range at constant speed.
    static func timelineDuration(
        forSourceDuration sourceDuration: RationalTime,
        speed: RationalValue
    ) throws -> RationalTime {
        try validateSpeedOrThrow(speed)
        do {
            return try sourceDuration
                .multiplied(by: speed.denominator)
                .divided(by: speed.numerator)
        } catch let error as RationalTimeError {
            throw ClipSpeedMappingError.timeArithmetic(error)
        }
    }

    /// Returns source duration consumed by a timeline duration at constant speed.
    static func sourceDuration(
        forTimelineDuration timelineDuration: RationalTime,
        speed: RationalValue
    ) throws -> RationalTime {
        try validateSpeedOrThrow(speed)
        do {
            return try timelineDuration
                .multiplied(by: speed.numerator)
                .divided(by: speed.denominator)
        } catch let error as RationalTimeError {
            throw ClipSpeedMappingError.timeArithmetic(error)
        }
    }

    /// Maps a timeline-local offset to a source-local offset using this clip's speed.
    func sourceOffset(forTimelineOffset timelineOffset: RationalTime) throws -> RationalTime {
        try Self.sourceDuration(forTimelineDuration: timelineOffset, speed: speed)
    }

    /// Maps an absolute sequence time to this clip's source time.
    ///
    /// Reverse clips use the mathematical half-open range end here. Consumers that decode discrete
    /// frames or samples clamp that exclusive end to their last valid media quantum.
    func sourceTime(at timelineTime: RationalTime) throws -> RationalTime {
        do {
            try Self.validateSpeedOrThrow(speed)
            if freezeFrame {
                return sourceRange.start
            }
            let timelineOffset = try timelineTime.subtracting(timelineRange.start)
            let sourceOffset = try sourceOffset(forTimelineOffset: timelineOffset)
            if reverse {
                return try sourceRange.end().subtracting(sourceOffset)
            }
            return try sourceRange.start.adding(sourceOffset)
        } catch let error as ClipSpeedMappingError {
            throw error
        } catch let error as RationalTimeError {
            throw ClipSpeedMappingError.timeArithmetic(error)
        }
    }

    private static func validateSpeedOrThrow(_ speed: RationalValue) throws {
        if let error = validateSpeed(speed) {
            throw ClipSpeedMappingError.invalidSpeed(error)
        }
    }
}
