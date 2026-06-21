// SPDX-License-Identifier: GPL-3.0-or-later

/// Errors produced by exact time construction and arithmetic.
public enum RationalTimeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A time value was created with a zero or negative timescale.
    case invalidTimescale(Int64)

    /// A frame rate was created with a zero or negative frame or second count.
    case invalidFrameRate(frames: Int64, seconds: Int64)

    /// A range duration was negative.
    case negativeDuration(RationalTime)

    /// A value cannot be represented exactly at the requested timescale.
    case inexactRescale(value: RationalTime, timescale: Int64)

    /// Integer arithmetic exceeded the exact range `RationalTime` can represent.
    case arithmeticOverflow

    /// A division used a zero divisor.
    case divisionByZero

    /// A human-readable description of the error.
    public var description: String {
        switch self {
        case .invalidTimescale(let timescale):
            "invalid timescale \(timescale); timescale must be positive"
        case .invalidFrameRate(let frames, let seconds):
            "invalid frame rate \(frames)/\(seconds); frame rate parts must be positive"
        case .negativeDuration(let duration):
            "negative time range duration \(duration)"
        case .inexactRescale(let value, let timescale):
            "\(value) cannot be represented exactly at timescale \(timescale)"
        case .arithmeticOverflow:
            "rational time arithmetic overflowed"
        case .divisionByZero:
            "division by zero"
        }
    }
}

/// An exact, normalized time value represented as `value / timescale` seconds.
///
/// `RationalTime` is the foundation for ROADMAP M1 and ADR-0008: timeline math stays exact by
/// avoiding floating-point frame counts. The value can be negative, but the timescale is always
/// positive and normalized to the smallest equivalent fraction.
///
/// Storage uses signed 64-bit integers for both fraction parts. Arithmetic that cannot be
/// represented exactly in that range throws `RationalTimeError.arithmeticOverflow`; it never
/// silently wraps or traps.
public struct RationalTime: Codable, Hashable, Sendable, CustomStringConvertible {
    /// The signed numerator of the normalized time fraction.
    public let value: Int64

    /// The positive denominator of the normalized time fraction.
    public let timescale: Int64

    /// The zero time value.
    public static let zero = RationalTime(normalizedValue: 0, timescale: 1)

    /// Adds two exact time values.
    public static func + (left: RationalTime, right: RationalTime) throws -> RationalTime {
        try left.adding(right)
    }

    /// Subtracts two exact time values.
    public static func - (left: RationalTime, right: RationalTime) throws -> RationalTime {
        try left.subtracting(right)
    }

    /// Negates an exact time value.
    public static prefix func - (time: RationalTime) throws -> RationalTime {
        try time.negated()
    }

    /// Multiplies an exact time value by a scalar.
    public static func * (time: RationalTime, factor: Int64) throws -> RationalTime {
        try time.multiplied(by: factor)
    }

    /// Multiplies an exact time value by a scalar.
    public static func * (factor: Int64, time: RationalTime) throws -> RationalTime {
        try time.multiplied(by: factor)
    }

    /// Divides an exact time value by a scalar.
    public static func / (time: RationalTime, divisor: Int64) throws -> RationalTime {
        try time.divided(by: divisor)
    }

    /// Creates a normalized rational time from `value / timescale` seconds.
    public init(value: Int64, timescale: Int64) throws {
        guard timescale > 0 else {
            throw RationalTimeError.invalidTimescale(timescale)
        }

        let divisor = Self.greatestCommonDivisor(value.magnitude, UInt64(timescale))
        let signedDivisor = Int64(divisor)
        self.value = value / signedDivisor
        self.timescale = timescale / signedDivisor
    }

    /// Creates an exact time at `frameIndex` for a given frame rate.
    public static func atFrame(_ frameIndex: Int64, frameRate: FrameRate) throws -> RationalTime {
        try frameRate.duration(ofFrames: frameIndex)
    }

