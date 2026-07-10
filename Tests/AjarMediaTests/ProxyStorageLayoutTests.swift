// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class ProxyStorageLayoutTests: XCTestCase {
    func testFRMED004RelativePathLayout() throws {
        let mediaID = try XCTUnwrap(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let hash = ContentHash.sha256(data: Data("bytes".utf8))
        let path = ProxyStorageLayout.relativePath(
            mediaID: mediaID,
            contentHash: hash,
            resolution: PixelDimensions(width: 960, height: 540)
        )
        XCTAssertTrue(path.hasPrefix("caches/proxies/"))
        XCTAssertTrue(path.contains(mediaID.uuidString.lowercased()))
        XCTAssertTrue(path.hasSuffix("-960x540.mov"))
        XCTAssertTrue(path.contains(ProxyStorageLayout.contentHashPrefix(hash)))
    }

    func testFRMED004AbsoluteURLJoinsPackageRoot() {
        let root = URL(fileURLWithPath: "/tmp/Project.ajar")
        let relative = "caches/proxies/m-hash-640x360.mov"
        let url = ProxyStorageLayout.absoluteURL(packageRootURL: root, relativePath: relative)
        XCTAssertEqual(url.path, "/tmp/Project.ajar/caches/proxies/m-hash-640x360.mov")
    }

    func testFRMED004EnsureProxiesDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-proxy-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProxyStorageLayout.ensureProxiesDirectory(packageRootURL: root)
        var isDir: ObjCBool = false
        let path = root.appendingPathComponent("caches/proxies").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
