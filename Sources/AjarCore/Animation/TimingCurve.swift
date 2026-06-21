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
