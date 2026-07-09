// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

/// 1080p30 single-layer fixture with a 33³ FR-COL-004 `lut` node, plus a matched no-LUT
/// baseline for differential timing (PERFORMANCE §3 / ADR-0016 §4).
struct BenchmarkLUTFixture {
    let dimensions: PixelDimensions
    let project: Project
    let sequence: Sequence
    let sourceProvider: any RenderSourceTextureProvider
    let baselineProject: Project
    let baselineSequence: Sequence
    let baselineSourceProvider: any RenderSourceTextureProvider

    init(device: MTLDevice) throws {
        dimensions = PixelDimensions(width: 1_920, height: 1_080)
        let frameRate = try FrameRate(frames: 30)
        let table = try makeBenchmarkInvertCube(size: 33)
        project = try Self.makeProject(
            dimensions: dimensions,
            frameRate: frameRate,
            table: table,
            includeLUT: true
        )
        baselineProject = try Self.makeProject(
            dimensions: dimensions,
            frameRate: frameRate,
            table: table,
            includeLUT: false
        )
        guard let firstSequence = project.sequences.first,
              let firstBaseline = baselineProject.sequences.first
        else {
            throw AjarCLIError.missingSequence
        }
        sequence = firstSequence
        baselineSequence = firstBaseline
        let texture = try Self.makeTexture(
            device: device,
            dimensions: dimensions,
            pixel: [96, 112, 144, 255]
        )
        let clipID = try Self.uuid("00000000-0000-0000-0000-000000004014")
        sourceProvider = BenchmarkLUTTextureProvider(texturesByClipID: [clipID: texture])
        baselineSourceProvider = BenchmarkLUTTextureProvider(texturesByClipID: [clipID: texture])
    }

    private static func makeProject(
        dimensions: PixelDimensions,
        frameRate: FrameRate,
        table: CubeLUTTable,
        includeLUT: Bool
    ) throws -> Project {
        let mediaID = try uuid("00000000-0000-0000-0000-000000004010")
        let duration = try frameRate.duration(ofFrames: 60)
        let clip = try makeClip(
            mediaID: mediaID,
            duration: duration,
            table: table,
            includeLUT: includeLUT
        )
        let sequence = Sequence(
            id: try uuid("00000000-0000-0000-0000-000000004012"),
            name: includeLUT ? "Benchmark LUT 1080p30" : "Benchmark LUT baseline",
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
            mediaPool: [try makeMedia(id: mediaID, dimensions: dimensions, frameRate: frameRate)],
            sequences: [sequence]
        )
    }

    private static func makeClip(
        mediaID: UUID,
        duration: RationalTime,
        table: CubeLUTTable,
        includeLUT: Bool
    ) throws -> Clip {
        let stack: ClipEffectStack
        if includeLUT {
            stack = ClipEffectStack(
                nodes: [
                    ClipEffectNode(
                        id: try uuid("00000000-0000-0000-0000-000000004020"),
                        definition: .lut(
                            ClipLUTEffectParameters(table: table, strength: .one)
                        )
                    )
                ]
            )
        } else {
            stack = .empty
        }
        return Clip(
            id: try uuid("00000000-0000-0000-0000-000000004014"),
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .video,
            name: "Benchmark LUT",
            effectStack: stack
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
                duration: try frameRate.duration(ofFrames: 60),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    private static func makeTexture(
        device: MTLDevice,
        dimensions: PixelDimensions,
        pixel: [UInt8]
    ) throws -> MTLTexture {
        guard pixel.count == 4 else {
            throw AjarCLIError.benchmarkFailed("benchmark texture pixel must be BGRA8")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimensions.width,
            height: dimensions.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw AjarCLIError.benchmarkFailed("could not allocate LUT benchmark texture")
        }
        let rowBytes = dimensions.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * dimensions.height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = pixel[0]
            pixels[offset + 1] = pixel[1]
            pixels[offset + 2] = pixel[2]
            pixels[offset + 3] = pixel[3]
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, dimensions.width, dimensions.height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: rowBytes
        )
        return texture
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw AjarCLIError.benchmarkFailed("invalid benchmark UUID \(value)")
        }
        return uuid
    }
}

private func makeBenchmarkInvertCube(size: Int) throws -> CubeLUTTable {
    var entries: [CubeLUTColor] = []
    entries.reserveCapacity(size * size * size)
    let denom = Float(max(size - 1, 1))
    for blue in 0..<size {
        for green in 0..<size {
            for red in 0..<size {
                entries.append(
                    CubeLUTColor(
                        r: 1.0 - (Float(red) / denom),
                        g: 1.0 - (Float(green) / denom),
                        b: 1.0 - (Float(blue) / denom)
                    )
                )
            }
        }
    }
    let table = CubeLUTTable(
        title: "Benchmark Invert \(size)",
        dimensions: .threeD,
        size: size,
        entries: entries
    )
    switch table.validated() {
    case .success(let valid):
        return valid
    case .failure(let error):
        throw AjarCLIError.benchmarkFailed(error.message)
    }
}

enum BenchmarkLUTMeasurement {
    /// Isolates LUT node GPU cost: same 1080p frame with and without the LUT, graphs
    /// prebuilt, textures warm, median(with) − median(baseline).
    static func measureEffectNodeLUTGPU() async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }
        let fixture = try BenchmarkLUTFixture(device: device)
        let executor = try MetalRenderExecutor(device: device)
        let renderTime = try RationalTime.atFrame(0, frameRate: fixture.project.settings.frameRate)
        let lutGraph = try buildRenderGraph(
            for: fixture.sequence,
            at: renderTime,
            in: fixture.project
        )
        let baselineGraph = try buildRenderGraph(
            for: fixture.baselineSequence,
            at: renderTime,
            in: fixture.baselineProject
        )
        let output = RenderOutputDescriptor(pixelDimensions: fixture.dimensions)

        let warmLUT = try executor.render(
            graph: lutGraph,
            output: output,
            sourceProvider: fixture.sourceProvider
        )
        try await warmLUT.waitForCompletion()
        let warmBase = try executor.render(
            graph: baselineGraph,
            output: output,
            sourceProvider: fixture.baselineSourceProvider
        )
        try await warmBase.waitForCompletion()

        let lutMedian = try await BenchmarkCommand.medianMilliseconds {
            executor.removeAllCachedFrames()
            let frame = try executor.render(
                graph: lutGraph,
                output: output,
                sourceProvider: fixture.sourceProvider
            )
            try await frame.waitForCompletion()
        }
        let baselineMedian = try await BenchmarkCommand.medianMilliseconds {
            executor.removeAllCachedFrames()
            let frame = try executor.render(
                graph: baselineGraph,
                output: output,
                sourceProvider: fixture.baselineSourceProvider
            )
            try await frame.waitForCompletion()
        }
        return max(0, lutMedian - baselineMedian)
    }
}

private final class BenchmarkLUTTextureProvider: RenderSourceTextureProvider {
    private let texturesByClipID: [UUID: MTLTexture]

    init(texturesByClipID: [UUID: MTLTexture]) {
        self.texturesByClipID = texturesByClipID
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = texturesByClipID[source.clipID] else {
            throw AjarCLIError.decodedTextureUnavailable(source.mediaID)
        }
        return texture
    }
}
