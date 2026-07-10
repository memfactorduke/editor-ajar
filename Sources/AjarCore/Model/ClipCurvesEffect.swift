// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Limits for FR-COL-002 RGB master + per-channel color curves (M8 scope).
public enum ColorCurveLimits {
    /// Minimum control points on a curve (endpoints only).
    public static let minimumPointCount = 2

    /// Maximum control points on a curve (UI / payload ceiling).
    public static let maximumPointCount = 16

    /// CPU-baked 1D ramp length uploaded to the GPU (parameter-change only; no per-frame bake).
    public static let rampSampleCount = 256
}

/// One ordered control point on a color curve in normalized 0...1 space.
///
/// **M8:** control points are static on the node (not keyframed). Keyframable master
/// strength lives on ``ClipCurvesEffectParameters/strength``.
public struct ColorCurveControlPoint: Codable, Equatable, Sendable {
    /// Horizontal position (input value), valid 0...1. Points on a curve must be strictly
    /// increasing in `x`.
    public let x: Float

    /// Vertical position (output value), valid 0...1.
    public let y: Float

    /// Creates a control point.
    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

/// An ordered RGB transfer curve: 2…16 control points with strictly increasing `x`.
///
/// Interpolation is **Fritsch–Carlson monotone cubic** Hermite, evaluated on the CPU when
/// baking a 256-entry ramp (never on the playback hot path).
public struct ColorCurve: Codable, Equatable, Sendable {
    /// Ordered control points (first typically at x=0, last at x=1 — not required, but
    /// evaluation clamps outside the endpoint abscissae).
    public let points: [ColorCurveControlPoint]

    private enum CodingKeys: String, CodingKey {
        case points
    }

    /// Identity curve: (0,0) → (1,1). Bakes to a bit-exact linear ramp.
    public static let identity = ColorCurve(
        points: [
            ColorCurveControlPoint(x: 0, y: 0),
            ColorCurveControlPoint(x: 1, y: 1)
        ]
    )

    /// Creates a curve. Callers should validate via ``ColorCurve/validated()`` before
    /// attaching the curve to a project node.
    public init(points: [ColorCurveControlPoint]) {
        self.points = points
    }

    /// Decodes points, defaulting a missing array to the identity curve (legacy-safe).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points =
            try container.decodeIfPresent([ColorCurveControlPoint].self, forKey: .points)
            ?? ColorCurve.identity.points
    }

    /// Whether this is the structural identity pair (0,0)/(1,1).
    public var isStructuralIdentity: Bool {
        points.count == 2
            && points[0].x == 0 && points[0].y == 0
            && points[1].x == 1 && points[1].y == 1
    }

    /// Typed validation: point count, unit range, strictly increasing `x`.
    public func validated() -> Result<ColorCurve, ColorCurveValidationError> {
        let count = points.count
        guard count >= ColorCurveLimits.minimumPointCount,
            count <= ColorCurveLimits.maximumPointCount
        else {
            return .failure(.pointCountOutOfRange(count))
        }
        for (index, point) in points.enumerated() {
            // NaN / ±inf fail every range comparison; reject with the typed unit-range error.
            let outOfUnit =
                !point.x.isFinite || !point.y.isFinite
                || point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1
            if outOfUnit {
                return .failure(.pointOutOfUnitRange(index: index, point: point))
            }
            if index > 0 {
                let previous = points[index - 1]
                if point.x <= previous.x {
                    return .failure(
                        .xNotStrictlyIncreasing(index: index, previousX: previous.x, x: point.x)
                    )
                }
            }
        }
        return .success(self)
    }

    /// Evaluates the monotone cubic at `input` (clamped to the endpoint abscissae).
    ///
    /// Structural identity returns `input` bit-exactly (no Hermite float noise).
    public func evaluate(at input: Float) -> Float {
        if isStructuralIdentity {
            return input
        }
        guard case .success = validated() else {
            return input
        }
        return ColorCurveInterpolator.evaluate(points: points, at: input)
    }

