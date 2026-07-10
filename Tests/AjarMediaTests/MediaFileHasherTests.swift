// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class MediaFileHasherTests: XCTestCase {
    func testFRMED007StreamingHasherMatchesKnownInMemoryHashAcrossChunkBoundaries() throws {
        let root = try temporaryDirectory(named: "streaming-hash")
        defer { try? FileManager.default.removeItem(at: root) }
        let hasher = SHA256MediaFileHasher()

        for byteCount in [0, 1_048_576, 1_048_577] {
            let bytes = Data(repeating: 0xA5, count: byteCount)
            let url = root.appendingPathComponent("source-\(byteCount).mov")
            try bytes.write(to: url)

            XCTAssertEqual(
                try hasher.contentHash(of: url),
                ContentHash.sha256(data: bytes),
                "streamed digest differs at \(byteCount) bytes"
            )
        }
    }
}
