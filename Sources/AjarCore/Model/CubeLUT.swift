// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Dimensionality of a parsed `.cube` LUT (FR-COL-004).
public enum CubeLUTDimensions: String, Codable, Equatable, Sendable {
    /// One-dimensional ramp table (`LUT_1D_SIZE`).
    case oneD = "1d"

    /// Three-dimensional lattice (`LUT_3D_SIZE`).
    case threeD = "3d"
}

/// One RGB sample in a `.cube` table, stored as IEEE-754 single-precision components.
///
/// Values are not clamped on decode: domain and out-of-range table entries are legal in the
/// `.cube` format and are applied as authored during sampling.
public struct CubeLUTColor: Codable, Equatable, Sendable {
    /// Red component.
    public let r: Float

    /// Green component.
    public let g: Float

    /// Blue component.
    public let b: Float

    /// Neutral black.
    public static let zero = CubeLUTColor(r: 0, g: 0, b: 0)

    /// Neutral white.
    public static let one = CubeLUTColor(r: 1, g: 1, b: 1)

    /// Creates an RGB triple.
    public init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Size and payload ceilings for `.cube` tables kept inline on effect nodes (FR-COL-004,
/// ADR-0016 Codable discipline).
public enum CubeLUTLimits {
    /// Minimum inclusive lattice edge length (1D length or 3D edge).
    public static let minimumSize = 2

    /// Maximum inclusive 1D table length.
    public static let maximumOneDSize = 4_096

    /// Maximum inclusive 3D lattice edge.
    public static let maximumThreeDSize = 64

    /// Absolute maximum RGB rows any legal table can hold (`64³`).
    public static let absoluteMaximumEntryCount =
        maximumThreeDSize * maximumThreeDSize * maximumThreeDSize

    /// Returns the maximum legal size for `dimensions`.
    public static func maximumSize(for dimensions: CubeLUTDimensions) -> Int {
        switch dimensions {
        case .oneD:
            maximumOneDSize
        case .threeD:
            maximumThreeDSize
        }
    }

    /// Expected number of RGB rows for a table of `size` and `dimensions`.
    public static func expectedEntryCount(size: Int, dimensions: CubeLUTDimensions) -> Int? {
        guard size >= minimumSize else {
            return nil
        }
        switch dimensions {
        case .oneD:
            guard size <= maximumOneDSize else {
                return nil
            }
            return size
        case .threeD:
            guard size <= maximumThreeDSize else {
                return nil
            }
            let squared = size * size
            return squared * size
        }
    }
}

/// Parsed `.cube` LUT payload stored inline on a `lut` effect node (FR-COL-004).
///
/// `contentDigest` is a stable SHA-256 of the sampling-relevant payload (dimensions, size,
/// domain, entries). Render-graph content hashes and GPU texture caches key on this digest
/// so graph builds never re-encode the full lattice.
public struct CubeLUTTable: Codable, Equatable, Sendable {
    /// Optional `TITLE` from the file (informational; not used by sampling).
    public let title: String?

    /// Lattice dimensionality.
    public let dimensions: CubeLUTDimensions

    /// Edge length (3D) or ramp length (1D).
    public let size: Int

    /// Domain lower bound (`DOMAIN_MIN`), default black.
    public let domainMin: CubeLUTColor

    /// Domain upper bound (`DOMAIN_MAX`), default white.
    public let domainMax: CubeLUTColor

    /// Table entries in `.cube` order: 1D is `size` RGB rows; 3D is `size³` rows in
    /// blue-major / green-middle / red-minor order (standard `.cube` lattice walk).
    public let entries: [CubeLUTColor]

    /// Stable digest of sampling-relevant payload (computed once at init / parse).
    public let contentDigest: ContentHash

    private enum CodingKeys: String, CodingKey {
        case title
        case dimensions
        case size
        case domainMin
        case domainMax
        case entries
    }

    /// Creates a table. Callers should validate via ``CubeLUTTable/validated()`` before
    /// attaching the table to a project node. Digest is computed from the sampling payload.
    public init(
        title: String? = nil,
        dimensions: CubeLUTDimensions,
        size: Int,
        domainMin: CubeLUTColor = .zero,
        domainMax: CubeLUTColor = .one,
        entries: [CubeLUTColor]
    ) {
        self.title = title
        self.dimensions = dimensions
        self.size = size
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.entries = entries
        self.contentDigest = Self.computeDigest(
            dimensions: dimensions,
            size: size,
            domainMin: domainMin,
            domainMax: domainMax,
            entries: entries
        )
    }

    /// Decodes a table and recomputes the content digest from entries (NFR-STAB-003).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let dimensions = try container.decode(CubeLUTDimensions.self, forKey: .dimensions)
        let size = try container.decode(Int.self, forKey: .size)
        let domainMin = try container.decodeIfPresent(CubeLUTColor.self, forKey: .domainMin)
            ?? .zero
        let domainMax = try container.decodeIfPresent(CubeLUTColor.self, forKey: .domainMax)
            ?? .one
        let entries = try container.decodeIfPresent([CubeLUTColor].self, forKey: .entries) ?? []
        self.init(
            title: title,
            dimensions: dimensions,
            size: size,
            domainMin: domainMin,
            domainMax: domainMax,
            entries: entries
        )
    }

    /// Encodes the table without persisting the derived digest (recomputed on decode).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(dimensions, forKey: .dimensions)
        try container.encode(size, forKey: .size)
        try container.encode(domainMin, forKey: .domainMin)
        try container.encode(domainMax, forKey: .domainMax)
        try container.encode(entries, forKey: .entries)
    }