    /// Bakes a 256-entry ramp for GPU upload (CPU only, on parameter change).
    ///
    /// Structural identity ramps are exact `i / (N-1)` floats (bit-identical passthrough path).
    public func bakeRamp(sampleCount: Int = ColorCurveLimits.rampSampleCount) -> [Float] {
        let count = max(sampleCount, 2)
        var ramp = [Float](repeating: 0, count: count)
        let denom = Float(count - 1)
        if isStructuralIdentity {
            for index in 0..<count {
                ramp[index] = Float(index) / denom
            }
            return ramp
        }
        for index in 0..<count {
            let t = Float(index) / denom
            ramp[index] = evaluate(at: t)
        }
        return ramp
    }

    /// Stable digest of control points (GPU texture cache + render-graph content hash).
    public var contentDigest: ContentHash {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(points.count * 8)
        for point in points {
            Self.appendFloatBits(point.x, to: &bytes)
            Self.appendFloatBits(point.y, to: &bytes)
        }
        return ContentHash.sha256(bytes: bytes)
    }

    private static func appendFloatBits(_ value: Float, to bytes: inout [UInt8]) {
        var bitPattern = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bitPattern) { buffer in
            bytes.append(contentsOf: buffer)
        }
    }
}

/// Which channel a curve validation error refers to.
public enum ColorCurveChannel: String, Equatable, Sendable {
    case rgb
    case red
    case green
    case blue
}

/// Typed validation failures for a single color curve (FR-COL-002).
public enum ColorCurveValidationError: Error, Equatable, Sendable {
    /// Point count is outside 2...16.
    case pointCountOutOfRange(Int)

    /// A control point coordinate is outside 0...1.
    case pointOutOfUnitRange(index: Int, point: ColorCurveControlPoint)

    /// Control-point `x` values are not strictly increasing.
    case xNotStrictlyIncreasing(index: Int, previousX: Float, x: Float)

    /// Clear diagnostic for callers and tests.
    public var message: String {
        switch self {
        case .pointCountOutOfRange(let count):
            return
                "color curve has \(count) points; valid range is "
                + "\(ColorCurveLimits.minimumPointCount)...\(ColorCurveLimits.maximumPointCount)"
        case .pointOutOfUnitRange(let index, let point):
            return
                "color curve point[\(index)]=(\(point.x),\(point.y)) is outside unit range 0...1"
        case .xNotStrictlyIncreasing(let index, let previousX, let x):
            return
                "color curve point[\(index)].x=\(x) is not strictly greater than previous x="
                + "\(previousX)"
        }
    }
}

// MARK: - Fritsch–Carlson monotone cubic

/// CPU-only monotone cubic Hermite interpolator (Fritsch–Carlson).
enum ColorCurveInterpolator {
    static func evaluate(points: [ColorCurveControlPoint], at input: Float) -> Float {
        let count = points.count
        guard count >= 2 else {
            return input
        }
        let first = points[0]
        let last = points[count - 1]
        if input <= first.x {
            return first.y
        }
        if input >= last.x {
            return last.y
        }

        let slopes = monotoneSlopes(points: points)
        var segment = 0
        while segment < count - 2 && input > points[segment + 1].x {
            segment += 1
        }
        let left = points[segment]
        let right = points[segment + 1]
        let span = right.x - left.x
        guard span > 0 else {
            return left.y
        }
        let t = (input - left.x) / span
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * left.y + h10 * span * slopes[segment] + h01 * right.y + h11 * span
            * slopes[segment + 1]
    }

