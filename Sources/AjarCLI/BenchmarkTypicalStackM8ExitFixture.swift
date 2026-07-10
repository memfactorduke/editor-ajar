// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

/// Self-contained 1080p30 "typical stack" fixture for the M8 exit playback metric.
///
/// Timeline (rendered at mid cross-dissolve so every layer is live):
/// - V1: two media clips with a crossDissolve cut; each carries a grade (master S-curve
///   curves + 8³ invert LUT at half strength) plus gaussian blur (radius 2) and vignette.
/// - V2: styled title overlay (stroke + drop shadow).
///
/// Synthetic Metal textures only — no `.ajar` package / AVFoundation decode.
enum BenchmarkTypicalStackM8ExitFixture {
    static func measure() async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }
        let fixture = try TypicalStackM8ExitFixture(device: device)
        let executor = try MetalRenderExecutor(device: device)
        // Mid cross-dissolve: cut at frame 30, duration 10 → frame 35 is progress 0.5.
        let renderTime = try RationalTime.atFrame(35, frameRate: fixture.project.settings.frameRate)

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

// MARK: - Project / texture assembly

private struct TypicalStackM8ExitFixture {
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
        sourceProvider = try Self.makeSourceProvider(device: device, dimensions: dimensions)
    }

    private static func makeSourceProvider(
        device: MTLDevice,
        dimensions: PixelDimensions
    ) throws -> any RenderSourceTextureProvider {
        let outgoingTexture = try makeCheckerTexture(
            device: device,
            dimensions: dimensions,
            onPixel: [64, 128, 200, 255],
            offPixel: [200, 96, 48, 255]
        )
        let incomingTexture = try makeCheckerTexture(
            device: device,
            dimensions: dimensions,
            onPixel: [180, 90, 40, 255],
            offPixel: [40, 140, 180, 255]
        )
        // Title generators are rasterized by the executor; only media clips need textures.
        return TypicalStackTextureProvider(
            texturesByClipID: [
                try typicalStackUUID("00000000-0000-0000-0000-000000005015"): outgoingTexture,
                try typicalStackUUID("00000000-0000-0000-0000-000000005016"): incomingTexture
            ]
        )
    }

    private static func makeProject(
        dimensions: PixelDimensions,
        frameRate: FrameRate
    ) throws -> Project {
        let mediaID = try typicalStackUUID("00000000-0000-0000-0000-000000005010")
        let halfSecond = try frameRate.duration(ofFrames: 30)
        let fullSecond = try frameRate.duration(ofFrames: 60)
        let transitionDuration = try frameRate.duration(ofFrames: 10)
        let clips = try makeClips(
            mediaID: mediaID,
            halfSecond: halfSecond,
            fullSecond: fullSecond,
            transitionDuration: transitionDuration
        )
        let sequence = Sequence(
            id: try typicalStackUUID("00000000-0000-0000-0000-000000005012"),
            name: "M8 Exit Typical Stack 1080p30",
            videoTracks: [
                Track(
                    id: try typicalStackUUID("00000000-0000-0000-0000-000000005020"),
                    kind: .video,
                    items: [.clip(clips.outgoing), .clip(clips.incoming)]
                ),
                Track(
                    id: try typicalStackUUID("00000000-0000-0000-0000-000000005021"),
                    kind: .video,
                    items: [.clip(clips.title)]
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

    private struct Clips {
        let outgoing: Clip
        let incoming: Clip
        let title: Clip
    }

    private static func makeClips(
        mediaID: UUID,
        halfSecond: RationalTime,
        fullSecond: RationalTime,
        transitionDuration: RationalTime
    ) throws -> Clips {
        let halfStrength = try RationalValue(numerator: 1, denominator: 2)
        let lutTable = try makeTypicalStackInvertCube(size: 8)
        let outgoingID = try typicalStackUUID("00000000-0000-0000-0000-000000005015")
        let incomingID = try typicalStackUUID("00000000-0000-0000-0000-000000005016")
        let trailing = ClipVideoTransition(
            partnerClipID: incomingID,
            duration: transitionDuration,
            kind: .crossDissolve
        )
        let leading = ClipVideoTransition(
            partnerClipID: outgoingID,
            duration: transitionDuration,
            kind: .crossDissolve
        )
        return Clips(
            outgoing: Clip(
                id: outgoingID,
                source: .media(id: mediaID),
                sourceRange: try TimeRange(start: .zero, duration: halfSecond),
                timelineRange: try TimeRange(start: .zero, duration: halfSecond),
                kind: .video,
                name: "Typical Stack Outgoing",
                effectStack: try typicalStack(
                    nodeSeed: 5_030,
                    lutTable: lutTable,
                    lutStrength: halfStrength
                ),
                trailingTransition: trailing
            ),
            incoming: Clip(
                id: incomingID,
                source: .media(id: mediaID),
                sourceRange: try TimeRange(start: .zero, duration: halfSecond),
                timelineRange: try TimeRange(start: halfSecond, duration: halfSecond),
                kind: .video,
                name: "Typical Stack Incoming",
                effectStack: try typicalStack(
                    nodeSeed: 5_040,
                    lutTable: lutTable,
                    lutStrength: halfStrength
                ),
                leadingTransition: leading
            ),
            title: Clip(
                id: try typicalStackUUID("00000000-0000-0000-0000-000000005017"),
                source: .title(try styledTitle()),
                sourceRange: try TimeRange(start: .zero, duration: fullSecond),
                timelineRange: try TimeRange(start: .zero, duration: fullSecond),
                kind: .video,
                name: "Typical Stack Title"
            )
        )
    }

    /// Grade (curves S-curve + 8³ invert LUT @ ½) then blur + vignette.
    private static func typicalStack(
        nodeSeed: Int,
        lutTable: CubeLUTTable,
        lutStrength: RationalValue
    ) throws -> ClipEffectStack {
        ClipEffectStack(
            nodes: [
                ClipEffectNode(
                    id: try seededUUID(nodeSeed),
                    definition: .curves(
                        ClipCurvesEffectParameters(rgb: .rgbSCurve, strength: .one)
                    )
                ),
                ClipEffectNode(
                    id: try seededUUID(nodeSeed + 1),
                    definition: .lut(
                        ClipLUTEffectParameters(table: lutTable, strength: lutStrength)
                    )
                ),
                ClipEffectNode(
                    id: try seededUUID(nodeSeed + 2),
                    definition: .gaussianBlur(
                        ClipGaussianBlurParameters(radius: RationalValue(2))
                    )
                ),
                ClipEffectNode(
                    id: try seededUUID(nodeSeed + 3),
                    definition: .vignette(
                        ClipVignetteParameters(
                            amount: try RationalValue(numerator: 3, denominator: 4),
                            radius: try RationalValue(numerator: 1, denominator: 2),
                            softness: try RationalValue(numerator: 1, denominator: 4)
                        )
                    )
                )
            ]
        )
    }

    /// Title with stroke + drop shadow (FR-TXT-001 / FR-TXT-002).
    private static func styledTitle() throws -> TitleSource {
        let style = TitleTextStyle(
            fontFamily: TitleSource.deterministicFontFamily,
            fontSize: RationalValue(64),
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
            )
        )
        return TitleSource(
            boxes: [
                TitleTextBox(
                    id: try typicalStackUUID("00000000-0000-0000-0000-000000005050"),
                    text: "Editor Ajar",
                    origin: CanvasPoint(x: RationalValue(560), y: RationalValue(460)),
                    width: RationalValue(800),
                    height: RationalValue(160),
                    style: style
                )
            ]
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

    private static func makeCheckerTexture(
        device: MTLDevice,
        dimensions: PixelDimensions,
        onPixel: [UInt8],
        offPixel: [UInt8]
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
            throw AjarCLIError.benchmarkFailed(
                "could not allocate 1080p typical-stack bench texture"
            )
        }
        fillChecker(texture: texture, dimensions: dimensions, on: onPixel, off: offPixel)
        return texture
    }

    private static func fillChecker(
        texture: MTLTexture,
        dimensions: PixelDimensions,
        on: [UInt8],
        off: [UInt8]
    ) {
        let bytesPerRow = dimensions.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * dimensions.height)
        for y in 0..<dimensions.height {
            for x in 0..<dimensions.width {
                let pixel = ((x / 32) + (y / 32)).isMultiple(of: 2) ? on : off
                let offset = (y * bytesPerRow) + (x * 4)
                bytes[offset] = pixel[0]
                bytes[offset + 1] = pixel[1]
                bytes[offset + 2] = pixel[2]
                bytes[offset + 3] = pixel[3]
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
    }

    private static func seededUUID(_ seed: Int) throws -> UUID {
        try typicalStackUUID(String(format: "00000000-0000-0000-0000-%012d", seed))
    }
}

// MARK: - Shared helpers

private func typicalStackUUID(_ value: String) throws -> UUID {
    guard let uuid = UUID(uuidString: value) else {
        throw AjarCLIError.benchmarkFailed("invalid fixture UUID \(value)")
    }
    return uuid
}

/// 8³ invert cube for the M8-exit grade stack (matches golden `lut-invert-strength-half` size).
private func makeTypicalStackInvertCube(size: Int) throws -> CubeLUTTable {
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
        title: "M8 Exit Invert \(size)",
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

private final class TypicalStackTextureProvider: RenderSourceTextureProvider {
    private let texturesByClipID: [UUID: MTLTexture]

    init(texturesByClipID: [UUID: MTLTexture]) {
        self.texturesByClipID = texturesByClipID
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = texturesByClipID[source.clipID] else {
            throw AjarCLIError.benchmarkFailed(
                "missing typical-stack bench texture for clip \(source.clipID)"
            )
        }
        return texture
    }
}