    /// Returns `self` when size/entry/domain stay legal; otherwise a typed validation error.
    public func validated() -> Result<CubeLUTTable, CubeLUTValidationError> {
        guard size >= CubeLUTLimits.minimumSize else {
            return .failure(.sizeOutOfRange(size: size, dimensions: dimensions))
        }
        let maximum = CubeLUTLimits.maximumSize(for: dimensions)
        guard size <= maximum else {
            return .failure(.sizeOutOfRange(size: size, dimensions: dimensions))
        }
        guard let expected = CubeLUTLimits.expectedEntryCount(size: size, dimensions: dimensions)
        else {
            return .failure(.sizeOutOfRange(size: size, dimensions: dimensions))
        }
        guard entries.count == expected else {
            return .failure(
                .entryCountMismatch(
                    expected: expected,
                    actual: entries.count,
                    dimensions: dimensions,
                    size: size
                )
            )
        }
        if let channel = Self.invalidDomainChannel(min: domainMin, max: domainMax) {
            return .failure(.domainMinNotLessThanMax(channel: channel))
        }
        return .success(self)
    }

    /// Channel name when `domainMin` is not strictly less than `domainMax`.
    public static func invalidDomainChannel(
        min: CubeLUTColor,
        max: CubeLUTColor
    ) -> String? {
        if !(min.r < max.r) {
            return "r"
        }
        if !(min.g < max.g) {
            return "g"
        }
        if !(min.b < max.b) {
            return "b"
        }
        return nil
    }

    /// SHA-256 over a compact binary of sampling-relevant fields (not title).
    public static func computeDigest(
        dimensions: CubeLUTDimensions,
        size: Int,
        domainMin: CubeLUTColor,
        domainMax: CubeLUTColor,
        entries: [CubeLUTColor]
    ) -> ContentHash {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16 + entries.count * 12)
        bytes.append(contentsOf: Array(dimensions.rawValue.utf8))
        bytes.append(0)
        appendFloatBits(Float(size), to: &bytes)
        appendColorBits(domainMin, to: &bytes)
        appendColorBits(domainMax, to: &bytes)
        for entry in entries {
            appendColorBits(entry, to: &bytes)
        }
        return ContentHash.sha256(bytes: bytes)
    }

    private static func appendColorBits(_ color: CubeLUTColor, to bytes: inout [UInt8]) {
        appendFloatBits(color.r, to: &bytes)
        appendFloatBits(color.g, to: &bytes)
        appendFloatBits(color.b, to: &bytes)
    }

    private static func appendFloatBits(_ value: Float, to bytes: inout [UInt8]) {
        var bitPattern = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bitPattern) { buffer in
            bytes.append(contentsOf: buffer)
        }
    }
}

/// Typed validation failures for an embedded LUT table payload (FR-COL-004).
public enum CubeLUTValidationError: Error, Equatable, Sendable {
    /// Size is outside the inclusive limits for `dimensions`.
    case sizeOutOfRange(size: Int, dimensions: CubeLUTDimensions)

    /// Entry row count does not match `size` / `dimensions`.
    case entryCountMismatch(
        expected: Int,
        actual: Int,
        dimensions: CubeLUTDimensions,
        size: Int
    )

    /// `DOMAIN_MIN` is not strictly less than `DOMAIN_MAX` on a channel.
    case domainMinNotLessThanMax(channel: String)

    /// Clear diagnostic for callers and tests.
    public var message: String {
        switch self {
        case .sizeOutOfRange(let size, let dimensions):
            let maximum = CubeLUTLimits.maximumSize(for: dimensions)
            return
                "LUT \(dimensions.rawValue) size \(size) is outside \(CubeLUTLimits.minimumSize)"
                + "...\(maximum) (FR-COL-004 project payload ceiling)"
        case .entryCountMismatch(let expected, let actual, let dimensions, let size):
            return
                "LUT \(dimensions.rawValue) size \(size) expects \(expected) RGB rows but has "
                + "\(actual)"
        case .domainMinNotLessThanMax(let channel):
            return "LUT DOMAIN_MIN.\(channel) must be strictly less than DOMAIN_MAX.\(channel)"
        }
    }
}
