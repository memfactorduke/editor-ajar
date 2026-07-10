// SPDX-License-Identifier: GPL-3.0-or-later

/// Join shape used where two title-glyph outline segments meet (FR-TXT-002).
public enum TitleStrokeJoin: String, Codable, Equatable, Sendable {
    /// Extend the outside edges until they meet at a point.
    case miter

    /// Join outline segments with a circular arc.
    case round

    /// Cut the outside corner off with a straight edge.
    case bevel
}

/// Drop-shadow offset axis named by typed title validation failures.
public enum TitleShadowOffsetAxis: String, Equatable, Sendable {
    /// Horizontal canvas axis.
    case x

    /// Vertical canvas axis.
    case y
}

/// Opacity-bearing styling component named by typed title validation failures.
public enum TitleStyleOpacityComponent: String, Equatable, Sendable {
    /// Text drop shadow.
    case dropShadow

    /// Text-run background box.
    case backgroundBox
}

/// Static outline styling for a title text run (FR-TXT-002).
///
/// Title styling is static in the current title-source model. FR-TXT-004 adds title animation;
/// this slice does not introduce a parallel animation system.
public struct TitleStrokeStyle: Codable, Equatable, Sendable {
    /// Outline width in canvas points.
    public let width: RationalValue

    /// Outline RGB color in normalized 0...1 space.
    public let color: ClipRGBColor

    /// Shape used at outline joins.
    public let join: TitleStrokeJoin

    /// Creates an outline style.
    public init(
        width: RationalValue = RationalValue(1),
        color: ClipRGBColor = ClipRGBColor(red: .zero, green: .zero, blue: .zero),
        join: TitleStrokeJoin = .miter
    ) {
        self.width = width
        self.color = color
        self.join = join
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case color
        case join
    }

    /// Decodes sparse styling payloads with stable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width =
            try container.decodeIfPresent(RationalValue.self, forKey: .width) ?? RationalValue(1)
        color =
            try container.decodeIfPresent(ClipRGBColor.self, forKey: .color)
            ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        join = try container.decodeIfPresent(TitleStrokeJoin.self, forKey: .join) ?? .miter
    }
}

/// Static drop-shadow styling for a title text run (FR-TXT-002).
public struct TitleDropShadowStyle: Codable, Equatable, Sendable {
    /// Horizontal shadow offset in canvas points; positive values move right.
    public let offsetX: RationalValue

    /// Vertical shadow offset in canvas points; positive values move down.
    public let offsetY: RationalValue

    /// Core Graphics shadow blur radius in canvas points.
    public let blurRadius: RationalValue

    /// Shadow RGB color in normalized 0...1 space.
    public let color: ClipRGBColor

    /// Shadow opacity in normalized 0...1 space.
    public let opacity: RationalValue

    /// Creates a drop-shadow style.
    public init(
        offsetX: RationalValue = RationalValue(4),
        offsetY: RationalValue = RationalValue(4),
        blurRadius: RationalValue = RationalValue(4),
        color: ClipRGBColor = ClipRGBColor(red: .zero, green: .zero, blue: .zero),
        opacity: RationalValue = .one
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blurRadius = blurRadius
        self.color = color
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey {
        case offsetX
        case offsetY
        case blurRadius
        case color
        case opacity
    }

    /// Decodes sparse styling payloads with stable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offsetX =
            try container.decodeIfPresent(RationalValue.self, forKey: .offsetX)
            ?? RationalValue(4)
        offsetY =
            try container.decodeIfPresent(RationalValue.self, forKey: .offsetY)
            ?? RationalValue(4)
        blurRadius =
            try container.decodeIfPresent(RationalValue.self, forKey: .blurRadius)
            ?? RationalValue(4)
        color =
            try container.decodeIfPresent(ClipRGBColor.self, forKey: .color)
            ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        opacity = try container.decodeIfPresent(RationalValue.self, forKey: .opacity) ?? .one
    }
}

/// Static background drawn around a title text run's rendered bounds (FR-TXT-002).
public struct TitleBackgroundBoxStyle: Codable, Equatable, Sendable {
    /// Space between the text bounds and background edge in canvas points.
    public let padding: RationalValue

    /// Rounded-corner radius in canvas points.
    public let cornerRadius: RationalValue

    /// Background RGB color in normalized 0...1 space.
    public let fillColor: ClipRGBColor

    /// Background opacity in normalized 0...1 space.
    public let opacity: RationalValue

    /// Creates a text-run background style.
    public init(
        padding: RationalValue = RationalValue(8),
        cornerRadius: RationalValue = RationalValue(4),
        fillColor: ClipRGBColor = ClipRGBColor(red: .zero, green: .zero, blue: .zero),
        opacity: RationalValue = .one
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.fillColor = fillColor
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey {
        case padding
        case cornerRadius
        case fillColor
        case opacity
    }

    /// Decodes sparse styling payloads with stable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        padding =
            try container.decodeIfPresent(RationalValue.self, forKey: .padding)
            ?? RationalValue(8)
        cornerRadius =
            try container.decodeIfPresent(RationalValue.self, forKey: .cornerRadius)
            ?? RationalValue(4)
        fillColor =
            try container.decodeIfPresent(ClipRGBColor.self, forKey: .fillColor)
            ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        opacity = try container.decodeIfPresent(RationalValue.self, forKey: .opacity) ?? .one
    }
}

/// Linear gradient fill for a title text run (FR-TXT-002).
///
/// Only linear gradients ship in v1. Radial and conic gradients are intentionally left for a
/// future additive model change.
public struct TitleLinearGradientFill: Codable, Equatable, Sendable {
    /// Color at the start of the gradient axis.
    public let startColor: ClipRGBColor

    /// Color at the end of the gradient axis.
    public let endColor: ClipRGBColor

    /// Axis angle in degrees: 0 is left-to-right and 90 is top-to-bottom in canvas space.
    public let angleDegrees: RationalValue

    /// Creates a linear text fill.
    public init(
        startColor: ClipRGBColor = ClipRGBColor(red: .one, green: .one, blue: .one),
        endColor: ClipRGBColor = ClipRGBColor(red: .zero, green: .zero, blue: .zero),
        angleDegrees: RationalValue = .zero
    ) {
        self.startColor = startColor
        self.endColor = endColor
        self.angleDegrees = angleDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case startColor
        case endColor
        case angleDegrees
    }

    /// Decodes sparse styling payloads with stable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startColor =
            try container.decodeIfPresent(ClipRGBColor.self, forKey: .startColor)
            ?? ClipRGBColor(red: .one, green: .one, blue: .one)
        endColor =
            try container.decodeIfPresent(ClipRGBColor.self, forKey: .endColor)
            ?? ClipRGBColor(red: .zero, green: .zero, blue: .zero)
        angleDegrees =
            try container.decodeIfPresent(RationalValue.self, forKey: .angleDegrees)
            ?? .zero
    }
}
