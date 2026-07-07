// SPDX-License-Identifier: GPL-3.0-or-later

/// One time-remap keyframe mapping a clip-local timeline offset to a source time (FR-SPD-002).
public struct TimeRemapKeyframe: Codable, Equatable, Sendable {
    /// Timeline offset from the clip's timeline start.
    public let time: RationalTime

    /// Absolute source media time mapped at `time`.
    public let sourceTime: RationalTime

    /// Creates a time-remap keyframe.
    public init(time: RationalTime, sourceTime: RationalTime) {
        self.time = time
        self.sourceTime = sourceTime
    }
}

/// Typed validation errors for FR-SPD-002 time-remap curves.
public enum ClipTimeRemapValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A curve needs at least two keyframes to define a segment.
    case insufficientKeyframes(count: Int)

    /// The first keyframe must sit at timeline offset zero.
    case firstKeyframeNotAtZero(RationalTime)

    /// Keyframe timeline offsets must be strictly increasing.
    case keyframesNotSorted(index: Int, previousTime: RationalTime, time: RationalTime)

    /// Source times must be monotonic non-decreasing for forward playback.
    case decreasingSourceTime(
        index: Int,
        previousSourceTime: RationalTime,
        sourceTime: RationalTime
    )

    /// A time-remap curve cannot be combined with reverse, freeze-frame, or non-unit speed.
    case conflictingRetime(reverse: Bool, freezeFrame: Bool, speed: RationalValue)

    /// The curve domain must exactly cover the clip's timeline duration.
    case curveDurationMismatch(curveDuration: RationalTime, timelineDuration: RationalTime)

    /// A keyframe maps outside the clip's source range.
    case sourceTimeOutOfBounds(sourceTime: RationalTime, sourceRange: TimeRange)

    /// Exact time arithmetic failed while validating the curve against the clip.
    case timeArithmetic(RationalTimeError)

    /// A human-readable description of the validation failure.
    public var description: String {
        switch self {
        case .insufficientKeyframes(let count):
            "time remap needs at least two keyframes, got \(count)"
        case .firstKeyframeNotAtZero(let time):
            "time remap must start at offset zero, got \(time)"
        case .keyframesNotSorted(let index, let previousTime, let time):
            "time remap keyframe \(index) at \(time) must be later than \(previousTime)"
        case .decreasingSourceTime(let index, let previousSourceTime, let sourceTime):
            "time remap keyframe \(index) maps \(sourceTime) before \(previousSourceTime); "
                + "the curve must be monotonic non-decreasing"
        case .conflictingRetime(let reverse, let freezeFrame, let speed):
            "time remap cannot combine with reverse=\(reverse) freezeFrame=\(freezeFrame) "
                + "speed=\(speed.numerator)/\(speed.denominator); encode ramps in the curve"
        case .curveDurationMismatch(let curveDuration, let timelineDuration):
            "time remap domain \(curveDuration) must equal timeline duration \(timelineDuration)"
        case .sourceTimeOutOfBounds(let sourceTime, let sourceRange):
            "time remap source time \(sourceTime) is outside source range "
                + "\(sourceRange.start)+\(sourceRange.duration)"
        case .timeArithmetic(let error):
            "time remap validation arithmetic failed: \(error)"
        }
    }
}

/// A keyframed timeline-to-source time-remap curve for speed ramping (FR-SPD-002).
///
/// Keyframe segments interpolate linearly, so the instantaneous speed is the segment slope:
/// a `1x -> 2x` ramp is two segments with slopes one and two, and a zero-slope segment freezes
/// on its segment-start source time. Construction and decoding validate that offsets strictly
/// increase and source times never decrease, so a stored curve is always forward-monotonic.
public struct ClipTimeRemap: Codable, Equatable, Sendable {
    /// Keyframes in strictly ascending timeline-offset order with non-decreasing source times.
    public let keyframes: [TimeRemapKeyframe]

    private enum CodingKeys: String, CodingKey {
        case keyframes
    }

    /// Creates a validated time-remap curve.
    public init(keyframes: [TimeRemapKeyframe]) throws {
        if let error = Self.validate(keyframes: keyframes) {
            throw error
        }
        self.keyframes = keyframes
    }

