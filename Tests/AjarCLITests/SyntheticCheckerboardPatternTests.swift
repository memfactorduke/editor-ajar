// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import AjarCLI

/// Metal-free coverage for the optional checkerboard synthetic-media pattern (NFR-QUAL-001).
final class SyntheticCheckerboardPatternTests: XCTestCase {
    func testNFRQUAL001CheckerboardResolvedPixelsMatchCellPattern() throws {
        let pattern = SyntheticCheckerboardPattern(
            cellSize: 2,
            colorABGRA: [0, 0, 255, 255],
            colorBBGRA: [255, 0, 0, 255]
        )
        let spec = SyntheticMovieSpec(
            width: 4,
            height: 4,
            frameCount: 1,
            frameRate: 24,
            bgra: [0, 0, 0, 255],
            checkerboard: pattern
        )
        let pixels = try spec.resolvedBGRAPixels()
        XCTAssertEqual(pixels.count, 4 * 4 * 4)

        // Cell (0,0) and (1,1) use color A; (1,0) and (0,1) use color B.
        XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 255, 255])
        XCTAssertEqual(Array(pixels[8..<12]), [255, 0, 0, 255])
        // y=2,x=0 is still cellY=1 → B for x cell 0: (0+1) odd → B
        let y2x0 = 2 * 4 * 4
        XCTAssertEqual(Array(pixels[y2x0..<(y2x0 + 4)]), [255, 0, 0, 255])
    }

    func testNFRQUAL001PixelsBGRATakesPrecedenceOverCheckerboard() throws {
        let tight: [UInt8] = [
            1, 2, 3, 4,
            5, 6, 7, 8,
            9, 10, 11, 12,
            13, 14, 15, 16
        ]
        let spec = SyntheticMovieSpec(
            width: 2,
            height: 2,
            frameCount: 1,
            frameRate: 24,
            bgra: [0, 0, 0, 255],
            pixelsBGRA: tight,
            checkerboard: SyntheticCheckerboardPattern(
                cellSize: 1,
                colorABGRA: [0, 0, 255, 255],
                colorBBGRA: [255, 0, 0, 255]
            )
        )
        XCTAssertEqual(try spec.resolvedBGRAPixels(), tight)
    }

    func testNFRQUAL001LegacyManifestWithoutCheckerboardStillDecodes() throws {
        let json = """
            {
              "width": 2,
              "height": 2,
              "frameCount": 1,
              "frameRate": 24,
              "bgra": [0, 0, 255, 255]
            }
            """
        let data = Data(json.utf8)
        let spec = try JSONDecoder().decode(SyntheticMovieSpec.self, from: data)
        XCTAssertNil(spec.checkerboard)
        XCTAssertNil(spec.pixelsBGRA)
        XCTAssertEqual(try spec.resolvedBGRAPixels().count, 16)
    }
}
