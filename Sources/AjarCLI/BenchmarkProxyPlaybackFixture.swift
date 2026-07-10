// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import AjarRender
import Foundation
import Metal

/// Heavy-timeline proxy-on vs original **comparison** benchmark (FR-MED-004).
///
/// ## What this measures
/// Wall-clock median of: clear RAM frame cache → build render graph → **predecode** every
/// source (original 1080p or ready half-res proxy) → GPU composite four stacked layers with
/// transforms → wait for completion. Decode runs **inside** the measured loop.
///
/// ## What this is not
/// Not a gated NFR-PERF-003 real-time budget. Synthetic ProRes predecode + full-frame GPU
/// composite on Apple Silicon is typically well above one 30 fps frame (~33 ms). Metrics are
/// unbudgeted (`BenchmarkMetric.budget == nil`) so the pair is interpreted as a **relative**
/// original-vs-proxy ratio, not a failing gate when absolute cost is high.
enum BenchmarkProxyPlaybackFixture {
    static func measure(metric: BenchmarkMetric) async throws -> Double {
        let preferProxy: Bool
        switch metric {
        case .proxyPlaybackHeavyOriginal:
            preferProxy = false
        case .proxyPlaybackHeavyProxy:
            preferProxy = true
        default:
            throw AjarCLIError.benchmarkFailed(
                "BenchmarkProxyPlaybackFixture does not handle \(metric.rawValue)"
            )
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-bench-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try makeFixture(in: directory, preferProxy: preferProxy)
        let executor = try MetalRenderExecutor(device: device)
        let time = try RationalTime.atFrame(0, frameRate: fixture.project.settings.frameRate)
        let proxyFileExists: @Sendable (UUID) -> Bool = { mediaID in
            fixture.proxyExistsByMediaID[mediaID] ?? false
        }

        return try await BenchmarkCommand.medianMilliseconds {
            executor.removeAllCachedFrames()
            let graph = try buildRenderGraph(
                for: fixture.sequence,
                at: time,
                in: fixture.project,
                proxyFileExists: proxyFileExists
            )
            let sourceProvider = try await PredecodedSourceTextureProvider(
                graph: graph,
                project: fixture.project,
                device: device,
                packageRootURL: fixture.packageRootURL,
                decodeURLOverride: fixture.decodeURLByMediaID
            )
            let frame = try executor.render(
                graph: graph,
                output: RenderOutputDescriptor(
                    pixelDimensions: fixture.project.settings.resolution
                ),
                sourceProvider: sourceProvider
            )
            try await frame.waitForCompletion()
        }
    }

    private struct Fixture {
        let project: Project
        let sequence: Sequence
        let packageRootURL: URL
        let proxyExistsByMediaID: [UUID: Bool]
        let decodeURLByMediaID: [UUID: URL]
    }

    private static func makeFixture(in directory: URL, preferProxy: Bool) throws -> Fixture {
        let frameRate = try FrameRate(frames: 30)
        let mediaID = UUID()
        let movies = try writeProxyBenchMovies(
            directory: directory,
            mediaID: mediaID,
            frameRate: frameRate
        )
        let duration = try frameRate.duration(ofFrames: Int64(movies.frameCount))
        let media = MediaRef(
            id: mediaID,
            sourceURL: movies.originalURL,
            contentHash: movies.contentHash,
            metadata: MediaMetadata(
                codecID: "prores",
                pixelDimensions: movies.originalDims,
                frameRate: frameRate,
                duration: duration,
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            ),
            proxyState: .ready(relativePath: movies.relativePath)
        )
        let sequence = try makeHeavySequence(
            mediaID: mediaID,
            duration: duration,
            frameRate: frameRate
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 1_920, height: 1_080),
                colorSpace: .rec709,
                audioSampleRate: 48_000,
                preferProxyPlayback: preferProxy
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
        var decodeURLs: [UUID: URL] = [mediaID: movies.originalURL]
        if preferProxy {
            decodeURLs[mediaID] = movies.proxyURL
        }
        return Fixture(
            project: project,
            sequence: sequence,
            packageRootURL: movies.packageRoot,
            proxyExistsByMediaID: [mediaID: true],
            decodeURLByMediaID: decodeURLs
        )
    }

    private struct MoviePair {
        let originalURL: URL
        let proxyURL: URL
        let packageRoot: URL
        let relativePath: String
        let contentHash: ContentHash
        let originalDims: PixelDimensions
        let frameCount: Int
    }

    private static func writeProxyBenchMovies(
        directory: URL,
        mediaID: UUID,
        frameRate: FrameRate
    ) throws -> MoviePair {
        let originalSpec = SyntheticMovieSpec(
            width: 1_920,
            height: 1_080,
            frameCount: 4,
            frameRate: Int32(frameRate.frames),
            bgra: [40, 80, 160, 255]
        )
        let originalURL = directory.appendingPathComponent("heavy-original.mov")
        try SyntheticMovieWriter.writeMovie(to: originalURL, spec: originalSpec)
        let contentHash = ContentHash.sha256(data: Data("proxy-bench-original".utf8))
        let originalDims = PixelDimensions(width: originalSpec.width, height: originalSpec.height)
        let proxyDims = MediaProxyResolutionPolicy.proxyDimensions(for: originalDims)
        let relativePath = ProxyStorageLayout.relativePath(
            mediaID: mediaID,
            contentHash: contentHash,
            resolution: proxyDims
        )
        let packageRoot = directory.appendingPathComponent("bench.ajar", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try ProxyStorageLayout.ensureProxiesDirectory(packageRootURL: packageRoot)
        let proxyURL = ProxyStorageLayout.absoluteURL(
            packageRootURL: packageRoot,
            relativePath: relativePath
        )
        try SyntheticMovieWriter.writeMovie(
            to: proxyURL,
            spec: SyntheticMovieSpec(
                width: proxyDims.width,
                height: proxyDims.height,
                frameCount: originalSpec.frameCount,
                frameRate: Int32(frameRate.frames),
                bgra: [20, 40, 80, 255]
            )
        )
        return MoviePair(
            originalURL: originalURL,
            proxyURL: proxyURL,
            packageRoot: packageRoot,
            relativePath: relativePath,
            contentHash: contentHash,
            originalDims: originalDims,
            frameCount: originalSpec.frameCount
        )
    }

    private static func makeHeavySequence(
        mediaID: UUID,
        duration: RationalTime,
        frameRate: FrameRate
    ) throws -> Sequence {
        // Four stacked layers with transforms — decode pressure on original 1080p sources.
        var clips: [Clip] = []
        for index in 0..<4 {
            clips.append(
                Clip(
                    id: UUID(),
                    source: .media(id: mediaID),
                    sourceRange: try TimeRange(start: .zero, duration: duration),
                    timelineRange: try TimeRange(start: .zero, duration: duration),
                    kind: .video,
                    name: "Heavy \(index)",
                    transform: ClipTransform(
                        position: CanvasPoint(
                            x: RationalValue(Int64(index * 20)),
                            y: RationalValue(Int64(index * 10))
                        ),
                        scale: ClipScale(
                            x: try RationalValue(numerator: 9, denominator: 10),
                            y: try RationalValue(numerator: 9, denominator: 10)
                        )
                    )
                )
            )
        }
        return Sequence(
            id: UUID(),
            name: "Proxy heavy timeline",
            videoTracks: clips.map { clip in
                Track(id: UUID(), kind: .video, items: [.clip(clip)])
            },
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
    }
}