    /// Returns `self + other`, preserving an exact result or throwing on overflow.
    public func adding(_ other: RationalTime) throws -> RationalTime {
        let commonDivisor = Self.greatestCommonDivisor(UInt64(timescale), UInt64(other.timescale))
        let signedDivisor = Int64(commonDivisor)
        let leftScale = other.timescale / signedDivisor
        let rightScale = timescale / signedDivisor

        let leftValue = try Self.multiplied(value, by: leftScale)
        let rightValue = try Self.multiplied(other.value, by: rightScale)
        let resultValue = try Self.added(leftValue, rightValue)
        let resultTimescale = try Self.multiplied(timescale / signedDivisor, by: other.timescale)

        return try RationalTime(value: resultValue, timescale: resultTimescale)
    }

    /// Returns `self - other`, preserving an exact result or throwing on overflow.
    public func subtracting(_ other: RationalTime) throws -> RationalTime {
        let commonDivisor = Self.greatestCommonDivisor(UInt64(timescale), UInt64(other.timescale))
        let signedDivisor = Int64(commonDivisor)
        let leftScale = other.timescale / signedDivisor
        let rightScale = timescale / signedDivisor

        let leftValue = try Self.multiplied(value, by: leftScale)
        let rightValue = try Self.multiplied(other.value, by: rightScale)
        let resultValue = try Self.subtracted(leftValue, rightValue)
        let resultTimescale = try Self.multiplied(timescale / signedDivisor, by: other.timescale)

        return try RationalTime(value: resultValue, timescale: resultTimescale)
    }

    /// Returns `-self`, preserving an exact result or throwing on overflow.
    public func negated() throws -> RationalTime {
        let result = value.multipliedReportingOverflow(by: -1)
        if result.overflow {
            throw RationalTimeError.arithmeticOverflow
        }
        return RationalTime(normalizedValue: result.partialValue, timescale: timescale)
    }

    /// Returns `self * factor`, preserving an exact result or throwing on overflow.
    public func multiplied(by factor: Int64) throws -> RationalTime {
        let resultValue = try Self.multiplied(value, by: factor)
        return try RationalTime(value: resultValue, timescale: timescale)
    }

    /// Returns `self / divisor`, preserving an exact result or throwing on overflow.
    public func divided(by divisor: Int64) throws -> RationalTime {
        guard divisor != 0 else {
            throw RationalTimeError.divisionByZero
        }

        if divisor < 0 {
            let positiveDivisor = divisor.multipliedReportingOverflow(by: -1)
            if positiveDivisor.overflow {
                throw RationalTimeError.arithmeticOverflow
            }
            let positiveTime = try negated()
            return try positiveTime.divided(by: positiveDivisor.partialValue)
        }

        let resultTimescale = try Self.multiplied(timescale, by: divisor)
        return try RationalTime(value: value, timescale: resultTimescale)
    }

    /// Returns the exact numerator for this same value at `targetTimescale`.
    ///
    /// This is useful when a caller needs to serialize or compare values at a fixed project
    /// timescale. If the value is not exactly representable at `targetTimescale`, this throws
    /// `RationalTimeError.inexactRescale`.
    public func value(atTimescale targetTimescale: Int64) throws -> Int64 {
        guard targetTimescale > 0 else {
            throw RationalTimeError.invalidTimescale(targetTimescale)
        }

        let timescaleDivisor = Self.greatestCommonDivisor(
            UInt64(timescale),
            UInt64(targetTimescale)
        )
        let signedTimescaleDivisor = Int64(timescaleDivisor)
        let reducedTargetTimescale = targetTimescale / signedTimescaleDivisor
        var remainingCurrentTimescale = timescale / signedTimescaleDivisor

        let valueDivisor = Self.greatestCommonDivisor(
            value.magnitude,
            UInt64(remainingCurrentTimescale)
        )
        let signedValueDivisor = Int64(valueDivisor)
        let reducedValue = value / signedValueDivisor
        remainingCurrentTimescale /= signedValueDivisor

        let scaledValue = try Self.multiplied(reducedValue, by: reducedTargetTimescale)
        guard scaledValue % remainingCurrentTimescale == 0 else {
            throw RationalTimeError.inexactRescale(value: self, timescale: targetTimescale)
        }

        return scaledValue / remainingCurrentTimescale
    }