    /// Fritsch–Carlson slopes at each control point.
    static func monotoneSlopes(points: [ColorCurveControlPoint]) -> [Float] {
        let pointCount = points.count
        guard pointCount >= 2 else {
            return []
        }
        var delta = [Float](repeating: 0, count: pointCount - 1)
        for index in 0..<(pointCount - 1) {
            let span = points[index + 1].x - points[index].x
            delta[index] = span > 0 ? (points[index + 1].y - points[index].y) / span : 0
        }

        var slopes = [Float](repeating: 0, count: pointCount)
        slopes[0] = delta[0]
        slopes[pointCount - 1] = delta[pointCount - 2]
        if pointCount > 2 {
            for index in 1..<(pointCount - 1) {
                if delta[index - 1] * delta[index] <= 0 {
                    slopes[index] = 0
                } else {
                    slopes[index] = (delta[index - 1] + delta[index]) * 0.5
                }
            }
        }

        for index in 0..<(pointCount - 1) {
            if abs(delta[index]) < 1.0e-12 {
                slopes[index] = 0
                slopes[index + 1] = 0
                continue
            }
            let alpha = slopes[index] / delta[index]
            let beta = slopes[index + 1] / delta[index]
            let sumSquares = alpha * alpha + beta * beta
            if sumSquares > 9 {
                let tau = 3 / sumSquares.squareRoot()
                slopes[index] = tau * alpha * delta[index]
                slopes[index + 1] = tau * beta * delta[index]
            }
        }
        return slopes
    }
}

// MARK: - Effect parameters

/// CPU-baked 256-entry ramps for the four FR-COL-002 curves (RGBA texture pack order).
public struct ColorCurvePackedRamps: Equatable, Sendable {
    /// RGB master curve ramp (stored in texture alpha).
    public let rgb: [Float]
    /// Red channel ramp (texture R).
    public let red: [Float]
    /// Green channel ramp (texture G).
    public let green: [Float]
    /// Blue channel ramp (texture B).
    public let blue: [Float]
}

/// Static parameters for the FR-COL-002 `curves` effect kind (M8: RGB master + R/G/B).
///
/// Secondary curves (hue-vs-hue, hue-vs-sat, luma-vs-sat) remain v1.x per SPEC.
/// Control points are **static** for M8; ``strength`` is keyframable 0…1.
public struct ClipCurvesEffectParameters: Codable, Equatable, Sendable {
    /// RGB master curve applied to all channels before per-channel curves.
    public let rgb: ColorCurve

    /// Per-channel red curve (after the RGB master).
    public let red: ColorCurve

    /// Per-channel green curve (after the RGB master).
    public let green: ColorCurve

    /// Per-channel blue curve (after the RGB master).
    public let blue: ColorCurve

    /// Mix strength in 0...1: `mix(identity, curved, strength)`. Zero is a no-op skip.
    public let strength: RationalValue

    private enum CodingKeys: String, CodingKey {
        case rgb
        case red
        case green
        case blue
        case strength
    }

    /// Neutral curves with full strength.
    public static let identity = ClipCurvesEffectParameters()

    /// Creates curves parameters. Curves default to identity; strength defaults to full.
    public init(
        rgb: ColorCurve = .identity,
        red: ColorCurve = .identity,
        green: ColorCurve = .identity,
        blue: ColorCurve = .identity,
        strength: RationalValue = .one
    ) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
        self.strength = strength
    }

    /// Decodes with legacy-safe per-field defaults (identity curves, strength 1).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try container.decodeIfPresent(ColorCurve.self, forKey: .rgb) ?? .identity
        red = try container.decodeIfPresent(ColorCurve.self, forKey: .red) ?? .identity
        green = try container.decodeIfPresent(ColorCurve.self, forKey: .green) ?? .identity
        blue = try container.decodeIfPresent(ColorCurve.self, forKey: .blue) ?? .identity
        strength = try container.decodeIfPresent(RationalValue.self, forKey: .strength) ?? .one
    }

    /// Whether every curve is structural identity (GPU may skip when strength is also zero).
    public var isStructuralIdentityCurves: Bool {
        rgb.isStructuralIdentity
            && red.isStructuralIdentity
            && green.isStructuralIdentity
            && blue.isStructuralIdentity
    }

    /// Composite digest of all four curves for GPU ramp-texture caching.
    public var rampContentDigest: ContentHash {
        var bytes: [UInt8] = []
        for digest in [
            rgb.contentDigest.digest, red.contentDigest.digest, green.contentDigest.digest,
            blue.contentDigest.digest
        ] {
            bytes.append(contentsOf: Array(digest.utf8))
            bytes.append(0)
        }
        return ContentHash.sha256(bytes: bytes)
    }

    /// Bakes four 256-entry ramps for a single RGBA 1D upload.
    public func bakePackedRamp() -> ColorCurvePackedRamps {
        ColorCurvePackedRamps(
            rgb: rgb.bakeRamp(),
            red: red.bakeRamp(),
            green: green.bakeRamp(),
            blue: blue.bakeRamp()
        )
    }
}

