// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCLI

/// Metal-free guard that every committed golden-frame / golden-audio `manifest.json` decodes
/// with the harness's own loaders (NFR-QUAL-001).
///
/// Manifests authored without a GPU still must be schema-valid. #181 shipped effect fixtures
/// missing required `syntheticMedia.bgra`; the golden harness exits on the first bad manifest,
/// so this walk fails the suite with the broken path named.
final class GoldenFixtureManifestDecodeTests: XCTestCase {
    /// #181 / NFR-QUAL-001: every golden-frame and golden-audio manifest decodes via the
    /// harness decoder (no Metal required).
    func testNFRQUAL001Issue181EveryGoldenFixtureManifestDecodesWithHarnessLoader() throws {
        let roots = try fixtureRoots()
        var failures: [String] = []
        var decodedCount = 0
        var decodedFrameIDs = Set<String>()

        for root in roots {
            let manifests = try discoverManifestURLs(under: root)
            XCTAssertFalse(
                manifests.isEmpty,
                "expected at least one manifest.json under \(root.path)"
            )
            for manifestURL in manifests {
                do {
                    if root.lastPathComponent == "golden-audio" {
                        _ = try GoldenAudioManifest.load(from: manifestURL)
                    } else if root.lastPathComponent == "golden-export" {
                        _ = try GoldenExportManifest.load(from: manifestURL)
                    } else {
                        let manifest = try GoldenFrameManifest.load(from: manifestURL)
                        decodedFrameIDs.insert(manifest.id)
                    }
                    decodedCount += 1
                } catch {
                    failures.append("\(manifestURL.path): \(error)")
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            """
            Golden fixture manifest decode failed (NFR-QUAL-001, #181). \
            Fix the schema before merging — the harness aborts on the first invalid file.
            \(failures.joined(separator: "\n"))
            """
        )
        XCTAssertGreaterThan(decodedCount, 0)
        XCTAssertTrue(
            decodedFrameIDs.contains("media-offline-slate"),
            "FR-MED-007 offline-slate manifest must remain in the decode walk"
        )
        // FR-MED-004 does not add a golden-frame fixture (proxy is a decode tier, not a
        // raster golden). Keep the offline-slate walk as the media-tier identity sentinel.
        _ = "FR-MED-004"
    }

    private func fixtureRoots() throws -> [URL] {
        // Tests/AjarCLITests → Tests → Fixtures/{golden,golden-audio}
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixturesRoot = testsDirectory.appendingPathComponent("Fixtures")
        let roots = [
            fixturesRoot.appendingPathComponent("golden"),
            fixturesRoot.appendingPathComponent("golden-audio"),
            fixturesRoot.appendingPathComponent("golden-export")
        ]
        for root in roots {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            )
            XCTAssertTrue(
                exists && isDirectory.boolValue,
                "fixture root missing: \(root.path)"
            )
        }
        return roots
    }

    private func discoverManifestURLs(under root: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )
        else {
            throw NSError(
                domain: "GoldenFixtureManifestDecodeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not enumerate \(root.path)"]
            )
        }

        var manifests: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "manifest.json" else {
                continue
            }
            manifests.append(fileURL)
        }
        return manifests.sorted { left, right in left.path < right.path }
    }
}
