// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

/// Initial timeline placement duration vs unbounded still source extent (FR-MED-002 / #246).
final class StillPlacementDurationTests: XCTestCase {
    func testFRMED002TimelinePlacementDurationIsDefaultNotSourceExtent() throws {
        let still = MediaRef(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/photo.png"),
            contentHash: ContentHash.sha256(data: Data("still-placement".utf8)),
            metadata: MediaMetadata(
                codecID: "png",
                pixelDimensions: PixelDimensions(width: 64, height: 64),
                frameRate: nil,
                duration: try StillMediaDefaults.sourceExtentDuration(),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        XCTAssertTrue(StillMediaDefaults.isStillMedia(still))
        XCTAssertEqual(
            try StillMediaDefaults.timelinePlacementDuration(for: still),
            try StillMediaDefaults.defaultDuration()
        )
        XCTAssertNotEqual(
            try StillMediaDefaults.timelinePlacementDuration(for: still),
            try StillMediaDefaults.sourceExtentDuration()
        )

        let video = MediaRef(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
            contentHash: ContentHash.sha256(data: Data("video-placement".utf8)),
            metadata: MediaMetadata(
                codecID: "h264",
                pixelDimensions: PixelDimensions(width: 64, height: 64),
                frameRate: try FrameRate(frames: 30),
                duration: try RationalTime(value: 90, timescale: 30),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        XCTAssertFalse(StillMediaDefaults.isStillMedia(video))
        XCTAssertEqual(
            try StillMediaDefaults.timelinePlacementDuration(for: video),
            video.metadata.duration
        )
    }
}