    /// Decodes and validates the curve invariants.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(keyframes: container.decode([TimeRemapKeyframe].self, forKey: .keyframes))
    }

    /// Encodes the curve keyframes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyframes, forKey: .keyframes)
    }

    /// Returns the structural validation error for a keyframe list, if any.
    public static func validate(keyframes: [TimeRemapKeyframe]) -> ClipTimeRemapValidationError? {
        guard keyframes.count >= 2 else {
            return .insufficientKeyframes(count: keyframes.count)
        }
        guard let first = keyframes.first, first.time == .zero else {
            return .firstKeyframeNotAtZero(keyframes.first?.time ?? .zero)
        }

        for index in keyframes.indices.dropFirst() {
            let previous = keyframes[index - 1]
            let current = keyframes[index]
            if current.time <= previous.time {
                return .keyframesNotSorted(
                    index: index,
                    previousTime: previous.time,
                    time: current.time
                )
            }
            if current.sourceTime < previous.sourceTime {
                return .decreasingSourceTime(
                    index: index,
                    previousSourceTime: previous.sourceTime,
                    sourceTime: current.sourceTime
                )
            }
        }
        return nil
    }

    /// The curve domain length. Timeline duration for a remapped clip derives from this value.
    public var duration: RationalTime {
        keyframes.last?.time ?? .zero
    }

    /// The earliest source time on the curve (the first keyframe, by monotonicity).
    public var sourceStart: RationalTime {
        keyframes.first?.sourceTime ?? .zero
    }

    /// The latest source time on the curve (the last keyframe, by monotonicity).
    public var sourceEnd: RationalTime {
        keyframes.last?.sourceTime ?? .zero
    }

    /// Evaluates the curve at a clip-local timeline offset with exact rational arithmetic.
    ///
    /// Offsets outside the curve domain clamp to the endpoint source times, so evaluation can
    /// never read past the keyframed source span.
    public func sourceTime(atOffset offset: RationalTime) throws -> RationalTime {
        guard let first = keyframes.first, let last = keyframes.last else {
            return .zero
        }
        if offset <= first.time {
            return first.sourceTime
        }
        if offset >= last.time {
            return last.sourceTime
        }

        var left = first
        for right in keyframes.dropFirst() {
            if offset <= right.time {
                return try interpolatedSourceTime(atOffset: offset, left: left, right: right)
            }
            left = right
        }
        return last.sourceTime
    }

    /// Linear segment evaluation: `left.sourceTime + deltaSource * elapsed / segmentDuration`,
    /// kept exact by rescaling the elapsed fraction onto a common timescale (ADR-0008).
    private func interpolatedSourceTime(
        atOffset offset: RationalTime,
        left: TimeRemapKeyframe,
        right: TimeRemapKeyframe
    ) throws -> RationalTime {
        let elapsed = try offset.subtracting(left.time)
        let segment = try right.time.subtracting(left.time)
        let deltaSource = try right.sourceTime.subtracting(left.sourceTime)
        let fraction = try elapsed.valuesAtCommonTimescale(with: segment)
        guard fraction.right != 0 else {
            return left.sourceTime
        }
        let scaled = try deltaSource.multiplied(by: fraction.left).divided(by: fraction.right)
        return try left.sourceTime.adding(scaled)
    }
}

public extension Clip {
    /// Validates FR-SPD-002 clip-level time-remap invariants.
    ///
    /// Composition policy: a time-remap curve fully determines the timeline-to-source map, so
    /// it is rejected alongside `reverse`, `freezeFrame`, or a non-unit constant `speed` rather
    /// than silently composing. Freezes are zero-slope segments and constant rates are two-point
    /// linear curves, so the curve subsumes those retimes for forward playback.
    func validateTimeRemap() -> ClipTimeRemapValidationError? {
        guard let timeRemap else {
            return nil
        }
        if reverse || freezeFrame || speed != .one {
            return .conflictingRetime(reverse: reverse, freezeFrame: freezeFrame, speed: speed)
        }
        if timeRemap.duration != timelineRange.duration {
            return .curveDurationMismatch(
                curveDuration: timeRemap.duration,
                timelineDuration: timelineRange.duration
            )
        }
        if timeRemap.sourceStart < sourceRange.start {
            return .sourceTimeOutOfBounds(
                sourceTime: timeRemap.sourceStart,
                sourceRange: sourceRange
            )
        }
        do {
            let sourceEnd = try sourceRange.end()
            if timeRemap.sourceEnd > sourceEnd {
                return .sourceTimeOutOfBounds(
                    sourceTime: timeRemap.sourceEnd,
                    sourceRange: sourceRange
                )
            }
        } catch let error as RationalTimeError {
            return .timeArithmetic(error)
        } catch {
            return .timeArithmetic(.arithmeticOverflow)
        }
        return nil
    }
}
