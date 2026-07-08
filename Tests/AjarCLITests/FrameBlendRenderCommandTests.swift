// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import XCTest

@testable import AjarCLI

/// FR-SPD-004 end-to-end decode coverage for the source-end degeneracy: the final fractional
/// source position of a frame-blend clip has no later frame to blend with, and must render the
/// nearest-earlier (last) frame deterministically instead of failing the decode.
final class FrameBlendRenderCommandTests: XCTestCase {
    func testFRSPD004FinalFractionalPositionRendersLastFrameWithoutThrowing() async throws {
        try requireFrameBlendMetal()
        let directory = try makeFrameBlendTemporaryDirectory()
        let mediaURL = directory.appendingPathComponent("source.mov")
        let projectURL = directory.appendingPathComponent("project.ajar")
        let outputURL = directory.appendingPathComponent("final-fractional.png")
        // Green channel encodes the frame index (0...199), so the last frame carries a strong
        // green signal that survives the ProRes/color-conversion roundtrip.
        let movieSpec = SyntheticMovieSpec(
            width: 16,
            height: 16,
            frameCount: 200,
            frameRate: 24,
            bgra: [0, 0, 255, 255]
        )
        try SyntheticMovieWriter.writeMovie(to: mediaURL, spec: movieSpec)
        try ProjectPackageIO.writeProject(
            makeFrameBlendProject(mediaURL: mediaURL, movieSpec: movieSpec),
            to: projectURL
        )

        // Timeline frame 399 of the 1/2x clip maps to source frame 199.5: the later adjacent
        // frame would start on the exclusive source end, so the blend degenerates and the
        // provider must decode the nearest-earlier frame 199 at its exact frame start — never
        // the fractional time, which is not a deterministic decoder input past the final
        // sample start and can fail the render.
        let result = try await RenderFrameCommand.render(
            options: RenderFrameOptions(
                frameTime: try FrameTimeArgument.parse("399"),
                projectURL: projectURL,
                outputURL: outputURL
            )
        )

        XCTAssertEqual(result.pixelDimensions, PixelDimensions(width: 16, height: 16))
        let image = try PNGCodec.read(from: outputURL)
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 16)
        // BGRA byte order: green of the last frame (index 199) within decode noise; decoding
        // an earlier frame (or a transparent failure) would sit far below this band.
        let green = Int(image.bgra8[1])
        XCTAssertLessThanOrEqual(
            abs(green - 199),
            12,
            "expected last-frame green ~199, got \(green)"
        )
        XCTAssertEqual(image.bgra8[3], 255)
    }
}

private func makeFrameBlendProject(
    mediaURL: URL,
    movieSpec: SyntheticMovieSpec
) throws -> Project {
    let frameRate = try FrameRate(frames: Int64(movieSpec.frameRate))
    let duration = try frameRate.duration(ofFrames: Int64(movieSpec.frameCount))
    let mediaID = try frameBlendUUID("00000000-0000-0000-0000-000000002018")
    let media = MediaRef(
        id: mediaID,
        sourceURL: mediaURL,
        contentHash: ContentHash.sha256(data: Data("cli-frame-blend-test".utf8)),
        metadata: MediaMetadata(
            codecID: "prores4444",
            pixelDimensions: PixelDimensions(width: movieSpec.width, height: movieSpec.height),
            frameRate: frameRate,
            duration: duration,
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
    let clip = Clip(
        id: try frameBlendUUID("00000000-0000-0000-0000-000000002118"),
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(
            start: .zero,
            duration: try Clip.timelineDuration(
                forSourceDuration: duration,
                speed: try RationalValue(numerator: 1, denominator: 2)
            )
        ),
        kind: .video,
        name: "CLI FR-SPD-004 blend clip",
        speed: try RationalValue(numerator: 1, denominator: 2),
        frameSampling: .frameBlend
    )
    let sequence = Sequence(
        id: try frameBlendUUID("00000000-0000-0000-0000-000000002218"),
        name: "CLI FR-SPD-004 render",
        videoTracks: [
            Track(
                id: try frameBlendUUID("00000000-0000-0000-0000-000000002318"),
                kind: .video,
                items: [.clip(clip)]
            )
        ],
        audioTracks: [],
        markers: [],
        timebase: frameRate
    )

    return Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: frameRate,
            resolution: PixelDimensions(width: movieSpec.width, height: movieSpec.height),
            colorSpace: .rec709,
            audioSampleRate: 48_000
        ),
        mediaPool: [media],
        sequences: [sequence]
    )
}

private extension FrameBlendRenderCommandTests {
    func makeFrameBlendTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-frame-blend-cli-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private func requireFrameBlendMetal() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
}

private func frameBlendUUID(_ value: String) throws -> UUID {
    try XCTUnwrap(UUID(uuidString: value))
}
