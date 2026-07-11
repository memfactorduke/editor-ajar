// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Horizontal alignment of text inside a title box (FR-TXT-001).
public enum TitleTextAlignment: String, Codable, CaseIterable, Equatable, Sendable {
    /// Flush left.
    case left

    /// Centered.
    case center

    /// Flush right.
    case right

    /// Full justification between margins.
    case justified
}

/// Font weight for a title text style (FR-TXT-001).
public enum TitleFontWeight: String, Codable, CaseIterable, Equatable, Sendable {
    /// Ultra-light weight.
    case ultraLight

    /// Thin weight.
    case thin

    /// Light weight.
    case light

    /// Regular / book weight.
    case regular

    /// Medium weight.
    case medium

    /// Semibold weight.
    case semibold

    /// Bold weight.
    case bold

    /// Heavy weight.
    case heavy

    /// Black / heavy black weight.
    case black
}

/// Typed validation failures for title model values (FR-TXT-001/002, NFR-STAB-003).
public enum TitleSourceValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Font family string is empty or whitespace-only.
    case emptyFontFamily

    /// Font size is outside the supported range (points).
    case fontSizeOutOfRange(value: RationalValue, minimum: RationalValue, maximum: RationalValue)

    /// Tracking is outside the supported range (points).
    case trackingOutOfRange(value: RationalValue, minimum: RationalValue, maximum: RationalValue)

    /// Leading is outside the supported range (points of additional line spacing; zero uses font default).
    case leadingOutOfRange(value: RationalValue, minimum: RationalValue, maximum: RationalValue)

    /// Stroke width is outside the supported range (canvas points).
    case strokeWidthOutOfRange(
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// A drop-shadow offset is outside the supported signed range (canvas points).
    case dropShadowOffsetOutOfRange(
        axis: TitleShadowOffsetAxis,
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// Drop-shadow blur radius is outside the supported range (canvas points).
    case dropShadowBlurRadiusOutOfRange(
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// A title styling opacity is outside normalized 0...1.
    case styleOpacityOutOfRange(component: TitleStyleOpacityComponent, value: RationalValue)

    /// Background padding is outside the supported range (canvas points).
    case backgroundPaddingOutOfRange(
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// Background corner radius is outside the supported range (canvas points).
    case backgroundCornerRadiusOutOfRange(
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// Linear-gradient angle is outside the supported range (degrees).
    case gradientAngleOutOfRange(
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// Color channel is outside normalized 0...1.
    case colorChannelOutOfRange(channel: ClipColorChannel, value: RationalValue)

    /// Box width or height is not strictly positive.
    case nonPositiveBoxSize(width: RationalValue, height: RationalValue)

    /// Two text boxes share the same stable ID.
    case duplicateTextBoxID(UUID)

    /// Character reveal fraction is outside normalized 0...1 (FR-TXT-004 typewriter).
    case revealFractionOutOfRange(value: RationalValue)

    /// A human-readable description of the validation failure.
    public var description: String {
        switch self {
        case .emptyFontFamily:
            "title font family must be non-empty"
        case .fontSizeOutOfRange(let value, let minimum, let maximum):
            "title font size \(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .trackingOutOfRange(let value, let minimum, let maximum):
            "title tracking \(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .leadingOutOfRange(let value, let minimum, let maximum):
            "title leading \(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .strokeWidthOutOfRange(let value, let minimum, let maximum):
            "title stroke width \(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .dropShadowOffsetOutOfRange(let axis, let value, let minimum, let maximum):
            "title drop-shadow \(axis.rawValue) offset "
                + "\(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .dropShadowBlurRadiusOutOfRange(let value, let minimum, let maximum):
            "title drop-shadow blur \(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .styleOpacityOutOfRange(let component, let value):
            "title \(component.rawValue) opacity "
                + "\(value.numerator)/\(value.denominator) outside 0...1"
        case .backgroundPaddingOutOfRange(let value, let minimum, let maximum):
            "title background padding \(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .backgroundCornerRadiusOutOfRange(let value, let minimum, let maximum):
            "title background corner radius \(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .gradientAngleOutOfRange(let value, let minimum, let maximum):
            "title gradient angle \(value.numerator)/\(value.denominator) outside "
                + "\(minimum.numerator)/\(minimum.denominator)..."
                + "\(maximum.numerator)/\(maximum.denominator)"
        case .colorChannelOutOfRange(let channel, let value):
            "title color \(channel.rawValue) \(value.numerator)/\(value.denominator) outside 0...1"
        case .nonPositiveBoxSize(let width, let height):
            "title box size \(width.numerator)/\(width.denominator)x"
                + "\(height.numerator)/\(height.denominator) must be positive"
        case .duplicateTextBoxID(let id):
            "duplicate title text box id \(id)"
        case .revealFractionOutOfRange(let value):
            "title reveal fraction \(value.numerator)/\(value.denominator) outside 0...1"
        }
    }
}

/// Styled run parameters for one title text box (FR-TXT-001/002).
public struct TitleTextStyle: Codable, Equatable, Sendable {
    /// Requested font family name (Core Text family or PostScript name at rasterization).
    public let fontFamily: String

    /// Font size in points.
    public let fontSize: RationalValue

    /// Font weight.
    public let fontWeight: TitleFontWeight

    /// Fill color in normalized 0...1 RGB.
    public let color: ClipRGBColor

    /// Additional character spacing in points (may be negative for tighter tracking).
    public let tracking: RationalValue

    /// Additional line spacing in points. Zero means the font's default leading.
    public let leading: RationalValue

    /// Horizontal alignment inside the box.
    public let alignment: TitleTextAlignment

    /// Optional glyph outline. `nil` preserves the legacy fill-only rendering path.
    public let stroke: TitleStrokeStyle?

    /// Optional text drop shadow.
    public let dropShadow: TitleDropShadowStyle?

    /// Optional linear glyph fill. When present, it takes precedence over solid `color`.
    public let gradientFill: TitleLinearGradientFill?

    /// Default style: Helvetica 48 pt regular white, flush left (ADR-0017).
    public static let `default` = TitleTextStyle(
        fontFamily: TitleSource.deterministicFontFamily,
        fontSize: RationalValue(48),
        fontWeight: .regular,
        color: ClipRGBColor(red: .one, green: .one, blue: .one),
        tracking: .zero,
        leading: .zero,
        alignment: .left,
        stroke: nil,
        dropShadow: nil,
        gradientFill: nil
    )

    /// Creates a text style.
    public init(
        fontFamily: String = TitleSource.deterministicFontFamily,
        fontSize: RationalValue = RationalValue(48),
        fontWeight: TitleFontWeight = .regular,
        color: ClipRGBColor = ClipRGBColor(red: .one, green: .one, blue: .one),
        tracking: RationalValue = .zero,
        leading: RationalValue = .zero,
        alignment: TitleTextAlignment = .left,
        stroke: TitleStrokeStyle? = nil,
        dropShadow: TitleDropShadowStyle? = nil,
        gradientFill: TitleLinearGradientFill? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.color = color
        self.tracking = tracking
        self.leading = leading
        self.alignment = alignment
        self.stroke = stroke
        self.dropShadow = dropShadow
        self.gradientFill = gradientFill
    }

    private enum CodingKeys: String, CodingKey {
        case fontFamily
        case fontSize
        case fontWeight
        case color
        case tracking
        case leading
        case alignment
        case stroke
        case dropShadow
        case gradientFill
    }

    /// Decodes with defaults for absent keys so legacy partial payloads stay loadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily =
            try container.decodeIfPresent(String.self, forKey: .fontFamily)
            ?? TitleSource.deterministicFontFamily
        fontSize =
            try container.decodeIfPresent(RationalValue.self, forKey: .fontSize)
            ?? RationalValue(48)
        fontWeight =
            try container.decodeIfPresent(TitleFontWeight.self, forKey: .fontWeight)
            ?? .regular
        color =
            try container.decodeIfPresent(ClipRGBColor.self, forKey: .color)
            ?? ClipRGBColor(red: .one, green: .one, blue: .one)
        tracking = try container.decodeIfPresent(RationalValue.self, forKey: .tracking) ?? .zero
        leading = try container.decodeIfPresent(RationalValue.self, forKey: .leading) ?? .zero
        alignment =
            try container.decodeIfPresent(TitleTextAlignment.self, forKey: .alignment)
            ?? .left
        stroke = try container.decodeIfPresent(TitleStrokeStyle.self, forKey: .stroke)
        dropShadow = try container.decodeIfPresent(TitleDropShadowStyle.self, forKey: .dropShadow)
        gradientFill =
            try container.decodeIfPresent(TitleLinearGradientFill.self, forKey: .gradientFill)
    }
}

/// One positioned text box on a title generator (FR-TXT-001/002).
public struct TitleTextBox: Codable, Equatable, Sendable {
    /// Stable box ID for edit targeting.
    public let id: UUID

    /// UTF-8 text. Empty string is allowed (renders nothing for that box).
    public let text: String

    /// Top-left of the text frame in sequence canvas units.
    public let origin: CanvasPoint

    /// Frame width in canvas units (must be positive).
    public let width: RationalValue

    /// Frame height in canvas units (must be positive).
    public let height: RationalValue

    /// Style applied to the whole box in v1.
    public let style: TitleTextStyle

    /// Optional background drawn around the rendered text-run bounds.
    public let backgroundBox: TitleBackgroundBoxStyle?

    /// Creates a text box.
    public init(
        id: UUID,
        text: String,
        origin: CanvasPoint,
        width: RationalValue,
        height: RationalValue,
        style: TitleTextStyle = .default,
        backgroundBox: TitleBackgroundBoxStyle? = nil
    ) {
        self.id = id
        self.text = text
        self.origin = origin
        self.width = width
        self.height = height
        self.style = style
        self.backgroundBox = backgroundBox
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case origin
        case width
        case height
        case style
        case backgroundBox
    }

    /// Decodes with style defaults for absent keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        origin = try container.decodeIfPresent(CanvasPoint.self, forKey: .origin) ?? .zero
        width =
            try container.decodeIfPresent(RationalValue.self, forKey: .width)
            ?? RationalValue(100)
        height =
            try container.decodeIfPresent(RationalValue.self, forKey: .height)
            ?? RationalValue(100)
        style = try container.decodeIfPresent(TitleTextStyle.self, forKey: .style) ?? .default
        backgroundBox =
            try container.decodeIfPresent(TitleBackgroundBoxStyle.self, forKey: .backgroundBox)
    }
}

/// Generator payload for a title clip (FR-TXT-001/002/004, ADR-0017).
public struct TitleSource: Codable, Equatable, Sendable {
    /// PostScript / family name pinned for goldens and missing-font fallback (ADR-0017).
    public static let deterministicFontFamily = "Helvetica"

    /// Minimum supported font size in points.
    public static let minimumFontSize = RationalValue(1)

    /// Maximum supported font size in points.
    public static let maximumFontSize = RationalValue(1_000)

    /// Minimum supported tracking in points.
    public static let minimumTracking = RationalValue(-100)

    /// Maximum supported tracking in points.
    public static let maximumTracking = RationalValue(100)

    /// Minimum supported additional leading in points.
    public static let minimumLeading = RationalValue.zero

    /// Maximum supported additional leading in points.
    public static let maximumLeading = RationalValue(500)

    /// Minimum supported stroke width in canvas points.
    public static let minimumStrokeWidth = RationalValue.zero

    /// Maximum supported stroke width in canvas points.
    public static let maximumStrokeWidth = RationalValue(100)

    /// Minimum supported signed drop-shadow offset in canvas points.
    public static let minimumDropShadowOffset = RationalValue(-1_000)

    /// Maximum supported signed drop-shadow offset in canvas points.
    public static let maximumDropShadowOffset = RationalValue(1_000)

    /// Maximum supported drop-shadow blur radius in canvas points.
    public static let maximumDropShadowBlurRadius = RationalValue(500)

    /// Maximum supported background padding in canvas points.
    public static let maximumBackgroundPadding = RationalValue(500)

    /// Maximum supported background corner radius in canvas points.
    public static let maximumBackgroundCornerRadius = RationalValue(500)

    /// Minimum supported linear-gradient angle in degrees.
    public static let minimumGradientAngle = RationalValue(-360)

    /// Maximum supported linear-gradient angle in degrees.
    public static let maximumGradientAngle = RationalValue(360)

    /// Ordered text boxes, bottom-to-top paint order (later boxes draw on top).
    public let boxes: [TitleTextBox]

    /// Keyframable 0...1 character reveal fraction for typewriter presets (FR-TXT-004).
    ///
    /// `1` is fully revealed (legacy default). The rasterizer lays out only the first
    /// `floor(fraction × characterCount)` grapheme clusters per box. Keyframe times use the
    /// same absolute timeline domain as transform animation (FR-KEY-001).
    public let revealFraction: Animatable<RationalValue>

    /// Creates a title source.
    ///
    /// - Parameters:
    ///   - boxes: Ordered text boxes.
    ///   - revealFraction: Character reveal animation. Defaults to fully revealed.
    public init(
        boxes: [TitleTextBox] = [],
        revealFraction: Animatable<RationalValue> = .constant(.one)
    ) {
        self.boxes = boxes
        self.revealFraction = revealFraction
    }

    private enum CodingKeys: String, CodingKey {
        case boxes
        case revealFraction
    }

    /// Decodes with an empty box list and full reveal when keys are absent (legacy nested titles).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boxes = try container.decodeIfPresent([TitleTextBox].self, forKey: .boxes) ?? []
        revealFraction =
            try container.decodeIfPresent(Animatable<RationalValue>.self, forKey: .revealFraction)
            ?? .constant(.one)
    }

    /// Returns a copy with `box` replacing the matching ID, or appended when new.
    public func replacing(box: TitleTextBox) -> TitleSource {
        var next = boxes
        if let index = next.firstIndex(where: { $0.id == box.id }) {
            next[index] = box
        } else {
            next.append(box)
        }
        return TitleSource(boxes: next, revealFraction: revealFraction)
    }

    /// Returns a copy without the box with `boxID`.
    public func removingBox(id boxID: UUID) -> TitleSource {
        TitleSource(boxes: boxes.filter { $0.id != boxID }, revealFraction: revealFraction)
    }

    /// Returns a copy with a different reveal animation (FR-TXT-004).
    public func withRevealFraction(_ revealFraction: Animatable<RationalValue>) -> TitleSource {
        TitleSource(boxes: boxes, revealFraction: revealFraction)
    }

    /// Returns a copy whose reveal is the constant evaluation at `time` (render-graph snapshot).
    public func evaluated(at time: RationalTime) -> TitleSource {
        withRevealFraction(.constant(revealFraction.value(at: time)))
    }

    /// Resolved reveal fraction for rasterization after evaluation to a constant.
    public var resolvedRevealFraction: RationalValue {
        revealFraction.base
    }
}
