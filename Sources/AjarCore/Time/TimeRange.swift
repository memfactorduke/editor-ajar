// SPDX-License-Identifier: GPL-3.0-or-later

/// A half-open exact time range: `[start, end)`.
public struct TimeRange: Codable, Hashable, Sendable {
    /// The inclusive start time.
    public let start: RationalTime

    /// The non-negative duration.
    public let duration: RationalTime

    /// Creates a half-open range beginning at `start` and lasting `duration`.
    public init(start: RationalTime, duration: RationalTime) throws {
        guard duration >= .zero else {
            throw RationalTimeError.negativeDuration(duration)
        }

        self.start = start
        self.duration = duration
    }

    /// Returns the exclusive end time.
    public func end() throws -> RationalTime {
        try start.adding(duration)
    }

    /// Returns whether `time` is inside the half-open range.
    public func contains(_ time: RationalTime) throws -> Bool {
        let rangeEnd = try end()
        return time >= start && time < rangeEnd
    }

    /// Returns whether this range overlaps `other`.
    public func intersects(_ other: TimeRange) throws -> Bool {
        let rangeEnd = try end()
        let otherEnd = try other.end()
        return start < otherEnd && other.start < rangeEnd
    }
}
