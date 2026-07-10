// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

/// 1080p single-node FR-FX-002 GPU cost fixtures for `ajar bench` (PERFORMANCE §3, ADR-0016 §4).
///
/// Each metric renders one cold frame of a synthetic clip carrying exactly one enabled effect
/// stack node at representative parameters. Budgets are declared on `BenchmarkMetric.budget`
/// next to the kind (metric slug embeds the kind raw value for attribution).
enum BenchmarkEffectNodeFixture {
    static func measure(metric: BenchmarkMetric) async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }
        let definition = try definition(for: metric)
        let fixture = try Fixture(device: device, definition: definition)
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

    private static func definition(for metric: BenchmarkMetric) throws -> ClipEffectDefinition {
        switch metric {
        case .effectNodeGaussianBlur1080p:
            return .gaussianBlur(ClipGaussianBlurParameters(radius: RationalValue(8)))
        case .effectNodeBoxBlur1080p:
            return .boxBlur(ClipBoxBlurParameters(radius: RationalValue(8)))
        case .effectNodeZoomBlur1080p:
            return .zoomBlur(
                ClipZoomBlurParameters(
                    amount: try RationalValue(numerator: 1, denominator: 2),
                    centerX: RationalValue.approximating(0.5),
                    centerY: RationalValue.approximating(0.5)
                )
            )
        case .effectNodeSharpen1080p:
            return .sharpen(
                ClipSharpenParameters(
                    amount: try RationalValue(numerator: 1, denominator: 2),
                    radius: RationalValue(1)
                )
            )
        case .effectNodeGlow1080p:
            return .glow(
                ClipGlowParameters(
                    radius: RationalValue(8),
                    amount: try RationalValue(numerator: 1, denominator: 2)
                )
            )
        case .effectNodeVignette1080p, .effectNodeMirror1080p, .effectNodeMosaic1080p,
            .effectNodeColorAdjust1080p, .effectNodePosterize1080p, .effectNodeInvert1080p:
            return try BenchmarkEffectNodeBatch2Definitions.definition(for: metric)
        default:
            throw AjarCLIError.benchmarkFailed(
                "metric \(metric.rawValue) is not an effect-node GPU cost metric"
            )
        }
    }

    private struct Fixture {
        let dimensions: PixelDimensions
        let project: Project
        let sequence: Sequence
        let sourceProvider: any RenderSourceTextureProvider

        init(device: MTLDevice, definition: ClipEffectDefinition) throws {
            dimensions = PixelDimensions(width: 1_920, height: 1_080)
            let frameRate = try FrameRate(frames: 30)
            project = try Self.makeProject(
                dimensions: dimensions,
                frameRate: frameRate,
                definition: definition
            )
            guard let firstSequence = project.sequences.first else {
                throw AjarCLIError.missingSequence
            }
            sequence = firstSequence
            let texture = try Self.makeTexture(device: device, dimensions: dimensions)
            sourceProvider = BenchmarkEffectNodeTextureProvider(
                texturesByClipID: [
                    try Self.uuid("00000000-0000-0000-0000-000000004015"): texture
                ]
            )
        }

        private static func makeProject(
            dimensions: PixelDimensions,
            frameRate: FrameRate,
            definition: ClipEffectDefinition
        ) throws -> Project {
            let mediaID = try uuid("00000000-0000-0000-0000-000000004010")
            let clipID = try uuid("00000000-0000-0000-0000-000000004015")
            let duration = try frameRate.duration(ofFrames: 30)
            let node = ClipEffectNode(
                id: try uuid("00000000-0000-0000-0000-000000004020"),
                enabled: true,
                definition: definition
            )
            let clip = Clip(
                id: clipID,
                source: .media(id: mediaID),
                sourceRange: try TimeRange(start: .zero, duration: duration),
                timelineRange: try TimeRange(start: .zero, duration: duration),
                kind: .video,
                name: "Benchmark Effect Node",
                effectStack: ClipEffectStack(nodes: [node])
            )
            let sequence = Sequence(
                id: try uuid("00000000-0000-0000-0000-000000004012"),
                name: "Benchmark Effect Node 1080p Sequence",
                videoTracks: [
                    Track(
                        id: try uuid("00000000-0000-0000-0000-000000004016"),
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
                    resolution: dimensions,
                    colorSpace: .rec709,
                    audioSampleRate: 48_000
                ),
                mediaPool: [
                    try makeMedia(id: mediaID, dimensions: dimensions, frameRate: frameRate)
                ],
                sequences: [sequence]
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

        private static func makeTexture(
            device: MTLDevice,
            dimensions: PixelDimensions
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
                throw AjarCLIError.benchmarkFailed("could not allocate 1080p effect bench texture")
            }
            // Checker pattern so blur/sharpen/glow have spatial signal (not a solid field).
            let bytesPerRow = dimensions.width * 4
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * dimensions.height)
            for y in 0..<dimensions.height {
                for x in 0..<dimensions.width {
                    let on = ((x / 16) + (y / 16)).isMultiple(of: 2)
                    let offset = (y * bytesPerRow) + (x * 4)
                    bytes[offset] = on ? 255 : 0
                    bytes[offset + 1] = on ? 128 : 64
                    bytes[offset + 2] = on ? 64 : 200
                    bytes[offset + 3] = 255
                }
            }
            bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else {
                    return
                }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, dimensions.width, dimensions.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bytesPerRow
                )
            }
            return texture
        }

        private static func uuid(_ value: String) throws -> UUID {
            guard let uuid = UUID(uuidString: value) else {
                throw AjarCLIError.benchmarkFailed("invalid fixture UUID \(value)")
            }
            return uuid
        }
    }
}

private final class BenchmarkEffectNodeTextureProvider: RenderSourceTextureProvider {
    private let texturesByClipID: [UUID: MTLTexture]

    init(texturesByClipID: [UUID: MTLTexture]) {
        self.texturesByClipID = texturesByClipID
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = texturesByClipID[source.clipID] else {
            throw AjarCLIError.benchmarkFailed(
                "missing effect-node bench texture for clip \(source.clipID)"
            )
        }
        return texture
    }
}
