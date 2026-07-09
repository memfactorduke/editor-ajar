// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Shared ranges (FR-FX-002)

/// Documented parameter ranges for the FR-FX-002 blur/sharpen/glow library kinds.
public enum ClipEffectLibraryLimits {
    /// Max Gaussian / glow blur radius (source pixels).
    public static let maximumBlurRadius = RationalValue(64)
    /// Max single-pass box-blur radius (tap budget; multi-pass later for larger).
    public static let maximumBoxBlurRadius = RationalValue(16)
    /// Max sharpen kernel radius (source pixels).
    public static let maximumSharpenRadius = RationalValue(8)
}

// MARK: - Gaussian blur

/// Static Gaussian blur parameters (FR-FX-002). `radius` is 0...64 source pixels (0 = identity).
public struct ClipGaussianBlurParameters: Codable, Equatable, Sendable {
    /// Blur radius in source pixels (0...64). Zero is identity.
    public let radius: RationalValue

    private enum CodingKeys: String, CodingKey {
        case radius
    }

    /// Identity parameters (no-op radius).
    public static let identity = ClipGaussianBlurParameters(radius: .zero)

    /// Creates Gaussian blur parameters.
    public init(radius: RationalValue = .zero) {
        self.radius = radius
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius = try container.decodeIfPresent(RationalValue.self, forKey: .radius) ?? .zero
    }
}

