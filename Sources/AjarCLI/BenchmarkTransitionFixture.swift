// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

/// 1080p FR-FX-001 video transition GPU cost fixtures for `ajar bench` (PERFORMANCE §3).
///
/// One budgeted metric per kind family (crossDissolve, dip/fade, push/slide, wipe, zoom).
enum BenchmarkTransitionFixture {
    static func measure(metric: BenchmarkMetric) async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }
        let kind = try kind(for: metric)
        let fixture = try Fixture(device: device, kind: kind)
        let executor = try MetalRenderExecutor(device: device)
        let renderTime = try RationalTime(value: 12, timescale: 24)

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

    private static func kind(for metric: BenchmarkMetric) throws -> ClipVideoTransitionKind {
        switch metric {
        case .transitionCrossDissolve1080p:
            return .crossDissolve
        case .transitionDipFade1080p:
            return .dipToColor
        case .transitionPushSlide1080p:
            return .push
        case .transitionWipe1080p:
            return .wipe
        case .transitionZoom1080p:
            return .zoom
        default:
            throw AjarCLIError.benchmarkFailed(
                "metric \(metric.rawValue) is not a transition GPU cost metric"
            )
        }
    }

    private struct Fixture {
        let dimensions: PixelDimensions
        let project: Project
        let sequence: Sequence
        let sourceProvider: any RenderSourceTextureProvider

        init(device: MTLDevice, kind: ClipVideoTransitionKind) throws {
            dimensions = PixelDimensions(width: 1_920, height: 1_080)
            let mediaID = try Self.uuid(1)
            let sequenceID = try Self.uuid(2)
            let trackID = try Self.uuid(3)
            let outgoingID = try Self.uuid(4)
            let incomingID = try Self.uuid(5)
            let (outgoing, incoming) = try Self.edgeClips(
                mediaID: mediaID,
                outgoingID: outgoingID,
                incomingID: incomingID,
                kind: kind
            )
            let track = Track(
                id: trackID,
                kind: .video,
                items: [.clip(outgoing), .clip(incoming)]
            )
            sequence = Sequence(
                id: sequenceID,
                name: "bench-transition",
                videoTracks: [track],
                audioTracks: [],
                markers: [],
                timebase: try FrameRate(frames: 24)
            )
            let media = try Self.mediaRef(id: mediaID, dimensions: dimensions)
            project = Project(
                schemaVersion: AjarProjectCodec.currentSchemaVersion,
                settings: ProjectSettings(
                    frameRate: try FrameRate(frames: 24),
                    resolution: dimensions,
                    colorSpace: .rec709,
                    audioSampleRate: 48_000
                ),
                mediaPool: [media],
                sequences: [sequence]
            )
            let texture = try Self.makeSolidTexture(device: device, dimensions: dimensions)
            sourceProvider = ClosureRenderSourceTextureProvider { _ in texture }
        }

        private static func edgeClips(
            mediaID: UUID,
            outgoingID: UUID,
            incomingID: UUID,
            kind: ClipVideoTransitionKind
        ) throws -> (Clip, Clip) {
            let duration = try RationalTime(value: 4, timescale: 24)
            let ten = try RationalTime(value: 10, timescale: 24)
            let sourceRange = try TimeRange(start: .zero, duration: ten)
            let direction: ClipVideoTransitionDirection =
                kind == .wipe ? .topLeft : .right
            let record = ClipVideoTransition(
                partnerClipID: incomingID,
                duration: duration,
                kind: kind,
                direction: direction
            )
            let mirror = ClipVideoTransition(
                partnerClipID: outgoingID,
                duration: duration,
                kind: kind,
                direction: direction
            )
            let outgoing = Clip(
                id: outgoingID,
                source: .media(id: mediaID),
                sourceRange: sourceRange,
                timelineRange: try TimeRange(start: .zero, duration: ten),
                kind: .video,
                name: "bench-out",
                trailingTransition: record
            )
            let incoming = Clip(
                id: incomingID,
                source: .media(id: mediaID),
                sourceRange: sourceRange,
                timelineRange: try TimeRange(start: ten, duration: ten),
                kind: .video,
                name: "bench-in",
                leadingTransition: mirror
            )
            return (outgoing, incoming)
        }

        private static func mediaRef(
            id: UUID,
            dimensions: PixelDimensions
        ) throws -> MediaRef {
            MediaRef(
                id: id,
                sourceURL: URL(fileURLWithPath: "/tmp/bench-transition.mov"),
                contentHash: ContentHash.sha256(data: Data("bench-transition".utf8)),
                metadata: MediaMetadata(
                    codecID: "bgra",
                    pixelDimensions: dimensions,
                    frameRate: try FrameRate(frames: 24),
                    duration: try RationalTime(value: 240, timescale: 24),
                    colorSpace: .rec709,
                    audioChannelLayout: nil,
                    isVariableFrameRate: false,
                    conformedFrameRate: nil
                )
            )
        }

        private static func uuid(_ value: Int) throws -> UUID {
            let string = String(format: "00000000-0000-0000-0000-%012d", 8_000 + value)
            guard let id = UUID(uuidString: string) else {
                throw AjarCLIError.benchmarkFailed("invalid fixture UUID")
            }
            return id
        }

        private static func makeSolidTexture(
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
                throw MetalRenderError.metalDeviceUnavailable
            }
            // Mid-tone gray — never saturated.
            let pixel: [UInt8] = [128, 128, 128, 255]
            var bytes = [UInt8](
                repeating: 0,
                count: dimensions.width * dimensions.height * 4
            )
            for index in 0..<(dimensions.width * dimensions.height) {
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
}
