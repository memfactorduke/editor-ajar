// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

/// NFR-I18N-001 localization-readiness net.
///
/// Verifies the base-English String Catalog ships in the app bundle, that representative per-surface
/// keys resolve to their English values through a `Bundle` lookup, that unknown keys fall through
/// unchanged, and that the `AjarCore` typed-value → catalog mapping produces localized copy without
/// pulling localization machinery into the pure core.
final class EditorAjarLocalizationTests: XCTestCase {
    /// The app bundle that hosts these unit tests owns the compiled `Localizable` table.
    private var appBundle: Bundle { Bundle(for: EditorAjarAppModel.self) }

    // A missing entry returns the key unchanged when `value` is nil (NSLocalizedString convention).
    private func catalogValue(_ key: String) -> String {
        appBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    // MARK: - (a) Catalog resource loads and contains representative keys

    func testNFRI18N001CatalogResourceIsPresentInAppBundle() {
        // The compiled String Catalog surfaces as a `Localizable.strings` table in a `.lproj`.
        let englishTable = appBundle.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"
        )
        let baseTable = appBundle.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "Base"
        )
        XCTAssertTrue(
            englishTable != nil || baseTable != nil,
            "Localizable catalog table must ship in the app bundle (en or Base .lproj)."
        )
    }

    func testNFRI18N001CatalogContainsRepresentativePerSurfaceKeys() {
        // One representative key per major surface; values are the shipping English base strings.
        let expected: [String: String] = [
            "app.name": "Editor Ajar",
            "workspace.header.export": "Export…",
            "banner.readOnly.title": "Read-only project",
            "sequenceTabs.new": "New Sequence",
            "transport.play": "Play",
            "inspector.title": "Inspector",
            "timeline.tool.fit": "Fit Timeline",
            "export.dialog.title": "Export",
            "exportQueue.title": "Export Queue",
            "import.summary.title": "Media Import Summary",
            "import.summary.empty": "No media files were found in the selection.",
            "import.failure.projectUpdate.reason": "The open project rejected the import batch.",
            "import.failure.unsupportedFormat":
                "This format is not supported by the native importer. The FFmpeg import fallback is not available in this build.",
            "library.panel.ax":
                "Media and effects panel. Drop media files or folders here to import.",
            "marker.color.red": "Red",
            "blend.normal": "Normal",
            "transform.param.position": "Position",
            "state.selected": "Selected",
        ]
        for (key, english) in expected {
            XCTAssertEqual(
                catalogValue(key), english,
                "Catalog key \(key) should resolve to its English base value."
            )
        }
    }

    // MARK: - (b) Key-echo smoke

    func testNFRI18N001KnownKeysResolveAndBogusKeyFallsThrough() {
        // Known key resolves to English (not echoed back as the key).
        let known = "menu.export.open.ax"
        XCTAssertEqual(catalogValue(known), "Open export dialog")
        XCTAssertNotEqual(catalogValue(known), known)

        // Unknown key falls through unchanged.
        let bogus = "totally.bogus.key.\(UUID().uuidString)"
        XCTAssertEqual(catalogValue(bogus), bogus)
    }

    func testNFRI18N001AppStringAccessorReturnsEnglishForStaticAndInterpolatedKeys() {
        XCTAssertEqual(AppString.localized("app.name", "Editor Ajar"), "Editor Ajar")
        // Interpolated strings resolve via their compiler-generated default value.
        XCTAssertEqual(AppString.localized("frame.value", "Frame \(42)"), "Frame 42")
        XCTAssertEqual(
            AppString.localized("import.progress.file", "Importing \("clip.mov")"),
            "Importing clip.mov"
        )
        XCTAssertEqual(
            AppString.localized("import.progress.value", "\(2) of \(5) files"),
            "2 of 5 files"
        )
        XCTAssertEqual(
            AppString.localized(
                "import.status.complete",
                "Import complete: \(3) imported, \(1) skipped, \(2) failed"
            ),
            "Import complete: 3 imported, 1 skipped, 2 failed"
        )
    }

    // MARK: - (c) Core → app mapping (CORE PURITY BOUNDARY)

    func testNFRI18N001ReadOnlyReasonMapsToLocalizedCopyWithoutTouchingCore() {
        let reason = AjarProjectReadOnlyReason.newerSchemaMinor(found: 5, supported: 2)
        let message = AppString.readOnlyProjectMessage(for: reason)
        XCTAssertFalse(message.isEmpty)
        // App-side mapping surfaces the schema numbers and the read-only framing.
        XCTAssertTrue(message.contains("5"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("read-only"))
    }
}
