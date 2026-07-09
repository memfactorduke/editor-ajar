// SPDX-License-Identifier: GPL-3.0-or-later

/// Typed failures while decoding effect stack payloads (ADR-0018).
public enum ClipEffectDecodingError: Error, Equatable, Sendable {
    /// A `ClipEffectKind` raw string is not known to this build.
    ///
    /// Usually means the project was saved by a newer Editor Ajar that added library kinds
    /// (FR-FX-002) and bumped `schemaMinor`. Prefer opening via `AjarProjectCodec` so same-major
    /// higher-minor files become read-only before edit/resave can strip data (FR-PROJ-005).
    case unknownKind(String)

    /// Clear diagnostic for callers and tests.
    public var message: String {
        switch self {
        case .unknownKind(let raw):
            "Unknown clip effect kind \"\(raw)\". This project may have been saved by a newer "
                + "Editor Ajar (higher schema minor / FR-FX library kinds). Open it in a build "
                + "that supports that schema, or open read-only when the minor gate applies "
                + "(FR-PROJ-005, ADR-0018)."
        }
    }
}
