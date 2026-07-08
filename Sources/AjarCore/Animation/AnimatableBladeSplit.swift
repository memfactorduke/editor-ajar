// SPDX-License-Identifier: GPL-3.0-or-later

extension InterpolationMode {
    /// The cubic Bezier timing curve behind an eased mode; `nil` for `hold` and `linear`.
    var easingCurve: CubicBezierTimingCurve? {
        switch self {
        case .hold, .linear:
            nil
        case .easeIn:
            .easeIn
        case .easeOut:
            .easeOut
        case .easeInOut:
            .easeInOut
        case .bezier(let curve):
            curve
        }
    }
}

extension Animatable {
    /// Splits the keyframe list at the absolute timeline `cut` for a blade edit
    /// (FR-XFORM-008): each half keeps the keyframes on its own side plus a shared boundary
    /// keyframe evaluated at the cut, and the segment crossing the cut has its easing
    /// subdivided, so evaluating the left half before the cut and the right half from the
    /// cut reproduces the original animation. Overshooting Bezier easings subdivide exactly
    /// too; when a renormalization denominator vanishes (the overshoot returns to an
    /// endpoint progress exactly at the cut) an interior keyframe is baked so the split
    /// stays exact instead of falling back to an approximation.
    ///
    /// The left half's boundary keyframe sits exactly at its exclusive timeline end — the
    /// end is never sampled, but the keyframe shapes the approach into the cut (project
    /// validation accepts end-of-range keyframes for exactly this reason).
    func bladed(
        at cut: RationalTime
    ) throws -> (left: Animatable<Value>, right: Animatable<Value>) {
        guard !keyframes.isEmpty else {
            return (self, self)
        }
        var leftKeyframes = keyframes.filter { keyframe in keyframe.time < cut }
        var rightKeyframes = keyframes.filter { keyframe in keyframe.time > cut }
        let exact = keyframes.first { keyframe in keyframe.time == cut }
        var boundary = exact
            ?? Keyframe(time: cut, value: value(at: cut), interpolation: .hold)
        var rightExtras: [Keyframe<Value>] = []
        if exact == nil,
           let crossingLeft = leftKeyframes.last,
           let crossingRight = rightKeyframes.first {
            // The cut lands strictly inside the segment crossingLeft → crossingRight:
            // split its easing so both sub-segments retrace the original curve.
            let segment = BladeSegment(
                start: crossingLeft,
                endTime: crossingRight.time,
                endValue: crossingRight.value
            )
            let split = try Self.splitSegment(segment, at: cut, interiorSplitBudget: 1)
            leftKeyframes[leftKeyframes.count - 1] = Keyframe(
                time: crossingLeft.time,
                value: crossingLeft.value,
                interpolation: split.startInterpolation
            )
            leftKeyframes += split.leftExtras
            boundary = split.boundary
            rightExtras = split.rightExtras
        }
        leftKeyframes.append(boundary)
        rightKeyframes.insert(contentsOf: [boundary] + rightExtras, at: 0)
        return (
            left: try Animatable(base: base, keyframes: leftKeyframes),
            right: try Animatable(base: base, keyframes: rightKeyframes)
        )
    }

    /// The crossing segment being bladed: its start keyframe and end point.
    private struct BladeSegment {
        let start: Keyframe<Value>
        let endTime: RationalTime
        let endValue: Value
    }

    /// One crossing-segment split into exact halves. Interior keyframes appear only when a
    /// degenerate renormalization forces an extra bake point on that side of the cut.
    private struct SegmentSplit {
        let startInterpolation: InterpolationMode
        let leftExtras: [Keyframe<Value>]
        let boundary: Keyframe<Value>
        let rightExtras: [Keyframe<Value>]
    }

