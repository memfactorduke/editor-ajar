// SPDX-License-Identifier: GPL-3.0-or-later

/// A rational frame rate expressed as `frames / seconds`.
public struct FrameRate: Codable, Hashable, Sendable, CustomStringConvertible {
    /// The positive frame count in the normalized rate fraction.
    public let frames: Int64

    /// The positive second count in the normalized rate fraction.
    public let seconds: Int64

    /// Creates a normalized frame rate from `frames / seconds`.
    public init(frames: Int64, per seconds: Int64 = 1) throws {
        guard frames > 0, seconds > 0 else {
            throw RationalTimeError.invalidFrameRate(frames: frames, seconds: seconds)
        }

        let divisor = RationalTime.greatestCommonDivisor(UInt64(frames), UInt64(seconds))
        let signedDivisor = Int64(divisor)
        self.frames = frames / signedDivisor
        self.seconds = seconds / signedDivisor
    }

    /// Returns the exact duration of `frameCount` frames.
    public func duration(ofFrames frameCount: Int64) throws -> RationalTime {
        let resultValue = try RationalTime.multiplied(frameCount, by: seconds)
        return try RationalTime(value: resultValue, timescale: frames)
    }

    /// A human-readable `frames/seconds fps` string.
    public var description: String {
        if seconds == 1 {
            "\(frames) fps"
        } else {
            "\(frames)/\(seconds) fps"
        }
    }
}

/// Rounding policies for converting exact time to frame indexes.
public enum FrameRoundingRule: Codable, Hashable, Sendable {
    /// Round toward zero.
    case towardZero

    /// Round toward negative infinity.
    case down

    /// Round toward positive infinity.
    case up

    /// Round to nearest frame, with exact half-frames rounded away from zero.
    case nearestOrAwayFromZero
}
