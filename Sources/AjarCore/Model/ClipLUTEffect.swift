// SPDX-License-Identifier: GPL-3.0-or-later

/// Where a LUT sits in the FR-COL-004 grading chain (input / transform / look).
///
/// **v1 render positioning:** `input` LUTs run on linear working color *before* the fixed
/// primary grade (`ClipColorCorrection`). `transform` and `look` both run *after* that grade
/// in the same stage — transform == look positioning is intentional v1 behavior until a
/// dedicated transform slot is split out.
public enum ClipLUTPlacement: String, Codable, Equatable, Sendable, CaseIterable {
    /// Applied pre-grade on source linear color (input LUT).
    case input

    /// Applied post-grade (v1: same stage as `look`).
    case transform

    /// Applied post-grade as a creative look (default).
    case look
}

/// Static parameters for the FR-COL-004 LUT effect kind.
///
/// The parsed `.cube` table is stored **inline** on the node (ADR-0016 Codable discipline).
/// Strength is normalized 0...1; zero is a documented no-op identity mix.
public struct ClipLUTEffectParameters: Codable, Equatable, Sendable {
    /// Parsed LUT payload (1D or 3D), size-capped by ``CubeLUTLimits``.
    public let table: CubeLUTTable

    /// Mix strength in 0...1: `mix(identity, lutSample, strength)`.
    public let strength: RationalValue

    /// Chain placement (FR-COL-004 input / transform / look). Defaults to `.look`.
    public let placement: ClipLUTPlacement

    private enum CodingKeys: String, CodingKey {
        case table
        case strength
        case placement
    }

    /// Creates LUT parameters. Callers must supply a validated table; strength defaults to full;
    /// placement defaults to look.
    public init(
        table: CubeLUTTable,
        strength: RationalValue = .one,
        placement: ClipLUTPlacement = .look
    ) {
        self.table = table
        self.strength = strength
        self.placement = placement
    }

    /// Decodes LUT parameters with legacy-safe defaults (strength 1, placement look).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        table = try container.decode(CubeLUTTable.self, forKey: .table)
        strength = try container.decodeIfPresent(RationalValue.self, forKey: .strength) ?? .one
        placement =
            try container.decodeIfPresent(ClipLUTPlacement.self, forKey: .placement) ?? .look
    }
}

/// Keyframable parameters for the FR-COL-004 LUT effect kind.
///
/// The LUT table and placement are constant on the node (not keyframed). Strength is keyframable.
public struct AnimatableClipLUTSettings: Codable, Equatable, Sendable {
    /// Constant LUT payload.
    public let table: CubeLUTTable

    /// Keyframable mix strength in 0...1.
    public let strength: Animatable<RationalValue>

    /// Constant chain placement.
    public let placement: ClipLUTPlacement

    private enum CodingKeys: String, CodingKey {
        case table
        case strength
        case placement
    }

    /// Creates keyframable LUT parameters.
    public init(
        table: CubeLUTTable,
        strength: Animatable<RationalValue> = .constant(.one),
        placement: ClipLUTPlacement = .look
    ) {
        self.table = table
        self.strength = strength
        self.placement = placement
    }

    /// Decodes keyframable LUT parameters with legacy-safe defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        table = try container.decode(CubeLUTTable.self, forKey: .table)
        strength =
            try container.decodeIfPresent(
                Animatable<RationalValue>.self,
                forKey: .strength
            ) ?? .constant(.one)
        placement =
            try container.decodeIfPresent(ClipLUTPlacement.self, forKey: .placement) ?? .look
    }

    /// Creates keyframable parameters with constant values.
    public static func constant(
        _ parameters: ClipLUTEffectParameters
    ) -> AnimatableClipLUTSettings {
        AnimatableClipLUTSettings(
            table: parameters.table,
            strength: .constant(parameters.strength),
            placement: parameters.placement
        )
    }

    /// Evaluates parameters at a sequence time.
    public func value(at time: RationalTime) -> ClipLUTEffectParameters {
        ClipLUTEffectParameters(
            table: table,
            strength: strength.value(at: time),
            placement: placement
        )
    }

    /// Static parameters represented by base keyframe values.
    public var baseParameters: ClipLUTEffectParameters {
        ClipLUTEffectParameters(table: table, strength: strength.base, placement: placement)
    }
}

extension CubeLUTTable {
    /// Smallest valid identity 1D ramp (2 samples: black → white), used for LUT reset identity.
    public static let identityOneD = CubeLUTTable(
        title: nil,
        dimensions: .oneD,
        size: 2,
        domainMin: .zero,
        domainMax: .one,
        entries: [.zero, .one]
    )

    /// Identity 1D ramp of arbitrary legal size (for texel-center tests).
    public static func identityOneD(size: Int) -> CubeLUTTable {
        let clamped = max(CubeLUTLimits.minimumSize, min(size, CubeLUTLimits.maximumOneDSize))
        let denom = Float(clamped - 1)
        var entries: [CubeLUTColor] = []
        entries.reserveCapacity(clamped)
        for index in 0..<clamped {
            let value = Float(index) / denom
            entries.append(CubeLUTColor(r: value, g: value, b: value))
        }
        return CubeLUTTable(
            title: nil,
            dimensions: .oneD,
            size: clamped,
            domainMin: .zero,
            domainMax: .one,
            entries: entries
        )
    }

    /// Smallest valid identity 3D lattice (2³), used as a dummy shader binding when needed.
    public static let identity3D: CubeLUTTable = {
        let size = 2
        var entries: [CubeLUTColor] = []
        entries.reserveCapacity(size * size * size)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let denom = Float(size - 1)
                    entries.append(
                        CubeLUTColor(
                            r: Float(red) / denom,
                            g: Float(green) / denom,
                            b: Float(blue) / denom
                        )
                    )
                }
            }
        }
        return CubeLUTTable(
            title: nil,
            dimensions: .threeD,
            size: size,
            domainMin: .zero,
            domainMax: .one,
            entries: entries
        )
    }()

    /// Alias retained for call sites that used the older name.
    public static let identityOneDAs3D = identity3D
}
