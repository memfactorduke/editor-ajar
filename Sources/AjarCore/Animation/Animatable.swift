// SPDX-License-Identifier: GPL-3.0-or-later

/// Interpolation modes available for a keyframe segment.
///
/// The segment beginning at a keyframe uses that keyframe's mode.
public enum InterpolationMode: Codable, Equatable, Sendable {
    /// Keep the left keyframe value until the next keyframe is reached.
    case hold

    /// Linearly interpolate between the left and right keyframe values.
    case linear

    /// Ease slowly out of the left keyframe.
    case easeIn

    /// Ease slowly into the right keyframe.
    case easeOut

    /// Ease at both ends of the segment.
    case easeInOut

    /// Custom cubic Bezier timing.
    case bezier(CubicBezierTimingCurve)

    private enum CodingKeys: String, CodingKey {
        case kind
        case curve
    }

    /// Decodes legacy string modes and current structured Bezier modes.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            switch value {
            case "hold":
                self = .hold
            case "linear":
                self = .linear
            case "easeIn":
                self = .easeIn
            case "easeOut":
                self = .easeOut
            case "easeInOut":
                self = .easeInOut
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown interpolation mode \(value)"
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "bezier":
            self = .bezier(try container.decode(CubicBezierTimingCurve.self, forKey: .curve))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown interpolation mode \(kind)"
            )
        }
    }

    /// Encodes built-in modes as legacy strings and custom Bezier modes as structured values.
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .hold:
            var container = encoder.singleValueContainer()
            try container.encode("hold")
        case .linear:
            var container = encoder.singleValueContainer()
            try container.encode("linear")
        case .easeIn:
            var container = encoder.singleValueContainer()
            try container.encode("easeIn")
        case .easeOut:
            var container = encoder.singleValueContainer()
            try container.encode("easeOut")
        case .easeInOut:
            var container = encoder.singleValueContainer()
            try container.encode("easeInOut")
        case .bezier(let curve):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("bezier", forKey: .kind)
            try container.encode(curve, forKey: .curve)
        }
    }

    func timingFraction(for linearFraction: Double) -> Double {
        switch self {
        case .hold:
            0
        case .linear:
            linearFraction
        case .easeIn:
            CubicBezierTimingCurve.easeIn.value(at: linearFraction)
        case .easeOut:
            CubicBezierTimingCurve.easeOut.value(at: linearFraction)
        case .easeInOut:
            CubicBezierTimingCurve.easeInOut.value(at: linearFraction)
        case .bezier(let curve):
            curve.value(at: linearFraction)
        }
    }
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

    private enum CodingKeys: String, CodingKey {
        case base
        case keyframes
    }

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

    /// Decodes and validates keyframe ordering.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            base: container.decode(Value.self, forKey: .base),
            keyframes: container.decode([Keyframe<Value>].self, forKey: .keyframes)
        )
    }

    /// Encodes the animatable parameter.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(base, forKey: .base)
        try container.encode(keyframes, forKey: .keyframes)
    }

    /// Creates a constant animatable parameter.
    public static func constant(_ value: Value) -> Animatable<Value> {
        Animatable(base: value, validatedKeyframes: [])
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
            return left.value
        case .linear, .easeIn, .easeOut, .easeInOut, .bezier:
            let fraction = Self.interpolationFraction(
                at: time,
                leftTime: left.time,
                rightTime: right.time
            )
            return left.value.lerp(
                to: right.value,
                fraction: left.interpolation.timingFraction(for: fraction)
            )
        }
    }

    private init(base: Value, validatedKeyframes keyframes: [Keyframe<Value>]) {
        self.base = base
        self.keyframes = keyframes
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

extension RationalValue {
    /// Approximate `Double` representation used by interpolation and GPU uniform conversion.
    public var doubleValue: Double {
        Double(numerator) / Double(denominator)
    }

    /// Creates a stable rational approximation for non-time interpolated model values.
    public static func approximating(_ value: Double) -> RationalValue {
        guard value.isFinite else {
            return .zero
        }

        let denominator: Int64 = 1_000_000
        let scaled = value * Double(denominator)
        guard scaled >= Double(Int64.min), scaled <= Double(Int64.max) else {
            return value < 0
                ? RationalValue(Int64.min / denominator)
                : RationalValue(Int64.max / denominator)
        }

        let numerator = Int64(scaled.rounded())
        return (try? RationalValue(numerator: numerator, denominator: denominator)) ?? .zero
    }
}

extension RationalValue: Interpolatable {
    /// Returns the linearly interpolated rational approximation.
    public func lerp(to target: RationalValue, fraction: Double) -> RationalValue {
        RationalValue.approximating(doubleValue + ((target.doubleValue - doubleValue) * fraction))
    }
}
