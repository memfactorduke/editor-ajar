// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Built-in animated title presets expressed as keyframe programs (FR-TXT-004).
public enum TitleAnimationPresetKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// Opacity 0 → 1 over the preset duration.
    case fade

    /// Position entrance from an off-frame edge with optional opacity ramp.
    case slide

    /// Character reveal via `TitleSource.revealFraction` 0 → 1.
    case typewriter

    /// Scale + opacity pop-in with ease-out.
    case pop

    /// Lower-third: FR-TXT-002 bar styling + rise/slide entrance.
    case lowerThird
}

/// Edge a slide / lower-third entrance comes from (FR-TXT-004).
public enum TitleAnimationDirection: String, Codable, CaseIterable, Equatable, Sendable {
    /// Enters from the left of the frame.
    case left

    /// Enters from the right of the frame.
    case right

    /// Enters from above the frame.
    case up

    /// Enters from below the frame.
    case down
}

/// Parameterized title animation preset applied as one undoable edit (FR-TXT-004).
///
/// Applying a preset writes ordinary transform / `revealFraction` keyframes; afterward the
/// user can edit those keyframes with the M4 keyframe tools. No bespoke animation runtime.
public struct TitleAnimationPreset: Codable, Equatable, Sendable {
    /// Which built-in program to materialize.
    public let kind: TitleAnimationPresetKind

    /// Animation length from the clip's timeline start. Must be positive and ≤ clip duration.
    public let duration: RationalTime

    /// Entrance edge for `slide` and `lowerThird`. Ignored by fade / typewriter / pop.
    public let direction: TitleAnimationDirection

    /// Optional FR-TXT-002 background used by `lowerThird` (defaults when `nil`).
    public let lowerThirdBackground: TitleBackgroundBoxStyle?

    /// Optional text-style overrides applied to every box by `lowerThird`.
    public let lowerThirdTextStyle: TitleTextStyle?

    /// Creates a preset specification.
    ///
    /// When `direction` is omitted, uses ``defaultDirection(for:)`` (`.left` for most kinds,
    /// `.down` for lower-thirds).
    public init(
        kind: TitleAnimationPresetKind,
        duration: RationalTime,
        direction: TitleAnimationDirection? = nil,
        lowerThirdBackground: TitleBackgroundBoxStyle? = nil,
        lowerThirdTextStyle: TitleTextStyle? = nil
    ) {
        self.kind = kind
        self.duration = duration
        self.direction = direction ?? Self.defaultDirection(for: kind)
        self.lowerThirdBackground = lowerThirdBackground
        self.lowerThirdTextStyle = lowerThirdTextStyle
    }

    /// Default direction for a kind when the caller does not care.
    public static func defaultDirection(
        for kind: TitleAnimationPresetKind
    ) -> TitleAnimationDirection {
        switch kind {
        case .fade, .typewriter, .pop, .slide:
            return .left
        case .lowerThird:
            return .down
        }
    }
}

/// Resolved keyframe program produced by a preset (FR-TXT-004).
public struct TitleAnimationProgram: Equatable, Sendable {
    /// Base transform after any lower-third rest placement.
    public let transform: ClipTransform

    /// Full transform animation for the clip (ordinary M4 keyframes).
    public let transformAnimation: AnimatableClipTransform

    /// Title source including revealFraction keyframes and any lower-third styling.
    public let title: TitleSource
}

/// Builds M4 keyframe programs for title animation presets (FR-TXT-004).
public enum TitleAnimationPresetBuilder {
    /// Shared timing / base state for one preset materialization.
    private struct BuildContext {
        let title: TitleSource
        let base: ClipTransform
        let start: RationalTime
        let end: RationalTime
        let direction: TitleAnimationDirection
        let frame: PixelDimensions
        let preset: TitleAnimationPreset
    }

    /// Materializes `preset` against `clip` / `title` using the project frame for slide offsets.
    public static func program(
        for preset: TitleAnimationPreset,
        clip: Clip,
        title: TitleSource,
        frame: PixelDimensions
    ) throws -> TitleAnimationProgram {
        let start = clip.timelineRange.start
        let end = try start.adding(preset.duration)
        let context = BuildContext(
            title: title,
            base: clip.transformAnimation.baseTransform,
            start: start,
            end: end,
            direction: preset.direction,
            frame: frame,
            preset: preset
        )
        switch preset.kind {
        case .fade:
            return try fadeProgram(context)
        case .slide:
            return try slideProgram(context)
        case .typewriter:
            return try typewriterProgram(context)
        case .pop:
            return try popProgram(context)
        case .lowerThird:
            return try lowerThirdProgram(context)
        }
    }

