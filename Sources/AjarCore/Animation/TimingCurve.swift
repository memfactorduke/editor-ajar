// SPDX-License-Identifier: GPL-3.0-or-later

/// A normalized 2D control point for cubic Bezier timing curves.
public struct CubicBezierTimingControlPoint: Codable, Equatable, Sendable {
    /// Horizontal timing coordinate. Values between `0` and `1` keep the curve monotonic.
    public let x: RationalValue

    /// Vertical progress coordinate.
    public let y: RationalValue

    /// Creates a cubic Bezier timing control point.
    public init(x: RationalValue, y: RationalValue) {
        self.x = x
        self.y = y
    }
}

/// Cubic Bezier timing curve from `(0, 0)` to `(1, 1)`.
public struct CubicBezierTimingCurve: Codable, Equatable, Sendable {
    /// First control point.
    public let controlPoint1: CubicBezierTimingControlPoint

    /// Second control point.
    public let controlPoint2: CubicBezierTimingControlPoint

    /// Linear cubic Bezier timing.
    public static let linear = CubicBezierTimingCurve(
        controlPoint1: CubicBezierTimingControlPoint(x: .zero, y: .zero),
        controlPoint2: CubicBezierTimingControlPoint(x: .one, y: .one)
    )

    /// CSS-style ease-in timing.
    public static let easeIn = CubicBezierTimingCurve(
        controlPoint1: CubicBezierTimingControlPoint(
            x: RationalValue.approximating(0.42),
            y: .zero
        ),
        controlPoint2: CubicBezierTimingControlPoint(x: .one, y: .one)
    )

    /// CSS-style ease-out timing.
    public static let easeOut = CubicBezierTimingCurve(
        controlPoint1: CubicBezierTimingControlPoint(x: .zero, y: .zero),
        controlPoint2: CubicBezierTimingControlPoint(
            x: RationalValue.approximating(0.58),
            y: .one
        )
    )

    /// CSS-style ease-in-out timing.
    public static let easeInOut = CubicBezierTimingCurve(
        controlPoint1: CubicBezierTimingControlPoint(
            x: RationalValue.approximating(0.42),
            y: .zero
        ),
        controlPoint2: CubicBezierTimingControlPoint(
            x: RationalValue.approximating(0.58),
            y: .one
        )
    )

    /// Creates a cubic Bezier timing curve.
    public init(
        controlPoint1: CubicBezierTimingControlPoint,
        controlPoint2: CubicBezierTimingControlPoint
    ) {
        self.controlPoint1 = controlPoint1
        self.controlPoint2 = controlPoint2
    }

    /// Returns the progress value for the given normalized time fraction.
    public func value(at fraction: Double) -> Double {
        let targetX = Self.clamp01(fraction)
        var lower = 0.0
        var upper = 1.0
        var parameter = targetX

        for _ in 0..<40 {
            parameter = (lower + upper) / 2
            if sampleX(at: parameter) < targetX {
                lower = parameter
            } else {
                upper = parameter
            }
        }

        return sampleY(at: parameter)
    }

    private func sampleX(at parameter: Double) -> Double {
        Self.sample(
            at: parameter,
            firstControl: controlPoint1.x.doubleValue,
            secondControl: controlPoint2.x.doubleValue
        )
    }

    private func sampleY(at parameter: Double) -> Double {
        Self.sample(
            at: parameter,
            firstControl: controlPoint1.y.doubleValue,
            secondControl: controlPoint2.y.doubleValue
        )
    }

