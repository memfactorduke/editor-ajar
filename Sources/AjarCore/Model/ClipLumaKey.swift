// SPDX-License-Identifier: GPL-3.0-or-later

/// Scalar luma-key controls for FR-COMP-005.
public enum ClipLumaKeyParameter: String, Equatable, Sendable {
    /// Lower luma threshold.
    case lowThreshold

    /// Upper luma threshold.
    case highThreshold

    /// Softness ramp width around the luma range.
    case softness
}

/// Luma-key controls for FR-COMP-005.
public struct ClipLumaKeySettings: Codable, Equatable, Sendable {
    /// Whether the keyer participates in rendering.
    public let enabled: Bool

    /// Lower bound of the luma range to remove, valid 0...1.
    public let lowThreshold: RationalValue

    /// Upper bound of the luma range to remove, valid 0...1.
    public let highThreshold: RationalValue

    /// Edge softness around the keyed luma range, valid 0...1.
    public let softness: RationalValue

    /// Whether to invert the resolved luma matte.
    public let invert: Bool

    /// Disabled keyer with stable default values.
    public static let disabled = ClipLumaKeySettings()

    /// Creates luma-key settings.
    public init(
        enabled: Bool = false,
        lowThreshold: RationalValue = .zero,
        highThreshold: RationalValue = .one,
        softness: RationalValue = .zero,
        invert: Bool = false
    ) {
        self.enabled = enabled
        self.lowThreshold = lowThreshold
        self.highThreshold = highThreshold
        self.softness = softness
        self.invert = invert
    }
}

/// Keyframable luma-key controls that evaluate to static render settings.
public struct AnimatableClipLumaKeySettings: Codable, Equatable, Sendable {
    /// Whether the keyer participates in rendering.
    public let enabled: Bool

    /// Lower bound of the luma range to remove.
    public let lowThreshold: Animatable<RationalValue>

    /// Upper bound of the luma range to remove.
    public let highThreshold: Animatable<RationalValue>

    /// Edge softness around the keyed luma range.
    public let softness: Animatable<RationalValue>

    /// Whether to invert the resolved luma matte.
    public let invert: Bool

    /// Disabled keyer with stable default values.
    public static let disabled = AnimatableClipLumaKeySettings.constant(.disabled)

    /// Creates keyframable luma-key settings.
    public init(
        enabled: Bool = false,
        lowThreshold: Animatable<RationalValue> = .constant(.zero),
        highThreshold: Animatable<RationalValue> = .constant(.one),
        softness: Animatable<RationalValue> = .constant(.zero),
        invert: Bool = false
    ) {
        self.enabled = enabled
        self.lowThreshold = lowThreshold
        self.highThreshold = highThreshold
        self.softness = softness
        self.invert = invert
    }

    /// Creates keyframable settings with constant values.
    public static func constant(
        _ settings: ClipLumaKeySettings
    ) -> AnimatableClipLumaKeySettings {
        AnimatableClipLumaKeySettings(
            enabled: settings.enabled,
            lowThreshold: .constant(settings.lowThreshold),
            highThreshold: .constant(settings.highThreshold),
            softness: .constant(settings.softness),
            invert: settings.invert
        )
    }

    /// Evaluates keyframable controls at a sequence time.
    public func value(at time: RationalTime) -> ClipLumaKeySettings {
        ClipLumaKeySettings(
            enabled: enabled,
            lowThreshold: lowThreshold.value(at: time),
            highThreshold: highThreshold.value(at: time),
            softness: softness.value(at: time),
            invert: invert
        )
    }

    /// Static settings represented by base keyframe values.
    public var baseSettings: ClipLumaKeySettings {
        ClipLumaKeySettings(
            enabled: enabled,
            lowThreshold: lowThreshold.base,
            highThreshold: highThreshold.base,
            softness: softness.base,
            invert: invert
        )
    }
}
