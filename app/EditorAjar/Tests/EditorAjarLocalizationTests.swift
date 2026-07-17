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
            "document.open.title": "Open…",
            "document.warning.saveAsCleanup.title": "Project Saved with Cleanup Warning",
            "document.warning.saveAsCleanupSkipped":
                "The project was saved successfully and is now using %@. Automatic cleanup was skipped safely because the older folder changed. No folder was identified as safe to delete.",
            "document.warning.saveAsRetainedCleanup":
                "The project was saved and is now using %@, but an older retained package could not be removed safely. It was left as %@ for manual cleanup or recovery.",
            "document.newSettings.title": "New Project",
            "welcome.title": "Welcome to Editor Ajar",
            "workspace.header.export": "Export…",
            "banner.readOnly.title": "Read-only project",
            "sequenceTabs.new": "New Sequence",
            "compound.defaultName": "Compound Clip %lld",
            "menu.clip.makeCompound": "Make Compound Clip",
            "menu.clip.openCompound": "Open Compound Clip",
            "menu.clip.decomposeCompound": "Decompose Compound Clip",
            "compound.make.refusal.locked":
                "Unlock every selected or linked track before making a compound clip.",
            "compound.make.refusal.ducking":
                "The selection crosses an audio ducking boundary. Include every affected ducking track or change the ducking setup first.",
            "compound.decompose.refusal.attributes":
                "Remove compound-level transforms, effects, keyframes, time remapping, reverse or freeze settings, audio adjustments, and nested track keyframes before decomposing.",
            "timeline.placement.refusal.linkedPartial":
                "This edit would move or replace only part of a linked audio/video group. Target both linked tracks, move to a cut, or detach the clips first. The project was not changed.",
            "status.audioPlaybackReady": "Audio playback ready",
            "status.audioPlaybackUnavailable": "Audio playback unavailable: %@",
            "sequence.close.refusal.referenced":
                "This sequence is used by a compound clip. Decompose every instance before removing it.",
            "transport.play": "Play",
            "inspector.title": "Inspector",
            "timeline.tool.fit": "Fit Timeline",
            "export.dialog.title": "Export",
            "export.dialog.addToQueue": "Add to Queue",
            "export.dialog.addToQueue.ax": "Add export to queue",
            "export.dialog.addingToQueue": "Adding…",
            "export.dialog.destination.panelTitle": "Choose Export Destination",
            "export.mode.animatedGIF": "Animated GIF",
            "export.gif.size.ax": "Animated GIF size",
            "export.gif.size.half": "Half",
            "export.gif.frameRate.ax": "Animated GIF frame rate",
            "export.gif.frameRate.fps15": "15 fps",
            "export.gif.loop.ax": "Animated GIF playback",
            "export.gif.loop.forever": "Forever",
            "export.gif.loop.playOnce": "Play once",
            "exportQueue.title": "Export Queue",
            "import.summary.title": "Media Import Summary",
            "import.summary.empty": "No media files were found in the selection.",
            "import.failure.projectUpdate.reason": "The open project rejected the import batch.",
            "import.failure.unsupportedFormat":
                "This format could not be converted into working media.",
            "consolidate.menu.title": "Consolidate Media…",
            "consolidate.progress.cancel.ax": "Cancel media consolidation",
            "consolidate.failure.packageBusy":
                "This project is already consolidating media in another window or process. Wait for it to finish and try again.",
            "consolidate.failure.staleCleanup":
                "Temporary media cleanup for %@ needs attention. Consolidation stopped without deleting the uncertain item.",
            "consolidate.failure.publicationSync":
                "The copy of %@ is present, but safe storage could not be confirmed, so its reference was not changed.",
            "consolidate.failure.sourceProtection":
                "Media safety could not verify %@. Consolidation stopped before temporary files were cleaned up.",
            "consolidate.summary.title": "Media Consolidation",
            "library.panel.ax":
                "Media and effects panel. Drop media files or folders here to import.",
            "marker.color.red": "Red",
            "blend.normal": "Normal",
            "transform.param.position": "Position",
            "state.selected": "Selected"
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
        XCTAssertEqual(
            AppString.localized(
                "consolidate.confirm.message.many",
                "Copy \(2) media files to \("/Project.ajar/media"). Originals are never deleted."
            ),
            "Copy 2 media files to /Project.ajar/media. Originals are never deleted."
        )
        XCTAssertEqual(
            AppString.localized(
                "consolidate.confirm.message.one",
                "Copy 1 media file to \("/Project.ajar/media"). Originals are never deleted."
            ),
            "Copy 1 media file to /Project.ajar/media. Originals are never deleted."
        )
        XCTAssertEqual(
            AppString.localized(
                "consolidate.failure.staleCleanup",
                "Temporary media cleanup for \("source.mov") needs attention. Consolidation stopped without deleting the uncertain item."
            ),
            "Temporary media cleanup for source.mov needs attention. Consolidation stopped without deleting the uncertain item."
        )
        XCTAssertEqual(
            AppString.localized(
                "consolidate.failure.sourceProtection",
                "Media safety could not verify \("source.mov"). Consolidation stopped before temporary files were cleaned up."
            ),
            "Media safety could not verify source.mov. Consolidation stopped before temporary files were cleaned up."
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
