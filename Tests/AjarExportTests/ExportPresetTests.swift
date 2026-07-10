// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarExport

final class ExportPresetTests: XCTestCase {
    func testFREXP003BuiltInPresetsResolveThroughExportSettingsValidation() throws {
        let presets = ExportBuiltInPresets.all
        XCTAssertEqual(presets.count, 5)

        let names = Set(presets.map(\.name))
        XCTAssertEqual(
            names,
            [
                "YouTube 1080p",
                "YouTube 4K",
                "Square 1080",
                "Vertical 9:16",
                "ProRes 422 Master"
            ]
        )

        for preset in presets {
            XCTAssertTrue(preset.isBuiltIn)
            let settings = try preset.makeSettings()
            XCTAssertEqual(settings.container, preset.container)
            XCTAssertEqual(settings.video.codec, preset.videoCodec)
            XCTAssertEqual(settings.video.resolution, preset.resolution)
            try settings.validate()
        }
    }

    func testFREXP003BuiltInResolutionsMatchSpecTargets() throws {
        let youTube1080 = try XCTUnwrap(ExportBuiltInPresets.youTube1080p)
        XCTAssertEqual(youTube1080.resolution, PixelDimensions(width: 1_920, height: 1_080))
        XCTAssertEqual(youTube1080.container, .mp4)
        XCTAssertEqual(youTube1080.videoCodec, .h264)

        let youTube4K = try XCTUnwrap(ExportBuiltInPresets.youTube4K)
        XCTAssertEqual(youTube4K.resolution, PixelDimensions(width: 3_840, height: 2_160))

        let square = try XCTUnwrap(ExportBuiltInPresets.square1080)
        XCTAssertEqual(square.resolution, PixelDimensions(width: 1_080, height: 1_080))

        let vertical = try XCTUnwrap(ExportBuiltInPresets.vertical916)
        XCTAssertEqual(vertical.resolution, PixelDimensions(width: 1_080, height: 1_920))

        let proRes = try XCTUnwrap(ExportBuiltInPresets.proRes422Mezzanine)
        XCTAssertEqual(proRes.container, .mov)
        XCTAssertEqual(proRes.videoCodec, .proRes422)
        XCTAssertEqual(proRes.audio?.codec, .linearPCM)
        XCTAssertEqual(proRes.name, "ProRes 422 Master")
    }

    func testFREXP003CustomPresetCodableRoundTripAndValidation() throws {
        let frameRate = try FrameRate(frames: 24)
        let original = ExportPreset(
            name: "Podcast 720p",
            isBuiltIn: false,
            container: .mp4,
            videoCodec: .h264,
            resolution: PixelDimensions(width: 1_280, height: 720),
            frameRate: frameRate,
            averageBitRate: 5_000_000,
            audio: try ExportAudioSettings(
                codec: .aac,
                sampleRate: 48_000,
                channelCount: 2,
                bitRate: 128_000
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: data)
        XCTAssertEqual(decoded, original)
        try decoded.validate()
    }

    func testFREXP003InvalidPresetSurfacesTypedSettingsError() {
        let frameRate = try? FrameRate(frames: 30)
        guard let frameRate else {
            return XCTFail("frame rate")
        }
        let preset = ExportPreset(
            name: "Bad",
            container: .mp4,
            videoCodec: .proRes422,
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: frameRate
        )

        XCTAssertThrowsError(try preset.makeSettings()) { error in
            guard case .invalidSettings(let validation)? = error as? ExportError else {
                return XCTFail("expected invalidSettings, got \(error)")
            }
            XCTAssertEqual(
                validation,
                .videoCodecUnsupportedInContainer(.proRes422, .mp4)
            )
        }
    }
}