    /// Splits `segment` at `cut` (strictly inside it).
    private static func splitSegment(
        _ segment: BladeSegment,
        at cut: RationalTime,
        interiorSplitBudget: Int
    ) throws -> SegmentSplit {
        let fraction = try bladeFraction(
            of: cut,
            from: segment.start.time,
            to: segment.endTime
        )
        guard let curve = segment.start.interpolation.easingCurve else {
            if case .hold = segment.start.interpolation {
                return SegmentSplit(
                    startInterpolation: .hold,
                    leftExtras: [],
                    boundary: Keyframe(
                        time: cut,
                        value: segment.start.value,
                        interpolation: .hold
                    ),
                    rightExtras: []
                )
            }
            return SegmentSplit(
                startInterpolation: .linear,
                leftExtras: [],
                boundary: Keyframe(
                    time: cut,
                    value: segment.start.value.lerp(to: segment.endValue, fraction: fraction),
                    interpolation: .linear
                ),
                rightExtras: []
            )
        }
        return try splitEasedSegment(
            segment,
            curve: curve,
            at: cut,
            fraction: fraction,
            interiorSplitBudget: interiorSplitBudget
        )
    }

    private static func splitEasedSegment(
        _ segment: BladeSegment,
        curve: CubicBezierTimingCurve,
        at cut: RationalTime,
        fraction: Double,
        interiorSplitBudget: Int
    ) throws -> SegmentSplit {
        let boundaryValue = segment.start.value.lerp(
            to: segment.endValue,
            fraction: curve.value(at: fraction)
        )
        let halves = curve.subdivided(atFraction: fraction)
        if let leftCurve = halves.left, let rightCurve = halves.right {
            return SegmentSplit(
                startInterpolation: .bezier(leftCurve),
                leftExtras: [],
                boundary: Keyframe(
                    time: cut,
                    value: boundaryValue,
                    interpolation: .bezier(rightCurve)
                ),
                rightExtras: []
            )
        }
        if halves.left == nil {
            // The progress at the cut equals the start progress, so renormalizing the
            // left half divides by zero; the right half's denominators are far from zero
            // when the left's vanish. The flat fallback (an exact hold when the curve
            // truly never moves before the cut) seeds the degenerate split.
            let flatFallback = SegmentSplit(
                startInterpolation: .hold,
                leftExtras: [],
                boundary: Keyframe(
                    time: cut,
                    value: boundaryValue,
                    interpolation: halves.right.map { .bezier($0) } ?? .linear
                ),
                rightExtras: []
            )
            return try splitLeftDegenerateSegment(
                segment,
                curve: curve,
                at: cut,
                flatFallback: flatFallback,
                interiorSplitBudget: interiorSplitBudget
            )
        }
        // Mirror case: the progress at the cut equals the end progress; the right half
        // holds the boundary value exactly when the curve is flat after the cut.
        let flatFallback = SegmentSplit(
            startInterpolation: halves.left.map { .bezier($0) } ?? .linear,
            leftExtras: [],
            boundary: Keyframe(time: cut, value: boundaryValue, interpolation: .hold),
            rightExtras: []
        )
        return try splitRightDegenerateSegment(
            segment,
            curve: curve,
            at: cut,
            flatFallback: flatFallback,
            interiorSplitBudget: interiorSplitBudget
        )
    }

    /// The curve's progress at the cut equals its start progress. If the curve moves
    /// anywhere before the cut (an overshoot returning exactly to zero progress), bake an
    /// interior keyframe where the progress is far from both endpoints and split the
    /// non-degenerate remainder at the cut — exact. A curve that is truly flat before the
    /// cut keeps the equally exact hold fallback.
    private static func splitLeftDegenerateSegment(
        _ segment: BladeSegment,
        curve: CubicBezierTimingCurve,
        at cut: RationalTime,
        flatFallback: SegmentSplit,
        interiorSplitBudget: Int
    ) throws -> SegmentSplit {
        guard
            interiorSplitBudget > 0,
            let interior = try interiorEasedKeyframe(
                in: segment,
                curve: curve,
                windowStart: segment.start.time,
                windowEnd: cut
            )
        else {
            return flatFallback
        }
        let rest = try splitSegment(
            BladeSegment(
                start: interior.keyframe,
                endTime: segment.endTime,
                endValue: segment.endValue
            ),
            at: cut,
            interiorSplitBudget: interiorSplitBudget - 1
        )
        let adjustedInterior = Keyframe(
            time: interior.keyframe.time,
            value: interior.keyframe.value,
            interpolation: rest.startInterpolation
        )
        return SegmentSplit(
            startInterpolation: interior.startInterpolation,
            leftExtras: [adjustedInterior] + rest.leftExtras,
            boundary: rest.boundary,
            rightExtras: rest.rightExtras
        )
    }