/// Keyframable parameters for the FR-COL-002 `curves` effect kind.
///
/// Curves are constant on the node (M8). Strength is keyframable.
public struct AnimatableClipCurvesSettings: Codable, Equatable, Sendable {
    /// Constant RGB master curve (applied to all channels first).
    public let rgb: ColorCurve

    /// Constant red curve.
    public let red: ColorCurve

    /// Constant green curve.
    public let green: ColorCurve

    /// Constant blue curve.
    public let blue: ColorCurve

    /// Keyframable mix strength in 0...1.
    public let strength: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case rgb
        case red
        case green
        case blue
        case strength
    }

    /// Neutral constant curves at full strength.
    public static let identity = AnimatableClipCurvesSettings()

    /// Creates keyframable curves parameters.
    public init(
        rgb: ColorCurve = .identity,
        red: ColorCurve = .identity,
        green: ColorCurve = .identity,
        blue: ColorCurve = .identity,
        strength: Animatable<RationalValue> = .constant(.one)
    ) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
        self.strength = strength
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try container.decodeIfPresent(ColorCurve.self, forKey: .rgb) ?? .identity
        red = try container.decodeIfPresent(ColorCurve.self, forKey: .red) ?? .identity
        green = try container.decodeIfPresent(ColorCurve.self, forKey: .green) ?? .identity
        blue = try container.decodeIfPresent(ColorCurve.self, forKey: .blue) ?? .identity
        strength =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .strength
            ) ?? .constant(.one)
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipCurvesEffectParameters
    ) -> AnimatableClipCurvesSettings {
        AnimatableClipCurvesSettings(
            rgb: parameters.rgb,
            red: parameters.red,
            green: parameters.green,
            blue: parameters.blue,
            strength: .constant(parameters.strength)
        )
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipCurvesEffectParameters {
        ClipCurvesEffectParameters(
            rgb: rgb,
            red: red,
            green: green,
            blue: blue,
            strength: strength.value(at: time)
        )
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipCurvesEffectParameters {
        ClipCurvesEffectParameters(
            rgb: rgb,
            red: red,
            green: green,
            blue: blue,
            strength: strength.base
        )
    }
}

// MARK: - Representative fixtures (tests / goldens / benches)

extension ColorCurve {
    /// Classic contrast S-curve for RGB-master discrimination and goldens.
    public static let rgbSCurve = ColorCurve(
        points: [
            ColorCurveControlPoint(x: 0, y: 0),
            ColorCurveControlPoint(x: 0.25, y: 0.15),
            ColorCurveControlPoint(x: 0.75, y: 0.85),
            ColorCurveControlPoint(x: 1, y: 1)
        ]
    )

    /// Red-channel lift in the low mid-tones (per-channel golden / discrimination).
    public static let redLift = ColorCurve(
        points: [
            ColorCurveControlPoint(x: 0, y: 0.12),
            ColorCurveControlPoint(x: 0.5, y: 0.55),
            ColorCurveControlPoint(x: 1, y: 1)
        ]
    )
}
