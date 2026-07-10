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

    /// Imported `.cube` 1D/3D LUT with keyframable strength (FR-COL-004).
    ///
    /// Introduced at `schemaMinor` **3** (ADR-0018): minor 2 is FR-FX-002 batch 1 (#181);
    /// later minors 4–6 cover title styling, FX batch 2, and video transitions.
    case lut

    /// Radial edge darkening with configurable falloff (FR-FX-002).
    case vignette

    /// Horizontal, vertical, or four-quadrant mirroring (FR-FX-002).
    case mirror

    /// Source-pixel mosaic / pixelation (FR-FX-002).
    case mosaic

    /// Basic brightness, contrast, saturation, and tint adjustment (FR-FX-002).
    case colorAdjust

    /// Discrete color-level posterization (FR-FX-002).
    case posterize

    /// Linear-working-space RGB inversion (FR-FX-002).
    case invert

    /// RGB master + per-channel color curves (FR-COL-002, M8). Secondary curves stay v1.x.
    ///
    /// Introduced at `schemaMinor` **8** (ADR-0018). Minor 7 is FR-TXT-004 title presets
    /// (`revealFraction`, #186); this kind renumbered from the 7/8 race.
    case curves

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
