// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarRender

final class OfflineSlateRendererTests: XCTestCase {
    func testFRMED007OfflineSlateProducesIdenticalBytesTwice() throws {
        let dimensions = PixelDimensions(width: 64, height: 36)

        let first = try OfflineSlateRenderer.bgra8Pixels(dimensions: dimensions)
        let second = try OfflineSlateRenderer.bgra8Pixels(dimensions: dimensions)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, dimensions.width * dimensions.height * 4)
        XCTAssertEqual(ContentHash.sha256(bytes: first), ContentHash.sha256(bytes: second))
    }

    func testFRMED007OfflineSlateContainsSolidFieldAndDeterministicPattern() throws {
        let pixels = try OfflineSlateRenderer.bgra8Pixels(
            dimensions: PixelDimensions(width: 64, height: 36)
        )
        let colors = Set(stride(from: 0, to: pixels.count, by: 4).map { offset in
            Array(pixels[offset..<(offset + 4)])
        })

        XCTAssertEqual(colors.count, 2)
        XCTAssertTrue(colors.allSatisfy { $0[3] == 255 })
    }

    func testFRMED007OfflineSlateRejectsUnsafePersistedDimensionsBeforeAllocation() {
        let dimensions = PixelDimensions(width: 100_000, height: 100_000)

        XCTAssertThrowsError(
            try OfflineSlateRenderer.bgra8Pixels(dimensions: dimensions)
        ) { error in
            XCTAssertEqual(error as? OfflineSlateRenderError, .invalidDimensions(dimensions))
        }
    }
}
