// SPDX-License-Identifier: GPL-3.0-or-later

/// Per-clip source frame sampling mode for retimed playback (FR-SPD-004).
///
/// `nearest` preserves the pre-FR-SPD-004 behavior of decoding one source frame per rendered
/// frame. `frameBlend` opts a media-backed clip into blending the two source frames adjacent to
/// a fractional source frame position, weighted by the fractional part, for smoother slow
/// motion. Compound clip sources sample nearest in v1; optical flow is out of scope (v1.x).
public enum ClipFrameSamplingMode: String, Codable, Equatable, Sendable {
    /// Decode the single source frame the decoder resolves for the mapped source time.
    case nearest

    /// Blend the two adjacent source frames around a fractional source frame position.
    case frameBlend
}

/// The two adjacent source frame times and blend weight for one fractional source position
/// (FR-SPD-004).
public struct FrameBlendPair: Equatable, Sendable {
    /// Start time of the earlier adjacent source frame (`floor` of the fractional position).
    public let earlierFrameTime: RationalTime

    /// Start time of the later adjacent source frame (`ceil` of the fractional position).
    public let laterFrameTime: RationalTime

    /// Exact blend weight of the later frame in the open interval (0, 1).
    ///
    /// The weight is measured toward the later frame on the source-time axis regardless of
    /// playback direction, so reversed playback through the same source position blends the
    /// same two frames with the same weights as forward playback.
    public let laterWeight: RationalValue

    /// Creates a frame blend pair.
    public init(
        earlierFrameTime: RationalTime,
        laterFrameTime: RationalTime,
        laterWeight: RationalValue
    ) {
        self.earlierFrameTime = earlierFrameTime
        self.laterFrameTime = laterFrameTime
        self.laterWeight = laterWeight
    }
}

/// Pure FR-SPD-004 frame-blend sampling math shared by offline and playback frame providers.
public enum FrameBlendSampling {
    /// Resolves the adjacent frame pair and blend weight for a fractional source position.
    ///
    /// Returns `nil` whenever blending degenerates to nearest sampling:
    /// - the source time lands exactly on a frame boundary (integer frame position), or
    /// - the later adjacent frame would start at or past the exclusive `sourceEnd` bound, so
    ///   only one decodable frame exists at the position.
    ///
    /// When this declines, frame providers must decode the **nearest-earlier** frame
    /// (`nearestEarlierFrameTime(forSourceTime:frameRate:)`) rather than the fractional source
    /// time itself, so the source-end degeneracy deterministically renders the last frame
    /// instead of handing decoders a time past the final sample start.
    ///
    /// Freeze-frame clips hold a single decoded frame; callers resolve that degeneracy through
    /// `RenderSourceNode.resolvedFrameSampling` before asking for a pair.
    public static func blendPair(
        forSourceTime sourceTime: RationalTime,
        frameRate: FrameRate,
        sourceEnd: RationalTime?
    ) throws -> FrameBlendPair? {
        let earlierIndex = try sourceTime.frameIndex(at: frameRate, rounding: .down)
        let earlierFrameTime = try RationalTime.atFrame(earlierIndex, frameRate: frameRate)
        guard earlierFrameTime != sourceTime else {
            return nil
        }

        let laterFrameTime = try RationalTime.atFrame(earlierIndex + 1, frameRate: frameRate)
        if let sourceEnd, laterFrameTime >= sourceEnd {
            return nil
        }

        let elapsed = try sourceTime.subtracting(earlierFrameTime)
        let frameDuration = try frameRate.duration(ofFrames: 1)
        let fraction = try elapsed.valuesAtCommonTimescale(with: frameDuration)
        guard fraction.right > 0, fraction.left > 0, fraction.left < fraction.right else {
            return nil
        }

        return FrameBlendPair(
            earlierFrameTime: earlierFrameTime,
            laterFrameTime: laterFrameTime,
            laterWeight: try RationalValue(
                numerator: fraction.left,
                denominator: fraction.right
            )
        )
    }

    /// Returns the start time of the frame containing `sourceTime` (the nearest-earlier frame).
    ///
    /// This is the deterministic single-frame decode position frame-blend providers fall back
    /// to when `blendPair(forSourceTime:frameRate:sourceEnd:)` declines: for integer positions
    /// it is the position itself, and at the source-end degeneracy it is the last decodable
    /// frame start rather than a fractional time past it.
    public static func nearestEarlierFrameTime(
        forSourceTime sourceTime: RationalTime,
        frameRate: FrameRate
    ) throws -> RationalTime {
        let frameIndex = try sourceTime.frameIndex(at: frameRate, rounding: .down)
        return try RationalTime.atFrame(frameIndex, frameRate: frameRate)
    }
}