/// Keyframable parameters for the Gaussian blur effect kind.
public struct AnimatableClipGaussianBlurSettings: Codable, Equatable, Sendable {
    /// Keyframable blur radius in source pixels.
    public let radius: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case radius
    }

    /// Identity parameters (constant zero radius).
    public static let identity = AnimatableClipGaussianBlurSettings(radius: .constant(.zero))

    /// Creates keyframable Gaussian blur parameters.
    public init(radius: Animatable<RationalValue> = .constant(.zero)) {
        self.radius = radius
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .radius
            ) ?? .constant(.zero)
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipGaussianBlurParameters
    ) -> AnimatableClipGaussianBlurSettings {
        AnimatableClipGaussianBlurSettings(radius: .constant(parameters.radius))
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipGaussianBlurParameters {
        ClipGaussianBlurParameters(radius: radius.value(at: time))
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipGaussianBlurParameters {
        ClipGaussianBlurParameters(radius: radius.base)
    }
}

// MARK: - Box blur

/// Static box blur parameters (FR-FX-002). `radius` is 0...16 (single-pass; multi-pass later).
public struct ClipBoxBlurParameters: Codable, Equatable, Sendable {
    /// Blur radius in source pixels (0...16). Zero is identity.
    public let radius: RationalValue

    private enum CodingKeys: String, CodingKey {
        case radius
    }

    /// Identity parameters (no-op radius).
    public static let identity = ClipBoxBlurParameters(radius: .zero)

    /// Creates box blur parameters.
    public init(radius: RationalValue = .zero) {
        self.radius = radius
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius = try container.decodeIfPresent(RationalValue.self, forKey: .radius) ?? .zero
    }
}

/// Keyframable parameters for the box blur effect kind.
public struct AnimatableClipBoxBlurSettings: Codable, Equatable, Sendable {
    /// Keyframable blur radius in source pixels.
    public let radius: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case radius
    }

    /// Identity parameters (constant zero radius).
    public static let identity = AnimatableClipBoxBlurSettings(radius: .constant(.zero))

    /// Creates keyframable box blur parameters.
    public init(radius: Animatable<RationalValue> = .constant(.zero)) {
        self.radius = radius
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .radius
            ) ?? .constant(.zero)
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipBoxBlurParameters
    ) -> AnimatableClipBoxBlurSettings {
        AnimatableClipBoxBlurSettings(radius: .constant(parameters.radius))
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipBoxBlurParameters {
        ClipBoxBlurParameters(radius: radius.value(at: time))
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipBoxBlurParameters {
        ClipBoxBlurParameters(radius: radius.base)
    }
}

// MARK: - Zoom / radial blur

/// Static parameters for the zoom (radial) blur effect kind (FR-FX-002).
///
/// `amount` is normalized 0...1 (zero is identity). `centerX` / `centerY` are normalized
/// UV coordinates in 0...1 (0.5, 0.5 is frame center).
public struct ClipZoomBlurParameters: Codable, Equatable, Sendable {
    /// Normalized zoom strength (0...1). Zero is identity.
    public let amount: RationalValue

    /// Normalized horizontal center (0...1).
    public let centerX: RationalValue

    /// Normalized vertical center (0...1).
    public let centerY: RationalValue

    private enum CodingKeys: String, CodingKey {
        case amount
        case centerX
        case centerY
    }

    /// Identity parameters (no-op amount, centered).
    public static let identity = ClipZoomBlurParameters(
        amount: .zero,
        centerX: RationalValue.approximating(0.5),
        centerY: RationalValue.approximating(0.5)
    )

    /// Creates zoom blur parameters.
    public init(
        amount: RationalValue = .zero,
        centerX: RationalValue = RationalValue.approximating(0.5),
        centerY: RationalValue = RationalValue.approximating(0.5)
    ) {
        self.amount = amount
        self.centerX = centerX
        self.centerY = centerY
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decodeIfPresent(RationalValue.self, forKey: .amount) ?? .zero
        centerX =
            try container.decodeIfPresent(RationalValue.self, forKey: .centerX)
            ?? RationalValue.approximating(0.5)
        centerY =
            try container.decodeIfPresent(RationalValue.self, forKey: .centerY)
            ?? RationalValue.approximating(0.5)
    }
}

/// Keyframable parameters for the zoom blur effect kind.
public struct AnimatableClipZoomBlurSettings: Codable, Equatable, Sendable {
    /// Keyframable normalized zoom strength.
    public let amount: Animatable<RationalValue>

    /// Keyframable normalized horizontal center.
    public let centerX: Animatable<RationalValue>

    /// Keyframable normalized vertical center.
    public let centerY: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case amount
        case centerX
        case centerY
    }

    /// Identity parameters (constant zero amount, centered).
    public static let identity = AnimatableClipZoomBlurSettings(
        amount: .constant(.zero),
        centerX: .constant(RationalValue.approximating(0.5)),
        centerY: .constant(RationalValue.approximating(0.5))
    )

    /// Creates keyframable zoom blur parameters.
    public init(
        amount: Animatable<RationalValue> = .constant(.zero),
        centerX: Animatable<RationalValue> = .constant(RationalValue.approximating(0.5)),
        centerY: Animatable<RationalValue> = .constant(RationalValue.approximating(0.5))
    ) {
        self.amount = amount
        self.centerX = centerX
        self.centerY = centerY
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .amount
            ) ?? .constant(.zero)
        centerX =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .centerX
            ) ?? .constant(RationalValue.approximating(0.5))
        centerY =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .centerY
            ) ?? .constant(RationalValue.approximating(0.5))
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipZoomBlurParameters
    ) -> AnimatableClipZoomBlurSettings {
        AnimatableClipZoomBlurSettings(
            amount: .constant(parameters.amount),
            centerX: .constant(parameters.centerX),
            centerY: .constant(parameters.centerY)
        )
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipZoomBlurParameters {
        ClipZoomBlurParameters(
            amount: amount.value(at: time),
            centerX: centerX.value(at: time),
            centerY: centerY.value(at: time)
        )
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipZoomBlurParameters {
        ClipZoomBlurParameters(
            amount: amount.base,
            centerX: centerX.base,
            centerY: centerY.base
        )
    }
}

// MARK: - Sharpen

/// Static parameters for the sharpen effect kind (FR-FX-002).
///
/// `amount` is normalized 0...1 (zero is identity). `radius` is in source pixels, 0...8.
public struct ClipSharpenParameters: Codable, Equatable, Sendable {
    /// Normalized sharpen strength (0...1). Zero is identity.
    public let amount: RationalValue

    /// Kernel radius in source pixels (0...8).
    public let radius: RationalValue

    private enum CodingKeys: String, CodingKey {
        case amount
        case radius
    }

    /// Identity parameters (no-op amount, unit radius).
    public static let identity = ClipSharpenParameters(amount: .zero, radius: .one)

    /// Creates sharpen parameters.
    public init(amount: RationalValue = .zero, radius: RationalValue = .one) {
        self.amount = amount
        self.radius = radius
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decodeIfPresent(RationalValue.self, forKey: .amount) ?? .zero
        radius = try container.decodeIfPresent(RationalValue.self, forKey: .radius) ?? .one
    }
}

/// Keyframable parameters for the sharpen effect kind.
public struct AnimatableClipSharpenSettings: Codable, Equatable, Sendable {
    /// Keyframable normalized sharpen strength.
    public let amount: Animatable<RationalValue>

    /// Keyframable kernel radius in source pixels.
    public let radius: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case amount
        case radius
    }

    /// Identity parameters (constant zero amount).
    public static let identity = AnimatableClipSharpenSettings(
        amount: .constant(.zero),
        radius: .constant(.one)
    )

    /// Creates keyframable sharpen parameters.
    public init(
        amount: Animatable<RationalValue> = .constant(.zero),
        radius: Animatable<RationalValue> = .constant(.one)
    ) {
        self.amount = amount
        self.radius = radius
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .amount
            ) ?? .constant(.zero)
        radius =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .radius
            ) ?? .constant(.one)
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipSharpenParameters
    ) -> AnimatableClipSharpenSettings {
        AnimatableClipSharpenSettings(
            amount: .constant(parameters.amount),
            radius: .constant(parameters.radius)
        )
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipSharpenParameters {
        ClipSharpenParameters(
            amount: amount.value(at: time),
            radius: radius.value(at: time)
        )
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipSharpenParameters {
        ClipSharpenParameters(amount: amount.base, radius: radius.base)
    }
}

// MARK: - Glow

/// Static parameters for the glow effect kind (FR-FX-002).
///
/// `radius` is in source pixels (0...64). `amount` is normalized 0...1. Both zero is identity
/// (zero amount alone is also identity regardless of radius).
public struct ClipGlowParameters: Codable, Equatable, Sendable {
    /// Glow blur radius in source pixels (0...64).
    public let radius: RationalValue

    /// Normalized glow strength (0...1). Zero is identity.
    public let amount: RationalValue

    private enum CodingKeys: String, CodingKey {
        case radius
        case amount
    }

    /// Identity parameters (no-op glow).
    public static let identity = ClipGlowParameters(radius: .zero, amount: .zero)

    /// Creates glow parameters.
    public init(radius: RationalValue = .zero, amount: RationalValue = .zero) {
        self.radius = radius
        self.amount = amount
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius = try container.decodeIfPresent(RationalValue.self, forKey: .radius) ?? .zero
        amount = try container.decodeIfPresent(RationalValue.self, forKey: .amount) ?? .zero
    }
}

/// Keyframable parameters for the glow effect kind.
public struct AnimatableClipGlowSettings: Codable, Equatable, Sendable {
    /// Keyframable glow blur radius in source pixels.
    public let radius: Animatable<RationalValue>

    /// Keyframable normalized glow strength.
    public let amount: Animatable<RationalValue>

    private enum CodingKeys: String, CodingKey {
        case radius
        case amount
    }

    /// Identity parameters (constant zeros).
    public static let identity = AnimatableClipGlowSettings(
        radius: .constant(.zero),
        amount: .constant(.zero)
    )

    /// Creates keyframable glow parameters.
    public init(
        radius: Animatable<RationalValue> = .constant(.zero),
        amount: Animatable<RationalValue> = .constant(.zero)
    ) {
        self.radius = radius
        self.amount = amount
    }

    /// Decodes with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .radius
            ) ?? .constant(.zero)
        amount =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .amount
            ) ?? .constant(.zero)
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipGlowParameters
    ) -> AnimatableClipGlowSettings {
        AnimatableClipGlowSettings(
            radius: .constant(parameters.radius),
            amount: .constant(parameters.amount)
        )
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipGlowParameters {
        ClipGlowParameters(
            radius: radius.value(at: time),
            amount: amount.value(at: time)
        )
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipGlowParameters {
        ClipGlowParameters(radius: radius.base, amount: amount.base)
    }
}
