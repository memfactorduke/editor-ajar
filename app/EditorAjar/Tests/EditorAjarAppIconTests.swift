// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import XCTest

@testable import EditorAjar

/// App identity (#265): the shipping bundle must declare AppIcon and carry *compiled*
/// icon resources so Finder/Dock/Spotlight show the product mark.
///
/// These checks are offline and non-UI: Info.plist, resource files, NSImage catalog load,
/// and `/usr/bin/assetutil --info` on the bundled Assets.car.
final class EditorAjarAppIconTests: XCTestCase {
    private var appBundle: Bundle { Bundle(for: EditorAjarAppModel.self) }

    private static var expectedPixelSizeByRendition: [String: (Int, Int, Int)] {
        let at = String(UnicodeScalar(64)!)
        var map: [String: (Int, Int, Int)] = [:]
        let slots: [(Int, Int, Int)] = [
            (16, 1, 16), (16, 2, 32),
            (32, 1, 32), (32, 2, 64),
            (128, 1, 128), (128, 2, 256),
            (256, 1, 256), (256, 2, 512),
            (512, 1, 512), (512, 2, 1024),
        ]
        for (point, scale, px) in slots {
            let name: String
            if scale == 1 {
                name = "icon_\(point)x\(point).png"
            } else {
                name = "icon_\(point)x\(point)\(at)2x.png"
            }
            map[name] = (px, px, scale)
        }
        return map
    }

    func testAppIconNameIsDeclaredOnBundle() {
        let iconName = appBundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String
        XCTAssertEqual(
            iconName,
            "AppIcon",
            "CFBundleIconName must be AppIcon (ASSETCATALOG_COMPILER_APPICON_NAME)."
        )
    }

    func testAppIconIcnsIsPresentAndNonEmpty() {
        let icns = appBundle.url(forResource: "AppIcon", withExtension: "icns")
        XCTAssertNotNil(icns, "AppIcon.icns must ship in the app bundle Resources.")
        guard let icns else { return }
        let values = try? icns.resourceValues(forKeys: [.fileSizeKey])
        let size = values?.fileSize ?? 0
        XCTAssertGreaterThan(size, 0, "AppIcon.icns must be non-empty.")
    }

    func testAppIconImageLoadsFromCompiledAssetCatalog() {
        let image = NSImage(named: NSImage.Name("AppIcon"))
        XCTAssertNotNil(
            image,
            "NSImage(named: AppIcon) must load from the compiled asset catalog."
        )
        guard let image else { return }
        XCTAssertFalse(
            image.representations.isEmpty,
            "AppIcon must expose at least one bitmap representation."
        )
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testAssetsCarContainsAllAppIconRenditionsViaAssetutil() throws {
        let assetsCar = appBundle.url(forResource: "Assets", withExtension: "car")
        XCTAssertNotNil(assetsCar, "Assets.car must ship in the app bundle.")
        guard let assetsCar else { return }

        let values = try assetsCar.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertGreaterThan(values.fileSize ?? 0, 0, "Assets.car must be non-empty.")

        // Temp file avoids Pipe deadlock when assetutil output exceeds the pipe buffer
        // before waitUntilExit returns (output is not drained until after wait).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorAjarAppIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let outURL = tempDir.appendingPathComponent("assetutil-info.json")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/assetutil")
        process.arguments = ["--info", assetsCar.path]
        process.standardOutput = outHandle
        process.standardError = outHandle
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? outHandle.close()
            throw error
        }
        try outHandle.close()

        let data = try Data(contentsOf: outURL)
        XCTAssertEqual(
            process.terminationStatus, 0,
            "assetutil --info failed: \(String(data: data, encoding: .utf8) ?? "<binary>")"
        )

        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let entries = json as? [[String: Any]] else {
            XCTFail("assetutil --info did not return a JSON array")
            return
        }

        let expected = Self.expectedPixelSizeByRendition
        var seen = Set<String>()
        var appIconImages = 0
        for entry in entries {
            guard (entry["Name"] as? String) == "AppIcon" else { continue }
            guard (entry["AssetType"] as? String) == "Icon Image" else { continue }
            appIconImages += 1
            guard let rendition = entry["RenditionName"] as? String else {
                XCTFail("AppIcon Icon Image missing RenditionName")
                return
            }
            guard let want = expected[rendition] else {
                XCTFail("Unexpected AppIcon RenditionName: \(rendition)")
                return
            }
            let w = entry["PixelWidth"] as? Int
            let h = entry["PixelHeight"] as? Int
            let scale = entry["Scale"] as? Int
            XCTAssertEqual(w, want.0, "\(rendition) PixelWidth")
            XCTAssertEqual(h, want.1, "\(rendition) PixelHeight")
            XCTAssertEqual(scale, want.2, "\(rendition) Scale")
            seen.insert(rendition)
        }

        XCTAssertGreaterThan(
            appIconImages, 0,
            "Assets.car must contain compiled AppIcon Icon Image assets."
        )
        let missing = Set(expected.keys).subtracting(seen)
        XCTAssertTrue(
            missing.isEmpty,
            "Assets.car missing AppIcon rendition(s): \(missing.sorted().joined(separator: ", "))"
        )
        XCTAssertEqual(
            seen.count, expected.count,
            "Expected all \(expected.count) macOS AppIcon renditions in Assets.car."
        )
    }
}
