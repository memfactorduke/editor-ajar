// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

/// 1080p fully-styled title node fixture for `ajar bench` (FR-TXT-001/002, PERFORMANCE §3).
///
/// One cold frame: media underlayer + title with stroke, drop shadow, linear gradient fill,
/// and background box. The executor CPU-rasterizes the title (CoreText), uploads, and
/// composites — matching the ADR-0017 production path. Self-contained (no `.ajar` package).
enum BenchmarkTitleNodeFixture {
    static func measure() async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }
        let fixture = try TitleNodeFixture(device: device)
        let executor = try MetalRenderExecutor(device: device)
        let renderTime = try RationalTime.atFrame(0, frameRate: fixture.project.settings.frameRate)

        return try await BenchmarkCommand.medianMilliseconds {
            executor.removeAllCachedFrames()
            let graph = try buildRenderGraph(
                for: fixture.sequence,
                at: renderTime,
                in: fixture.project
            )
            let frame = try executor.render(
                graph: graph,
                output: RenderOutputDescriptor(pixelDimensions: fixture.dimensions),
                sourceProvider: fixture.sourceProvider
            )
            try await frame.waitForCompletion()
        }
    }
}

// MARK: - Project assembly

private struct TitleNodeFixture {
    let dimensions: PixelDimensions
    let project: Project
    let sequence: Sequence
    let sourceProvider: any RenderSourceTextureProvider

    init(device: MTLDevice) throws {
        dimensions = PixelDimensions(width: 1_920, height: 1_080)
        let frameRate = try FrameRate(frames: 30)
        project = try Self.makeProject(dimensions: dimensions, frameRate: frameRate)
        guard let firstSequence = project.sequences.first else {
            throw AjarCLIError.missingSequence
        }
        sequence = firstSequence
        let mediaClipID = try titleNodeUUID("00000000-0000-0000-0000-000000006015")
        let texture = try Self.makeSolidTexture(
            device: device,
            dimensions: dimensions,
            pixel: [48, 48, 48, 255]
        )
        // Title generators are rasterized by the executor; only the media underlayer needs a
        // source texture.
        sourceProvider = TitleNodeTextureProvider(texturesByClipID: [mediaClipID: texture])
    }