    /// Returns this same value expressed through `targetTimescale` when exactly representable.
    ///
    /// `RationalTime` stores normalized values, so the returned value may reduce back to a smaller
    /// equivalent timescale.
    public func rescaled(toTimescale targetTimescale: Int64) throws -> RationalTime {
        let rescaledValue = try value(atTimescale: targetTimescale)
        return try RationalTime(value: rescaledValue, timescale: targetTimescale)
    }

    /// Returns the least common positive timescale shared by this value and `other`.
    public func commonTimescale(with other: RationalTime) throws -> Int64 {
        try Self.leastCommonTimescale(timescale, other.timescale)
    }

    /// Returns both numerators expressed at the least common timescale.
    public func valuesAtCommonTimescale(
        with other: RationalTime
    ) throws -> CommonTimeValues {
        let sharedTimescale = try commonTimescale(with: other)
        return CommonTimeValues(
            left: try value(atTimescale: sharedTimescale),
            right: try other.value(atTimescale: sharedTimescale),
            timescale: sharedTimescale
        )
    }

    /// Converts this time to a frame index at `frameRate` using the selected rounding rule.
    public func frameIndex(
        at frameRate: FrameRate,
        rounding rule: FrameRoundingRule = .towardZero
    ) throws -> Int64 {
        let secondsDivisor = Self.greatestCommonDivisor(value.magnitude, UInt64(frameRate.seconds))
        let signedSecondsDivisor = Int64(secondsDivisor)
        let reducedValue = value / signedSecondsDivisor
        let reducedSeconds = frameRate.seconds / signedSecondsDivisor

        let timescaleDivisor = Self.greatestCommonDivisor(
            UInt64(frameRate.frames),
            UInt64(timescale)
        )
        let signedTimescaleDivisor = Int64(timescaleDivisor)
        let reducedFrames = frameRate.frames / signedTimescaleDivisor
        let reducedTimescale = timescale / signedTimescaleDivisor

        let numerator = try Self.multiplied(reducedValue, by: reducedFrames)
        let denominator = try Self.multiplied(reducedTimescale, by: reducedSeconds)

        return try Self.roundedQuotient(numerator: numerator, denominator: denominator, rule: rule)
    }

    /// The value in seconds as a lossy `Double`, intended only for display.
    ///
    /// Do not store timeline state with this accessor; use `value` and `timescale` instead.
    public var seconds: Double {
        Double(value) / Double(timescale)
    }

    /// A human-readable fraction, with whole seconds shown without `/1`.
    public var description: String {
        if timescale == 1 {
            "\(value)"
        } else {
            "\(value)/\(timescale)"
        }
    }

    private init(normalizedValue: Int64, timescale: Int64) {
        self.value = normalizedValue
        self.timescale = timescale
    }

    static func greatestCommonDivisor(_ left: UInt64, _ right: UInt64) -> UInt64 {
        var currentLeft = left
        var currentRight = right

        while currentRight != 0 {
            let remainder = currentLeft % currentRight
            currentLeft = currentRight
            currentRight = remainder
        }

        if currentLeft == 0 {
            return 1
        }
        return currentLeft
    }

    static func multiplied(_ left: Int64, by right: Int64) throws -> Int64 {
        let result = left.multipliedReportingOverflow(by: right)
        if result.overflow {
            throw RationalTimeError.arithmeticOverflow
        }
        return result.partialValue
    }

    static func leastCommonTimescale(_ left: Int64, _ right: Int64) throws -> Int64 {
        let commonDivisor = greatestCommonDivisor(UInt64(left), UInt64(right))
        return try multiplied(left / Int64(commonDivisor), by: right)
    }