    private static func sample(
        at parameter: Double,
        firstControl: Double,
        secondControl: Double
    ) -> Double {
        let inverse = 1 - parameter
        let firstTerm = 3 * inverse * inverse * parameter * firstControl
        let secondTerm = 3 * inverse * parameter * parameter * secondControl
        let finalTerm = parameter * parameter * parameter
        return firstTerm + secondTerm + finalTerm
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// The two renormalized halves of a timing curve subdivided at a horizontal fraction.
///
/// A `nil` half means that half's renormalization is division-degenerate: the split point
/// sits on that half's far corner in x or y — for y, the curve's progress at the split
/// equals that endpoint's progress, which happens when an overshooting curve returns to an
/// endpoint progress exactly at the cut. Overshoot alone (progress outside `[0, 1]` at the
/// split point) is not degenerate; the affine renormalization stays exact for it.
struct SubdividedTimingCurve {
    /// The renormalized left half, or `nil` when its renormalization is degenerate.
    let left: CubicBezierTimingCurve?

    /// The renormalized right half, or `nil` when its renormalization is degenerate.
    let right: CubicBezierTimingCurve?
}

extension CubicBezierTimingCurve {
    /// Splits the timing curve at the horizontal (linear-time) `fraction` and renormalizes
    /// both halves back to unit curves, so evaluating the left half over `[0, fraction]` and
    /// the right half over `[fraction, 1]` reproduces the original easing. Blade edits use
    /// this to keep a keyframed segment's shape unchanged across the cut (FR-XFORM-008).
    ///
    /// De Casteljau subdivision is exact for any control points, including overshooting y
    /// values; only a vanishing renormalization denominator makes a half unavailable (see
    /// `SubdividedTimingCurve`). Fractions at or outside the endpoints yield no halves.
    func subdivided(atFraction fraction: Double) -> SubdividedTimingCurve {
        guard fraction > 0, fraction < 1 else {
            return SubdividedTimingCurve(left: nil, right: nil)
        }
        let parameter = curveParameter(forX: fraction)
        let control1 = BezierCurvePoint(
            x: controlPoint1.x.doubleValue,
            y: controlPoint1.y.doubleValue
        )
        let control2 = BezierCurvePoint(
            x: controlPoint2.x.doubleValue,
            y: controlPoint2.y.doubleValue
        )
        // De Casteljau subdivision of ((0,0), control1, control2, (1,1)) at `parameter`.
        let firstLeg = BezierCurvePoint.zero.lerp(to: control1, at: parameter)
        let middleLeg = control1.lerp(to: control2, at: parameter)
        let lastLeg = control2.lerp(to: .one, at: parameter)
        let leftInner = firstLeg.lerp(to: middleLeg, at: parameter)
        let rightInner = middleLeg.lerp(to: lastLeg, at: parameter)
        let split = leftInner.lerp(to: rightInner, at: parameter)
        let epsilon = 1e-9
        var left: CubicBezierTimingCurve?
        if split.x > epsilon, abs(split.y) > epsilon {
            left = CubicBezierTimingCurve(
                controlPoint1: firstLeg.normalizedToward(split).controlPoint,
                controlPoint2: leftInner.normalizedToward(split).controlPoint
            )
        }
        var right: CubicBezierTimingCurve?
        if split.x < 1 - epsilon, abs(1 - split.y) > epsilon {
            right = CubicBezierTimingCurve(
                controlPoint1: rightInner.normalizedFrom(split).controlPoint,
                controlPoint2: lastLeg.normalizedFrom(split).controlPoint
            )
        }
        return SubdividedTimingCurve(left: left, right: right)
    }

    /// The Bezier parameter whose horizontal coordinate matches `targetX`, found with the
    /// same 40-step bisection as `value(at:)`.
    private func curveParameter(forX targetX: Double) -> Double {
        var lower = 0.0
        var upper = 1.0
        var parameter = targetX

        for _ in 0..<40 {
            parameter = (lower + upper) / 2
            if sampleX(at: parameter) < targetX {
                lower = parameter
            } else {
                upper = parameter
            }
        }

        return parameter
    }
}

/// Double-precision point used by De Casteljau subdivision.
private struct BezierCurvePoint {
    let x: Double
    let y: Double

    static let zero = BezierCurvePoint(x: 0, y: 0)
    static let one = BezierCurvePoint(x: 1, y: 1)

    func lerp(to other: BezierCurvePoint, at parameter: Double) -> BezierCurvePoint {
        BezierCurvePoint(
            x: x + ((other.x - x) * parameter),
            y: y + ((other.y - y) * parameter)
        )
    }

    /// Rescales a left-half point from `[(0,0), split]` onto the unit square.
    func normalizedToward(_ split: BezierCurvePoint) -> BezierCurvePoint {
        BezierCurvePoint(x: x / split.x, y: y / split.y)
    }

    /// Rescales a right-half point from `[split, (1,1)]` onto the unit square.
    func normalizedFrom(_ split: BezierCurvePoint) -> BezierCurvePoint {
        BezierCurvePoint(x: (x - split.x) / (1 - split.x), y: (y - split.y) / (1 - split.y))
    }

    var controlPoint: CubicBezierTimingControlPoint {
        CubicBezierTimingControlPoint(
            x: RationalValue.approximating(x),
            y: RationalValue.approximating(y)
        )
    }
}
