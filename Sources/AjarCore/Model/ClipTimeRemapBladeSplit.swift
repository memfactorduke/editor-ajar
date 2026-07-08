// SPDX-License-Identifier: GPL-3.0-or-later

extension ClipTimeRemap {
    /// Splits the curve at a clip-local timeline `offset` for a blade edit (FR-SPD-002).
    ///
    /// A boundary keyframe evaluated at the split point terminates the left half's curve and
    /// anchors the right half's curve at its new local time zero, with the remaining
    /// keyframes re-anchored by `-offset`. Both halves therefore satisfy every curve
    /// invariant (first keyframe at zero, strictly increasing times, non-decreasing source
    /// times) and reproduce the original timeline-to-source mapping piecewise.
    ///
    /// `offset` must lie strictly inside the curve domain `(0, duration)`; blade commands
    /// guarantee this by rejecting cuts outside the clip.
    func bladed(
        atOffset offset: RationalTime
    ) throws -> (left: ClipTimeRemap, right: ClipTimeRemap) {
        let boundarySource = try sourceTime(atOffset: offset)
        var leftKeyframes = keyframes.filter { keyframe in keyframe.time < offset }
        leftKeyframes.append(TimeRemapKeyframe(time: offset, sourceTime: boundarySource))
        var rightKeyframes = [TimeRemapKeyframe(time: .zero, sourceTime: boundarySource)]
        for keyframe in keyframes where keyframe.time > offset {
            rightKeyframes.append(
                TimeRemapKeyframe(
                    time: try keyframe.time.subtracting(offset),
                    sourceTime: keyframe.sourceTime
                )
            )
        }
        return (
            left: try ClipTimeRemap(keyframes: leftKeyframes),
            right: try ClipTimeRemap(keyframes: rightKeyframes)
        )
    }
}
