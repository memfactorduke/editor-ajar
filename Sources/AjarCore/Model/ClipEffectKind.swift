// SPDX-License-Identifier: GPL-3.0-or-later

/// Stable registry / codec identity for a built-in video effect kind (ADR-0016, FR-FX-002/003).
public enum ClipEffectKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// Minimal bootstrap kind so the stack schema has one concrete case.
    ///
    /// Real library kinds land under FR-FX-002 as additional cases without reshaping the stack.
    /// Adding a case **must** bump `AjarProjectCodec.currentSchemaMinor` (ADR-0018).
    case placeholder

    /// Separable Gaussian blur (FR-FX-002).
    case gaussianBlur

    /// Separable box blur (FR-FX-002).
    case boxBlur

    /// Zoom / radial blur from a normalized center (FR-FX-002).
    case zoomBlur

    /// Unsharp-mask style sharpen (FR-FX-002).
    case sharpen

    /// Soft glow via blurred highlight lift (FR-FX-002).
    case glow

    /// Decodes a kind string; unknown raw values become `ClipEffectDecodingError.unknownKind`
    /// (not a bare `DecodingError`) so callers can surface the newer-project situation (ADR-0018).
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let kind = ClipEffectKind(rawValue: raw) else {
            throw ClipEffectDecodingError.unknownKind(raw)
        }
        self = kind
    }

    /// Encodes the stable kind raw string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
