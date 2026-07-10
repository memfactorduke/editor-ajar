// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Central String Catalog accessor for the EditorAjar app target (NFR-I18N-001).
///
/// Every user-visible string in the app resolves through here so the base English text lives
/// behind stable, per-surface keys and `Localizable.xcstrings` can grow additional languages
/// without touching call sites. English is the base language and ships today.
///
/// **Accessibility identifiers are deliberately NOT routed through this type.** They stay stable,
/// non-localized literals that XCUITests query by (`EditorAjarAccessibilityTreeTests`, the UI-smoke
/// suite). Only visible/spoken text — `Text`, button titles, `.help`, and
/// `accessibilityLabel`/`Value`/`Hint` — is localized. Keeping the English values byte-identical to
/// the pre-externalization literals means identifier- and label-matched UI queries stay green.
enum AppString {
    /// Resolves `key` from `Localizable.xcstrings`, falling back to the interpolated `english`
    /// value when the catalog lacks the key (which is also the base-language string we ship).
    ///
    /// Interpolating into `english` (e.g. `"Video track \(index)"`) lets the compiler derive the
    /// format placeholders for the catalog automatically, so call sites stay type-safe.
    static func localized(
        _ key: StaticString,
        _ english: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: english, bundle: .main)
    }

    // MARK: - Core → app mapping (CORE PURITY BOUNDARY)
    //
    // `AjarCore` stays platform-pure and returns TYPED VALUES; it never carries localization
    // machinery. The app maps each typed case to a catalog key here. `AjarCore`'s own
    // `AjarProjectReadOnlyReason.message` remains English and developer-facing — it backs the
    // `ajar` CLI (AjarCLIError), which ships in English by design.

    /// Localized read-only banner / refusal copy for a typed open reason (FR-PROJ-005, ADR-0018).
    static func readOnlyProjectMessage(for reason: AjarProjectReadOnlyReason) -> String {
        switch reason {
        case .newerSchemaMinor(let found, let supported):
            return localized(
                "project.readOnly.newerSchemaMinor",
                """
                This project uses schema minor version \(found), but this build supports up to \
                \(supported) (major \(AjarProjectCodec.currentSchemaVersion)). It can be opened \
                read-only; saving is disabled so newer data is not stripped (FR-PROJ-005).
                """
            )
        }
    }
}
