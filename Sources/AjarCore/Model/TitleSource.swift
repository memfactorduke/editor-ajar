// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Horizontal alignment of text inside a title box (FR-TXT-001).
public enum TitleTextAlignment: String, Codable, Equatable, Sendable {
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
public enum TitleFontWeight: String, Codable, Equatable, Sendable {
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

/// Typed validation failures for title model values (FR-TXT-001, NFR-STAB-003).
public enum TitleSourceValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Font family string is empty or whitespace-only.
    case emptyFontFamily

    /// Font size is outside the supported range (points).
    case fontSizeOutOfRange(value: RationalValue, minimum: RationalValue, maximum: RationalValue)

    /// Tracking is outside the supported range (points).
    case trackingOutOfRange(value: RationalValue, minimum: RationalValue, maximum: RationalValue)

    /// Leading is outside the supported range (points of additional line spacing; zero uses font default).
    case leadingOutOfRange(value: RationalValue, minimum: RationalValue, maximum: RationalValue)

    /// Color channel is outside normalized 0...1.
    case colorChannelOutOfRange(channel: ClipColorChannel, value: RationalValue)

    /// Box width or height is not strictly positive.
    case nonPositiveBoxSize(width: RationalValue, height: RationalValue)

    /// Two text boxes share the same stable ID.
    case duplicateTextBoxID(UUID)

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
        case .colorChannelOutOfRange(let channel, let value):
            "title color \(channel.rawValue) \(value.numerator)/\(value.denominator) outside 0...1"
        case .nonPositiveBoxSize(let width, let height):
            "title box size \(width.numerator)/\(width.denominator)x"
                + "\(height.numerator)/\(height.denominator) must be positive"
        case .duplicateTextBoxID(let id):
            "duplicate title text box id \(id)"
        }
    }
}

/// Styled run parameters for one title text box (FR-TXT-001).
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

    /// Default style: Helvetica 48 pt regular white, flush left (ADR-0017).
    public static let `default` = TitleTextStyle(
        fontFamily: TitleSource.deterministicFontFamily,
        fontSize: RationalValue(48),
        fontWeight: .regular,
        color: ClipRGBColor(red: .one, green: .one, blue: .one),
        tracking: .zero,
        leading: .zero,
        alignment: .left
    )

    /// Creates a text style.
    public init(
        fontFamily: String = TitleSource.deterministicFontFamily,
        fontSize: RationalValue = RationalValue(48),
        fontWeight: TitleFontWeight = .regular,
        color: ClipRGBColor = ClipRGBColor(red: .one, green: .one, blue: .one),
        tracking: RationalValue = .zero,
        leading: RationalValue = .zero,
        alignment: TitleTextAlignment = .left
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.color = color
        self.tracking = tracking
        self.leading = leading
        self.alignment = alignment
    }

    private enum CodingKeys: String, CodingKey {
        case fontFamily
        case fontSize
        case fontWeight
        case color
        case tracking
        case leading
        case alignment
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
    }
}

/// One positioned text box on a title generator (FR-TXT-001).
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

    /// Style applied to the whole box in v1 (multi-run styles land with FR-TXT-002).
    public let style: TitleTextStyle

    /// Creates a text box.
    public init(
        id: UUID,
        text: String,
        origin: CanvasPoint,
        width: RationalValue,
        height: RationalValue,
        style: TitleTextStyle = .default
    ) {
        self.id = id
        self.text = text
        self.origin = origin
        self.width = width
        self.height = height
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case origin
        case width
        case height
        case style
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
    }
}

/// Generator payload for a title clip (FR-TXT-001, ADR-0017).
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

    /// Ordered text boxes, bottom-to-top paint order (later boxes draw on top).
    public let boxes: [TitleTextBox]

    /// Creates a title source.
    public init(boxes: [TitleTextBox] = []) {
        self.boxes = boxes
    }

    private enum CodingKeys: String, CodingKey {
        case boxes
    }

    /// Decodes with an empty box list when the key is absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boxes = try container.decodeIfPresent([TitleTextBox].self, forKey: .boxes) ?? []
    }

    /// Returns the first typed validation error, or `nil` when the source is valid.
    public func validate() -> TitleSourceValidationError? {
        var seenIDs = Set<UUID>()
        for box in boxes {
            if !seenIDs.insert(box.id).inserted {
                return .duplicateTextBoxID(box.id)
            }
            if let error = validate(box: box) {
                return error
            }
        }
        return nil
    }

    /// Returns a copy with `box` replacing the matching ID, or appended when new.
    public func replacing(box: TitleTextBox) -> TitleSource {
        var next = boxes
        if let index = next.firstIndex(where: { $0.id == box.id }) {
            next[index] = box
        } else {
            next.append(box)
        }
        return TitleSource(boxes: next)
    }

    /// Returns a copy without the box with `boxID`.
    public func removingBox(id boxID: UUID) -> TitleSource {
        TitleSource(boxes: boxes.filter { $0.id != boxID })
    }

    private func validate(box: TitleTextBox) -> TitleSourceValidationError? {
        let family = box.style.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if family.isEmpty {
            return .emptyFontFamily
        }
        if box.width.numerator <= 0 || box.height.numerator <= 0 {
            return .nonPositiveBoxSize(width: box.width, height: box.height)
        }
        if let error = rangeError(
            box.style.fontSize,
            minimum: Self.minimumFontSize,
            maximum: Self.maximumFontSize,
            as: { .fontSizeOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        if let error = rangeError(
            box.style.tracking,
            minimum: Self.minimumTracking,
            maximum: Self.maximumTracking,
            as: { .trackingOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        if let error = rangeError(
            box.style.leading,
            minimum: Self.minimumLeading,
            maximum: Self.maximumLeading,
            as: { .leadingOutOfRange(value: $0, minimum: $1, maximum: $2) }
        ) {
            return error
        }
        if let error = colorChannelError(box.style.color.red, channel: .red) {
            return error
        }
        if let error = colorChannelError(box.style.color.green, channel: .green) {
            return error
        }
        if let error = colorChannelError(box.style.color.blue, channel: .blue) {
            return error
        }
        return nil
    }

    private func rangeError(
        _ value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue,
        as make: (RationalValue, RationalValue, RationalValue) -> TitleSourceValidationError
    ) -> TitleSourceValidationError? {
        if value.doubleValue < minimum.doubleValue || value.doubleValue > maximum.doubleValue {
            return make(value, minimum, maximum)
        }
        return nil
    }

    private func colorChannelError(
        _ value: RationalValue,
        channel: ClipColorChannel
    ) -> TitleSourceValidationError? {
        if value.doubleValue < 0 || value.doubleValue > 1 {
            return .colorChannelOutOfRange(channel: channel, value: value)
        }
        return nil
    }
}
