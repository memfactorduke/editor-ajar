// SPDX-License-Identifier: GPL-3.0-or-later

/// Interpolation modes available for a keyframe segment in M1.
///
/// The segment beginning at a keyframe uses that keyframe's mode. M4 will expand this model with
/// ease and Bezier curve modes alongside the curve editor.
public enum InterpolationMode: String, Codable, Equatable, Sendable {
    /// Keep the left keyframe value until the next keyframe is reached.
    case hold

    /// Linearly interpolate between the left and right keyframe values.
    case linear
}

/// A value that can be linearly interpolated for keyframe evaluation.
public protocol Interpolatable {
    /// Returns the value at `fraction` between `self` and `target`.
    func lerp(to target: Self, fraction: Double) -> Self
}

extension Double: Interpolatable {
    /// Returns the linearly interpolated `Double` at `fraction` between `self` and `target`.
    public func lerp(to target: Double, fraction: Double) -> Double {
        self + ((target - self) * fraction)
    }
}

/// A single keyframe on an animatable parameter.
public struct Keyframe<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    /// The exact timeline time for this keyframe.
    public let time: RationalTime

    /// The parameter value at `time`.
    public let value: Value

    /// The interpolation mode for the segment from this keyframe to the next keyframe.
    public let interpolation: InterpolationMode

    /// Creates a keyframe value.
    public init(time: RationalTime, value: Value, interpolation: InterpolationMode) {
        self.time = time
        self.value = value
        self.interpolation = interpolation
    }
}

/// Typed validation errors for `Animatable` construction.
public enum AnimatableValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Keyframes were not provided in ascending time order.
    case keyframesNotSorted(
        previousIndex: Int,
        index: Int,
        previousTime: RationalTime,
        time: RationalTime
    )

    /// Two keyframes use the same exact time.
    case duplicateKeyframeTime(previousIndex: Int, index: Int, time: RationalTime)

    /// A human-readable description of the validation failure.
    public var description: String {
        switch self {
        case .keyframesNotSorted(let previousIndex, let index, let previousTime, let time):
            "keyframe \(index) at \(time) must be later than keyframe \(previousIndex) "
                + "at \(previousTime)"
        case .duplicateKeyframeTime(let previousIndex, let index, let time):
            "keyframe \(index) duplicates keyframe \(previousIndex) at \(time)"
        }
    }
}

/// Result of validating animatable keyframe invariants.
public enum AnimatableValidationResult: Equatable, Sendable {
    /// The keyframes satisfy the ordering invariants.
    case valid

    /// The keyframes failed validation with a typed error.
    case invalid(AnimatableValidationError)

    /// Whether the validation result is valid.
    public var isValid: Bool {
        self == .valid
    }
}

/// An animatable parameter with a base value and sorted keyframes.
public struct Animatable<
    Value: Codable & Equatable & Sendable & Interpolatable
>: Codable, Equatable, Sendable {
    /// The value used when no keyframes are present.
    public let base: Value

    /// Keyframes in strictly ascending time order.
    public let keyframes: [Keyframe<Value>]

    /// Creates an animatable parameter after validating the keyframe ordering invariant.
    public init(base: Value, keyframes: [Keyframe<Value>] = []) throws {
        switch Self.validate(keyframes: keyframes) {
        case .valid:
            break
        case .invalid(let error):
            throw error
        }

        self.base = base
        self.keyframes = keyframes
    }

    /// Validates the strict time-order invariant shared by construction and tests.
    public static func validate(keyframes: [Keyframe<Value>]) -> AnimatableValidationResult {
        guard keyframes.count > 1 else {
            return .valid
        }

        var previousIndex = keyframes.startIndex
        for index in keyframes.indices.dropFirst() {
            let previous = keyframes[previousIndex]
            let current = keyframes[index]

            if current.time == previous.time {
                return .invalid(
                    .duplicateKeyframeTime(
                        previousIndex: previousIndex,
                        index: index,
                        time: current.time
                    )
                )
            }

            if current.time < previous.time {
                return .invalid(
                    .keyframesNotSorted(
                        previousIndex: previousIndex,
                        index: index,
                        previousTime: previous.time,
                        time: current.time
                    )
                )
            }

            previousIndex = index
        }

        return .valid
    }

    /// Evaluates the parameter at an exact timeline time.
    public func value(at time: RationalTime) -> Value {
        guard let first = keyframes.first else {
            return base
        }

        if time <= first.time {
            return first.value
        }

        guard let last = keyframes.last else {
            return base
        }

        if time >= last.time {
            return last.value
        }

        var left = first
        for index in keyframes.indices.dropFirst() {
            let right = keyframes[index]
            if time < right.time {
                return value(at: time, left: left, right: right)
            }
            left = right
        }

        return last.value
    }

    private func value(
        at time: RationalTime,
        left: Keyframe<Value>,
        right: Keyframe<Value>
    ) -> Value {
        switch left.interpolation {
        case .hold:
            left.value
        case .linear:
            left.value.lerp(
                to: right.value,
                fraction: Self.interpolationFraction(
                    at: time,
                    leftTime: left.time,
                    rightTime: right.time
                )
            )
        }
    }

    private static func interpolationFraction(
        at time: RationalTime,
        leftTime: RationalTime,
        rightTime: RationalTime
    ) -> Double {
        do {
            let elapsed = try time.subtracting(leftTime)
            let duration = try rightTime.subtracting(leftTime)
            let common = try elapsed.valuesAtCommonTimescale(with: duration)
            guard common.right != 0 else {
                return 0
            }
            return Double(common.left) / Double(common.right)
        } catch {
            return fallbackFraction(at: time, leftTime: leftTime, rightTime: rightTime)
        }
    }

    private static func fallbackFraction(
        at time: RationalTime,
        leftTime: RationalTime,
        rightTime: RationalTime
    ) -> Double {
        let elapsed = distanceInSeconds(from: leftTime, to: time)
        let duration = distanceInSeconds(from: leftTime, to: rightTime)
        guard duration != 0 else {
            return 0
        }
        return elapsed / duration
    }

    private static func distanceInSeconds(
        from start: RationalTime,
        to end: RationalTime
    ) -> Double {
        let endValue = Double(end.value) * Double(start.timescale)
        let startValue = Double(start.value) * Double(end.timescale)
        let denominator = Double(end.timescale) * Double(start.timescale)
        return (endValue - startValue) / denominator
    }
}
