// SPDX-License-Identifier: GPL-3.0-or-later

extension InterpolationMode {
    /// Splits the segment timing at `fraction` of the segment's linear time so the two
    /// sub-segments concatenate to the original easing (FR-XFORM-008 blade support).
    ///
    /// `hold` and `linear` split exactly into themselves; the eased modes subdivide their
    /// underlying cubic Bezier timing curve. A degenerate subdivision (non-monotone
    /// overshoot curve) keeps the original mode on both halves as the closest shape.
    func bladed(
        atFraction fraction: Double
    ) -> (left: InterpolationMode, right: InterpolationMode) {
        let curve: CubicBezierTimingCurve
        switch self {
        case .hold:
            return (.hold, .hold)
        case .linear:
            return (.linear, .linear)
        case .easeIn:
            curve = .easeIn
        case .easeOut:
            curve = .easeOut
        case .easeInOut:
            curve = .easeInOut
        case .bezier(let bezier):
            curve = bezier
        }
        guard let halves = curve.subdivided(atFraction: fraction) else {
            return (self, self)
        }
        return (.bezier(halves.left), .bezier(halves.right))
    }
}

extension Animatable {
    /// Splits the keyframe list at the absolute timeline `cut` for a blade edit
    /// (FR-XFORM-008): each half keeps the keyframes on its own side plus a shared boundary
    /// keyframe evaluated at the cut, and the segment crossing the cut has its interpolation
    /// subdivided, so evaluating the left half before the cut and the right half from the
    /// cut reproduces the original animation.
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
        if exact == nil,
           let crossingLeft = leftKeyframes.last,
           let crossingRight = rightKeyframes.first {
            // The cut lands strictly inside the segment crossingLeft → crossingRight:
            // subdivide its timing so both sub-segments retrace the original easing.
            let fraction = try Self.bladeFraction(
                of: cut,
                from: crossingLeft.time,
                to: crossingRight.time
            )
            let modes = crossingLeft.interpolation.bladed(atFraction: fraction)
            leftKeyframes[leftKeyframes.count - 1] = Keyframe(
                time: crossingLeft.time,
                value: crossingLeft.value,
                interpolation: modes.left
            )
            boundary = Keyframe(time: cut, value: boundary.value, interpolation: modes.right)
        }
        leftKeyframes.append(boundary)
        rightKeyframes.insert(boundary, at: 0)
        return (
            left: try Animatable(base: base, keyframes: leftKeyframes),
            right: try Animatable(base: base, keyframes: rightKeyframes)
        )
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