    private static func makeProject(
        dimensions: PixelDimensions,
        frameRate: FrameRate
    ) throws -> Project {
        let mediaID = try titleNodeUUID("00000000-0000-0000-0000-000000006010")
        let duration = try frameRate.duration(ofFrames: 30)
        let sequence = try makeSequence(mediaID: mediaID, duration: duration, frameRate: frameRate)
        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: dimensions,
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [try makeMedia(id: mediaID, dimensions: dimensions, frameRate: frameRate)],
            sequences: [sequence]
        )
    }

    private static func makeSequence(
        mediaID: UUID,
        duration: RationalTime,
        frameRate: FrameRate
    ) throws -> Sequence {
        let mediaClip = Clip(
            id: try titleNodeUUID("00000000-0000-0000-0000-000000006015"),
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .video,
            name: "Title Node Underlay"
        )
        let titleClip = Clip(
            id: try titleNodeUUID("00000000-0000-0000-0000-000000006016"),
            source: .title(try fullyStyledTitle()),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .video,
            name: "Title Node Styled"
        )
        return Sequence(
            id: try titleNodeUUID("00000000-0000-0000-0000-000000006012"),
            name: "Title Node Styled 1080p",
            videoTracks: [
                Track(
                    id: try titleNodeUUID("00000000-0000-0000-0000-000000006020"),
                    kind: .video,
                    items: [.clip(mediaClip)]
                ),
                Track(
                    id: try titleNodeUUID("00000000-0000-0000-0000-000000006021"),
                    kind: .video,
                    items: [.clip(titleClip)]
                )
            ],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
    }

    private static func makeMedia(
        id: UUID,
        dimensions: PixelDimensions,
        frameRate: FrameRate
    ) throws -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: URL(fileURLWithPath: "/benchmark/\(id.uuidString).mov"),
            contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
            metadata: MediaMetadata(
                codecID: "synthetic-bgra",
                pixelDimensions: dimensions,
                frameRate: frameRate,
                duration: try frameRate.duration(ofFrames: 30),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    /// Stroke + shadow + gradient fill + background box (all four FR-TXT-002 styling features).
    private static func fullyStyledTitle() throws -> TitleSource {
        let style = TitleTextStyle(
            fontFamily: TitleSource.deterministicFontFamily,
            fontSize: RationalValue(72),
            fontWeight: .bold,
            color: ClipRGBColor(red: .one, green: .one, blue: .one),
            alignment: .center,
            stroke: TitleStrokeStyle(
                width: RationalValue(2),
                color: ClipRGBColor(red: .zero, green: .zero, blue: .zero),
                join: .round
            ),
            dropShadow: TitleDropShadowStyle(
                offsetX: RationalValue(4),
                offsetY: RationalValue(3),
                blurRadius: RationalValue(4),
                color: ClipRGBColor(red: .zero, green: .zero, blue: .zero),
                opacity: try RationalValue(numerator: 3, denominator: 4)
            ),
            gradientFill: TitleLinearGradientFill(
                startColor: ClipRGBColor(red: .one, green: .one, blue: .zero),
                endColor: ClipRGBColor(red: .one, green: .zero, blue: .zero),
                angleDegrees: RationalValue(20)
            )
        )
        return TitleSource(
            boxes: [
                TitleTextBox(
                    id: try titleNodeUUID("00000000-0000-0000-0000-000000006050"),
                    text: "Editor Ajar",
                    origin: CanvasPoint(x: RationalValue(480), y: RationalValue(440)),
                    width: RationalValue(960),
                    height: RationalValue(200),
                    style: style,
                    backgroundBox: TitleBackgroundBoxStyle(
                        padding: RationalValue(12),
                        cornerRadius: RationalValue(8),
                        fillColor: ClipRGBColor(
                            red: .zero,
                            green: try RationalValue(numerator: 1, denominator: 5),
                            blue: try RationalValue(numerator: 3, denominator: 5)
                        ),
                        opacity: try RationalValue(numerator: 4, denominator: 5)
                    )
                )
            ]
        )
    }

    private static func makeSolidTexture(
        device: MTLDevice,
        dimensions: PixelDimensions,
        pixel: [UInt8]
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimensions.width,
            height: dimensions.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw AjarCLIError.benchmarkFailed("could not allocate 1080p title-node texture")
        }
        let count = dimensions.width * dimensions.height
        var bytes = [UInt8](repeating: 0, count: count * 4)
        for index in 0..<count {
            let base = index * 4
            bytes[base] = pixel[0]
            bytes[base + 1] = pixel[1]
            bytes[base + 2] = pixel[2]
            bytes[base + 3] = pixel[3]
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, dimensions.width, dimensions.height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: dimensions.width * 4
        )
        return texture
    }
}

private func titleNodeUUID(_ value: String) throws -> UUID {
    guard let uuid = UUID(uuidString: value) else {
        throw AjarCLIError.benchmarkFailed("invalid title-node fixture UUID \(value)")
    }
    return uuid
}

private final class TitleNodeTextureProvider: RenderSourceTextureProvider {
    private let texturesByClipID: [UUID: MTLTexture]

    init(texturesByClipID: [UUID: MTLTexture]) {
        self.texturesByClipID = texturesByClipID
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = texturesByClipID[source.clipID] else {
            throw AjarCLIError.benchmarkFailed(
                "missing title-node bench texture for clip \(source.clipID)"
            )
        }
        return texture
    }
}

extension BenchmarkCommand {
    /// M8 creative metrics: full typical stack and the dedicated styled title node.
    static func measureM8CreativeMetric(_ metric: BenchmarkMetric) async throws -> Double {
        switch metric {
        case .typicalStack1080pPlaybackM8Exit:
            try await BenchmarkTypicalStackM8ExitFixture.measure()
        case .titleNodeStyled1080p:
            try await BenchmarkTitleNodeFixture.measure()
        default:
            throw AjarCLIError.benchmarkFailed(
                "metric \(metric.rawValue) is not an M8 creative stack/title metric"
            )
        }
    }
}
