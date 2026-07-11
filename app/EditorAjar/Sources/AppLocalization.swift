// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
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

    /// Localized per-file explanation for a typed media import failure.
    static func mediaImportFailureMessage(for error: MediaImportError) -> String {
        switch error {
        case .sourceMustBeFileURL:
            return localized(
                "import.failure.localFileRequired",
                "Only files and folders stored on this Mac can be imported."
            )
        case .sourceUnavailable:
            return localized(
                "import.failure.unavailable",
                "The file or folder is missing or cannot be read."
            )
        case .folderEnumerationFailed(_, let reason):
            return localized(
                "import.failure.folderScan",
                "The folder could not be scanned: \(reason)"
            )
        case .unsupportedFormat:
            return localized(
                "import.failure.unsupportedFormat",
                "This format is not supported by the native importer. The FFmpeg import fallback is not available in this build."
            )
        case .probingFailed(_, let reason):
            return localized(
                "import.failure.probe",
                "The file's media information could not be read: \(reason)"
            )
        case .conformRateUnavailable:
            return localized(
                "import.failure.vfrConform",
                "Variable frame rate was detected, but a stable playback rate could not be chosen."
            )
        case .hashingFailed(_, let reason):
            return localized(
                "import.failure.hash",
                "The file could not be fingerprinted: \(reason)"
            )
        case .bookmarkCreationFailed(_, let reason):
            return localized(
                "import.failure.bookmark",
                "Editor Ajar could not save permission to reopen this file: \(reason)"
            )
        case .projectUpdateFailed(_, let reason):
            return localized(
                "import.failure.projectUpdate",
                "The file was prepared but could not be added to the project: \(reason)"
            )
        }
    }
}
