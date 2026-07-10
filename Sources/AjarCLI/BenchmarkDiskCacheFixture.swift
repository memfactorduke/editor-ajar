// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

/// Prepares a warm disk frame cache for the FR-PLAY-005 warm-start benchmark.
///
/// The fixture renders the benchmark project's first frame once and persists it through the
/// offline population route, leaving a cache directory that fresh executor instances can warm
/// their RAM tier from without decoding or rendering.
final class BenchmarkDiskCacheFixture {
    /// Directory containing the persisted warm entry.
    let cacheDirectoryURL: URL

    /// The loaded benchmark project.
    let project: Project

    /// The sequence rendered into the warm entry.
    let sequence: AjarCore.Sequence

    /// Output descriptor matching the persisted entry identity.
    let output: RenderOutputDescriptor

    /// Frame time of the persisted entry.
    let renderTime: RationalTime

    init(projectURL: URL, device: MTLDevice) async throws {
        // Bench fixture reads only — higher-minor (read-only) packages are allowed.
        project = try ProjectPackageIO.loadProject(from: projectURL).project
        guard let sequence = project.sequences.first else {
            throw AjarCLIError.missingSequence
        }
        self.sequence = sequence
        output = RenderOutputDescriptor(pixelDimensions: project.settings.resolution)
        renderTime = try RationalTime.atFrame(0, frameRate: project.settings.frameRate)
        cacheDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-benchmarks")
            .appendingPathComponent("disk-frame-cache-\(UUID().uuidString)")

        let diskCache = try MetalDiskFrameCache(device: device, directoryURL: cacheDirectoryURL)
        let executor = try MetalRenderExecutor(device: device, diskCache: diskCache)
        let graph = try buildRenderGraph(for: sequence, at: renderTime, in: project)
        let sourceProvider = try await PredecodedSourceTextureProvider(
            graph: graph,
            project: project,
            device: device
        )
        let frame = try executor.render(
            graph: graph,
            output: output,
            sourceProvider: sourceProvider
        )
        try await diskCache.persist(frame: frame, output: output)
    }

    func removeGeneratedFiles() {
        try? FileManager.default.removeItem(at: cacheDirectoryURL)
    }
}