    private static func added(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        if result.overflow {
            throw RationalTimeError.arithmeticOverflow
        }
        return result.partialValue
    }

    private static func subtracted(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.subtractingReportingOverflow(right)
        if result.overflow {
            throw RationalTimeError.arithmeticOverflow
        }
        return result.partialValue
    }

    private static func roundedQuotient(
        numerator: Int64,
        denominator: Int64,
        rule: FrameRoundingRule
    ) throws -> Int64 {
        guard denominator != 0 else {
            throw RationalTimeError.divisionByZero
        }

        let quotient = numerator / denominator
        let remainder = numerator % denominator
        if remainder == 0 {
            return quotient
        }

        switch rule {
        case .towardZero:
            return quotient
        case .down:
            if numerator < 0 {
                return try decremented(quotient)
            }
            return quotient
        case .up:
            if numerator > 0 {
                return try incremented(quotient)
            }
            return quotient
        case .nearestOrAwayFromZero:
            let remainderMagnitude = remainder.magnitude
            let denominatorMagnitude = UInt64(denominator)
            let exactlyHalf =
                denominatorMagnitude % 2 == 0
                && remainderMagnitude == denominatorMagnitude / 2
            let pastHalf = remainderMagnitude > denominatorMagnitude / 2

            if pastHalf || exactlyHalf {
                if numerator > 0 {
                    return try incremented(quotient)
                }
                return try decremented(quotient)
            }
            return quotient
        }
    }

    private static func incremented(_ value: Int64) throws -> Int64 {
        let result = value.addingReportingOverflow(1)
        if result.overflow {
            throw RationalTimeError.arithmeticOverflow
        }
        return result.partialValue
    }

    private static func decremented(_ value: Int64) throws -> Int64 {
        let result = value.subtractingReportingOverflow(1)
        if result.overflow {
            throw RationalTimeError.arithmeticOverflow
        }
        return result.partialValue
    }

    private static func compareMagnitude(
        leftNumerator: UInt64,
        leftDenominator: UInt64,
        rightNumerator: UInt64,
        rightDenominator: UInt64
    ) -> Int {
        var currentLeftNumerator = leftNumerator
        var currentLeftDenominator = leftDenominator
        var currentRightNumerator = rightNumerator
        var currentRightDenominator = rightDenominator
        var direction = 1

        while true {
            let leftQuotient = currentLeftNumerator / currentLeftDenominator
            let rightQuotient = currentRightNumerator / currentRightDenominator

            if leftQuotient < rightQuotient {
                return -direction
            }
            if leftQuotient > rightQuotient {
                return direction
            }

            let leftRemainder = currentLeftNumerator % currentLeftDenominator
            let rightRemainder = currentRightNumerator % currentRightDenominator

            if leftRemainder == 0 && rightRemainder == 0 {
                return 0
            }
            if leftRemainder == 0 {
                return -direction
            }
            if rightRemainder == 0 {
                return direction
            }

            currentLeftNumerator = currentLeftDenominator
            currentLeftDenominator = leftRemainder
            currentRightNumerator = currentRightDenominator
            currentRightDenominator = rightRemainder
            direction = -direction
        }
    }
}

extension RationalTime: Comparable {
    /// Returns whether `left` is earlier than `right`.
    public static func < (left: RationalTime, right: RationalTime) -> Bool {
        if left.value < 0 && right.value >= 0 {
            return true
        }
        if left.value >= 0 && right.value < 0 {
            return false
        }

        let comparison = compareMagnitude(
            leftNumerator: left.value.magnitude,
            leftDenominator: UInt64(left.timescale),
            rightNumerator: right.value.magnitude,
            rightDenominator: UInt64(right.timescale)
        )

        if left.value < 0 && right.value < 0 {
            return comparison > 0
        }
        return comparison < 0
    }
}