    // Fade: opacity 0→1 linear; other channels constant; reveal full.
    private static func fadeProgram(_ context: BuildContext) throws -> TitleAnimationProgram {
        let opacity = try opacityRamp(
            base: context.base.opacity,
            start: context.start,
            end: context.end
        )
        let animation = AnimatableClipTransform.constant(context.base).replacing(opacity: opacity)
        return TitleAnimationProgram(
            transform: context.base.replacing(opacity: RationalValue.one),
            transformAnimation: animation,
            title: context.title.withRevealFraction(.constant(RationalValue.one))
        )
    }

    // Slide: position from off-frame edge → rest + opacity 0→1; reveal full.
    private static func slideProgram(_ context: BuildContext) throws -> TitleAnimationProgram {
        let rest = context.base.position
        let from = offsetPosition(rest, direction: context.direction, frame: context.frame)
        let position = try Animatable(
            base: rest,
            keyframes: [
                Keyframe(time: context.start, value: from, interpolation: .easeOut),
                Keyframe(time: context.end, value: rest, interpolation: .hold)
            ]
        )
        let opacity = try opacityRamp(
            base: context.base.opacity,
            start: context.start,
            end: context.end
        )
        let animation = AnimatableClipTransform.constant(context.base)
            .replacing(position: position, opacity: opacity)
        return TitleAnimationProgram(
            transform: context.base.replacing(opacity: RationalValue.one),
            transformAnimation: animation,
            title: context.title.withRevealFraction(.constant(RationalValue.one))
        )
    }

    // Typewriter: revealFraction 0→1 linear; transform constant; no opacity motion.
    private static func typewriterProgram(_ context: BuildContext) throws -> TitleAnimationProgram {
        let reveal = try Animatable(
            base: RationalValue.one,
            keyframes: [
                Keyframe(time: context.start, value: RationalValue.zero, interpolation: .linear),
                Keyframe(time: context.end, value: RationalValue.one, interpolation: .hold)
            ]
        )
        return TitleAnimationProgram(
            transform: context.base,
            transformAnimation: .constant(context.base),
            title: context.title.withRevealFraction(reveal)
        )
    }

    // Pop: scale 0→base easeOut + opacity 0→1 linear; reveal full.
    private static func popProgram(_ context: BuildContext) throws -> TitleAnimationProgram {
        let zeroScale = ClipScale(x: RationalValue.zero, y: RationalValue.zero)
        let scale = try Animatable(
            base: context.base.scale,
            keyframes: [
                Keyframe(time: context.start, value: zeroScale, interpolation: .easeOut),
                Keyframe(time: context.end, value: context.base.scale, interpolation: .hold)
            ]
        )
        let opacity = try opacityRamp(
            base: context.base.opacity,
            start: context.start,
            end: context.end
        )
        let animation = AnimatableClipTransform.constant(context.base)
            .replacing(scale: scale, opacity: opacity)
        return TitleAnimationProgram(
            transform: context.base.replacing(opacity: RationalValue.one),
            transformAnimation: animation,
            title: context.title.withRevealFraction(.constant(RationalValue.one))
        )
    }

    // Lower-third: FR-TXT-002 bar + rest near bottom; entrance from `direction`.
    private static func lowerThirdProgram(_ context: BuildContext) throws -> TitleAnimationProgram {
        let styled = applyLowerThirdStyling(context)
        let restPosition = lowerThirdRestPosition(frame: context.frame)
        let restTransform = context.base.replacing(
            position: restPosition,
            opacity: RationalValue.one
        )
        let from = offsetPosition(
            restPosition,
            direction: context.direction,
            frame: context.frame
        )
        let position = try Animatable(
            base: restPosition,
            keyframes: [
                Keyframe(time: context.start, value: from, interpolation: .easeOut),
                Keyframe(time: context.end, value: restPosition, interpolation: .hold)
            ]
        )
        let opacity = try opacityRamp(
            base: RationalValue.one,
            start: context.start,
            end: context.end
        )
        let animation = AnimatableClipTransform.constant(restTransform)
            .replacing(position: position, opacity: opacity)
        return TitleAnimationProgram(
            transform: restTransform,
            transformAnimation: animation,
            title: styled.withRevealFraction(.constant(.one))
        )
    }

