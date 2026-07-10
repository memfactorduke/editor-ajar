// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarCore
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

// swiftlint:enable sorted_imports

final class ExportProResWriterSettingsTests: XCTestCase {
    func testFREXP001ProResWriterVendsDocumentedHighBitDepthPixelBuffers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-prores-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("probe.mov")
        let settings = try ExportSettings(
            container: .mov,
            video: ExportVideoSettings(
                codec: .proRes422,
                resolution: PixelDimensions(width: 64, height: 64),
                frameRate: FrameRate(frames: 30),
                colorSpace: .rec709
            )
        )
        let writer = try AVAssetExportWriter(outputURL: outputURL, settings: settings)
        try writer.start()
        defer { writer.cancel() }

        let pixelBuffer = try writer.makeVideoPixelBuffer()
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            kCVPixelFormatType_64ARGB
        )
    }
}