    /// Mirror of `splitLeftDegenerateSegment`: the progress at the cut equals the end
    /// progress, so the right half's renormalization is degenerate. The baked interior
    /// keyframe lands on the right half; a truly flat tail keeps the exact hold fallback.
    private static func splitRightDegenerateSegment(
        _ segment: BladeSegment,
        curve: CubicBezierTimingCurve,
        at cut: RationalTime,
        flatFallback: SegmentSplit,
        interiorSplitBudget: Int
    ) throws -> SegmentSplit {
        guard
            interiorSplitBudget > 0,
            let interior = try interiorEasedKeyframe(
                in: segment,
                curve: curve,
                windowStart: cut,
                windowEnd: segment.endTime
            )
        else {
            return flatFallback
        }
        let rest = try splitSegment(
            BladeSegment(
                start: Keyframe(
                    time: segment.start.time,
                    value: segment.start.value,
                    interpolation: interior.startInterpolation
                ),
                endTime: interior.keyframe.time,
                endValue: interior.keyframe.value
            ),
            at: cut,
            interiorSplitBudget: interiorSplitBudget - 1
        )
        return SegmentSplit(
            startInterpolation: rest.startInterpolation,
            leftExtras: rest.leftExtras,
            boundary: rest.boundary,
            rightExtras: rest.rightExtras + [interior.keyframe]
        )
    }

    /// A keyframe baked at an interior point of `(windowStart, windowEnd)` where the
    /// curve's progress sits far from both endpoint progresses, so subdividing there is
    /// never division-degenerate. Candidates walk eighths of the window; `nil` means the
    /// curve is flat across the window (progress pinned to an endpoint everywhere — a
    /// non-constant cubic crosses an endpoint progress at most a handful of times, so one
    /// of the seven candidates is accepted whenever the curve moves).
    private static func interiorEasedKeyframe(
        in segment: BladeSegment,
        curve: CubicBezierTimingCurve,
        windowStart: RationalTime,
        windowEnd: RationalTime
    ) throws -> (startInterpolation: InterpolationMode, keyframe: Keyframe<Value>)? {
        let window = try windowEnd.subtracting(windowStart)
        let margin = 1e-3
        for candidate in Int64(1)...7 {
            let time = try windowStart.adding(window.multiplied(by: candidate).divided(by: 8))
            let fraction = try bladeFraction(
                of: time,
                from: segment.start.time,
                to: segment.endTime
            )
            let progress = curve.value(at: fraction)
            guard abs(progress) > margin, abs(1 - progress) > margin else {
                continue
            }
            let halves = curve.subdivided(atFraction: fraction)
            guard let leftCurve = halves.left, let rightCurve = halves.right else {
                continue
            }
            return (
                startInterpolation: .bezier(leftCurve),
                keyframe: Keyframe(
                    time: time,
                    value: segment.start.value.lerp(to: segment.endValue, fraction: progress),
                    interpolation: .bezier(rightCurve)
                )
            )
        }
        return nil
    }

    /// The exact linear fraction of `cut` within `[leftTime, rightTime]`, evaluated in
    /// `Double` for timing-curve subdivision.
    private static func bladeFraction(
        of cut: RationalTime,
        from leftTime: RationalTime,
        to rightTime: RationalTime
    ) throws -> Double {
        let elapsed = try cut.subtracting(leftTime)
        let duration = try rightTime.subtracting(leftTime)
        let common = try elapsed.valuesAtCommonTimescale(with: duration)
        guard common.right != 0 else {
            return 0
        }
        return Double(common.left) / Double(common.right)
    }
}
