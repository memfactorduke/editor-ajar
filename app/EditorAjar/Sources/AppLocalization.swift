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
                "This format could not be converted into working media."
            )
        case .ffmpegUnavailable(_, let guidance):
            return localized("import.failure.ffmpegUnavailable", "\(guidance)")
        case .ffmpegFailed(_, let exitCode, let stderrTail):
            return localized(
                "import.failure.ffmpegFailed",
                "FFmpeg could not convert this file (exit \(exitCode)): \(stderrTail)"
            )
        case .transcodeCancelled:
            return localized("import.failure.transcodeCancelled", "The transcode was cancelled.")
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

    /// Localized explanation for a typed single-item relink preparation failure (FR-MED-007).
    ///
    /// Provenance-aware relink can re-run FFmpeg when the selected file matches a fallback
    /// import's original bytes (`matchedOriginalRequiresTranscode`); those failures surface
    /// through ``MediaRelinkCommandError/retranscodeFailed`` with the same install/convert
    /// guidance as import (#238).
    static func mediaRelinkFailureMessage(for error: MediaRelinkCommandError) -> String {
        switch error {
        case .mediaReferenceNotFound:
            return localized(
                "library.relink.mediaMissing",
                "The media reference to relink is no longer in the project."
            )
        case .duplicateMediaReferenceID:
            return localized(
                "library.relink.duplicateMediaID",
                "The project has more than one media reference with the same id."
            )
        case .sourceMustBeFileURL:
            return localized(
                "library.relink.localFileRequired",
                "Only files stored on this Mac can be used for relink."
            )
        case .folderUnavailable:
            return localized(
                "library.relink.folderUnavailable",
                "The selected folder is missing or cannot be read."
            )
        case .hashingFailed(_, let reason):
            return localized(
                "library.relink.hash",
                "The file could not be fingerprinted: \(reason)"
            )
        case .bookmarkCreationFailed(_, let reason):
            return localized(
                "library.relink.bookmark",
                "Editor Ajar could not save permission to reopen this file: \(reason)"
            )
        case .folderEnumerationFailed:
            return localized(
                "library.relink.folderScan",
                "The folder could not be scanned for matching media."
            )
        case .retranscodeFailed(let transcodeError):
            return mediaRelinkRetranscodeFailureMessage(for: transcodeError)
        }
    }

    /// Maps FFmpeg re-transcode failures during provenance-aware relink
    /// (shared install guidance with import).
    private static func mediaRelinkRetranscodeFailureMessage(
        for error: FFmpegTranscodeError
    ) -> String {
        switch error {
        case .ffmpegUnavailable(let guidance):
            // Same install guidance string as import.failure.ffmpegUnavailable (#238).
            return localized("import.failure.ffmpegUnavailable", "\(guidance)")
        case .ffmpegFailed(let exitCode, let stderrTail):
            return localized(
                "library.relink.retranscode.ffmpegFailed",
                "FFmpeg could not rebuild working media for relink (exit \(exitCode)): \(stderrTail)"
            )
        case .transcodeCancelled:
            return localized(
                "library.relink.retranscode.cancelled",
                "Rebuilding working media for relink was cancelled."
            )
        case .transcodeTimedOut(let reason):
            return localized(
                "library.relink.retranscode.timedOut",
                "Rebuilding working media for relink timed out: \(reason)"
            )
        case .transactionFailed(let reason):
            return localized(
                "library.relink.retranscode.transactionFailed",
                "Could not rebuild working media for relink: \(reason)"
            )
        }
    }
}