    private static func opacityRamp(
        base: RationalValue,
        start: RationalTime,
        end: RationalTime
    ) throws -> Animatable<RationalValue> {
        try Animatable(
            base: base,
            keyframes: [
                Keyframe(time: start, value: RationalValue.zero, interpolation: .linear),
                Keyframe(time: end, value: RationalValue.one, interpolation: .hold)
            ]
        )
    }

    private static func applyLowerThirdStyling(_ context: BuildContext) -> TitleSource {
        let defaultBackground = TitleBackgroundBoxStyle(
            padding: RationalValue(8),
            cornerRadius: RationalValue(2),
            fillColor: ClipRGBColor(red: .zero, green: .zero, blue: .zero),
            opacity: (try? RationalValue(numerator: 3, denominator: 4)) ?? .one
        )
        let barBackground = context.preset.lowerThirdBackground ?? defaultBackground
        let frameWidth = RationalValue(Int64(context.frame.width))
        let boxHeight = RationalValue(56)
        let originY = RationalValue(Int64(max(0, context.frame.height - 72)))
        let boxes = context.title.boxes.enumerated().map { index, box in
            let style =
                context.preset.lowerThirdTextStyle
                ?? TitleTextStyle(
                    fontFamily: box.style.fontFamily,
                    fontSize: box.style.fontSize,
                    fontWeight: box.style.fontWeight == .regular ? .semibold : box.style.fontWeight,
                    color: box.style.color,
                    tracking: box.style.tracking,
                    leading: box.style.leading,
                    alignment: .left,
                    stroke: box.style.stroke,
                    dropShadow: box.style.dropShadow,
                    gradientFill: box.style.gradientFill
                )
            // First box becomes the lower-third bar; additional boxes stack above it.
            let yOffset = RationalValue(Int64(index) * 40)
            let origin = CanvasPoint(
                x: RationalValue(24),
                y: subtractNonNegative(originY, yOffset)
            )
            return TitleTextBox(
                id: box.id,
                text: box.text,
                origin: origin,
                width: larger(box.width, subtractValues(frameWidth, RationalValue(48))),
                height: larger(box.height, boxHeight),
                style: style,
                backgroundBox: box.backgroundBox ?? barBackground
            )
        }
        return TitleSource(boxes: boxes, revealFraction: context.title.revealFraction)
    }

    private static func lowerThirdRestPosition(frame: PixelDimensions) -> CanvasPoint {
        // Identity rest; boxes themselves sit in the lower-third band of the canvas.
        _ = frame
        return .zero
    }

    private static func offsetPosition(
        _ rest: CanvasPoint,
        direction: TitleAnimationDirection,
        frame: PixelDimensions
    ) -> CanvasPoint {
        let width = RationalValue(Int64(frame.width))
        let height = RationalValue(Int64(frame.height))
        switch direction {
        case .left:
            return CanvasPoint(x: subtractValues(rest.x, width), y: rest.y)
        case .right:
            return CanvasPoint(x: addValues(rest.x, width), y: rest.y)
        case .up:
            return CanvasPoint(x: rest.x, y: subtractValues(rest.y, height))
        case .down:
            return CanvasPoint(x: rest.x, y: addValues(rest.y, height))
        }
    }

    private static func addValues(_ left: RationalValue, _ right: RationalValue) -> RationalValue {
        RationalValue.approximating(left.doubleValue + right.doubleValue)
    }

    private static func subtractValues(
        _ left: RationalValue,
        _ right: RationalValue
    ) -> RationalValue {
        RationalValue.approximating(left.doubleValue - right.doubleValue)
    }

    private static func subtractNonNegative(
        _ left: RationalValue,
        _ right: RationalValue
    ) -> RationalValue {
        let value = left.doubleValue - right.doubleValue
        return RationalValue.approximating(Swift.max(0, value))
    }

    private static func larger(_ left: RationalValue, _ right: RationalValue) -> RationalValue {
        left.doubleValue >= right.doubleValue ? left : right
    }
}
