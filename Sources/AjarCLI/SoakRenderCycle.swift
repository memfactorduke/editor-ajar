// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarRender
import Foundation
import Metal

/// Per-iteration video cache statistics reported in the soak progress line.
struct SoakVideoCycleStats {
    let renderedFrameCount: Int
    let diskEntryCount: Int
    let quarantinedEntryCount: Int
    let diskPopulatedFrameCount: Int
}

/// Offline video render cycle for `ajar soak` (NFR-STAB-005).
///
/// Every iteration creates a fresh executor and disk-cache handle so their whole lifetimes are
/// inside the loop, then drives the known-risky cache paths: RAM-tier eviction (more distinct
/// frames than `maximumCacheEntryCount`), disk persist (write-behind readback route), disk
/// lookup warm-up via `prefetchCachedFrame`, read-time quarantine of a deliberately corrupted
/// entry, and a periodic full cache-directory reset.
final class SoakVideoRenderer {
    private let device: MTLDevice
    private let cacheDirectoryURL: URL
    private static let frameIndices: [Int64] = [0, 3, 6, 9, 12, 15]

    /// Fails (returns nil) when no Metal device is available; the soak then runs audio-only.
    init?(cacheDirectoryURL: URL) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.device = device
        self.cacheDirectoryURL = cacheDirectoryURL
    }

    /// Runs one full render + cache churn cycle over `sequence`.
    func runCycle(
        project: Project,
        sequence: Sequence,
        iteration: Int
    ) async throws -> SoakVideoCycleStats {
        if iteration % 3 == 0 {
            try? FileManager.default.removeItem(at: cacheDirectoryURL)
        }
        let diskCache = try MetalDiskFrameCache(
            device: device,
            directoryURL: cacheDirectoryURL,
            byteBudget: 64 * 1_024
        )
        let executor = try MetalRenderExecutor(
            device: device,
            maximumCacheEntryCount: 4,
            maximumPooledTextureCount: 4,
            diskCache: diskCache
        )
        let output = RenderOutputDescriptor(pixelDimensions: project.settings.resolution)
        let contentHashes = try await renderAndPersistFrames(
            project: project,
            sequence: sequence,
            executor: executor,
            diskCache: diskCache,
            output: output
        )

        diskCache.waitUntilIdle()
        corruptOneEntryFile()
        executor.removeAllCachedFrames()
        for contentHash in contentHashes {
            executor.prefetchCachedFrame(contentHash: contentHash, output: output)
        }
        diskCache.waitUntilIdle()
        try await renderOneWarmFrame(
            project: project,
            sequence: sequence,
            executor: executor,
            output: output
        )

        return SoakVideoCycleStats(
            renderedFrameCount: contentHashes.count,
            diskEntryCount: diskCache.storedEntryCount,
            quarantinedEntryCount: diskCache.quarantinedEntryCount,
            diskPopulatedFrameCount: executor.diskPopulatedFrameCount
        )
    }

    private func renderAndPersistFrames(
        project: Project,
        sequence: Sequence,
        executor: MetalRenderExecutor,
        diskCache: MetalDiskFrameCache,
        output: RenderOutputDescriptor
    ) async throws -> [ContentHash] {
        var contentHashes: [ContentHash] = []
        for frameIndex in Self.frameIndices {
            let renderTime = try RationalTime.atFrame(
                frameIndex,
                frameRate: project.settings.frameRate
            )
            let graph = try buildRenderGraph(for: sequence, at: renderTime, in: project)
            let sourceProvider = try await PredecodedSourceTextureProvider(
                graph: graph,
                project: project,
                device: device
            )
            let frame = try autoreleasepool {
                try executor.render(graph: graph, output: output, sourceProvider: sourceProvider)
            }
            try await frame.waitForCompletion()
            try await diskCache.persist(frame: frame, output: output)
            contentHashes.append(frame.contentHash)
        }
        return contentHashes
    }

    /// Renders the first frame again after the disk warm-up so populated RAM entries are read.
    private func renderOneWarmFrame(
        project: Project,
        sequence: Sequence,
        executor: MetalRenderExecutor,
        output: RenderOutputDescriptor
    ) async throws {
        guard let frameIndex = Self.frameIndices.first else {
            return
        }
        let renderTime = try RationalTime.atFrame(
            frameIndex,
            frameRate: project.settings.frameRate
        )
        let graph = try buildRenderGraph(for: sequence, at: renderTime, in: project)
        let sourceProvider = try await PredecodedSourceTextureProvider(
            graph: graph,
            project: project,
            device: device
        )
        let frame = try autoreleasepool {
            try executor.render(graph: graph, output: output, sourceProvider: sourceProvider)
        }
        try await frame.waitForCompletion()
    }

    /// Overwrites the lexicographically-first entry file with garbage so the next disk lookup
    /// exercises the read-time quarantine path (corrupt entries must read as misses).
    private func corruptOneEntryFile() {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: cacheDirectoryURL,
                includingPropertiesForKeys: nil
            )
        else {
            return
        }
        let target = entries
            .filter { $0.pathExtension == "ajarframe" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        guard let target else {
            return
        }
        try? Data("soak-corrupt-entry".utf8).write(to: target)
    }
}

/// Offline audio mix plus realtime plan handoff cycle for `ajar soak` (NFR-STAB-005).
///
/// The handoff lives for the whole run while plans are published and consumed every iteration,
/// so `ownedPointer` slot reclamation — the producer replacing retired plan storage under the
/// seq_cst hazard handshake — happens continuously across the soak.
final class SoakAudioCycle {
    private let handoff: RealtimeAudioRenderPlanHandoff
    private let sourceProvider: InMemoryAudioSourceProvider
    private let callbackBuffer: UnsafeMutableBufferPointer<Float>
    private static let publishesPerCycle = 4
    private static let callbacksPerPublish = 3

    /// Creates the run-long handoff and a preallocated callback output buffer.
    init(audioSources: [UUID: AudioSourceBuffer]) throws {
        handoff = try RealtimeAudioRenderPlanHandoff()
        sourceProvider = InMemoryAudioSourceProvider(sources: audioSources)
        callbackBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: 512 * 2)
        callbackBuffer.initialize(repeating: 0)
    }

    deinit {
        callbackBuffer.deallocate()
    }

    /// Mixes one second of the sequence (compound audio included), then runs publish/consume
    /// handoff cycles against the mixed plan. Returns the mixed frame count.
    func runCycle(project: Project, sequence: Sequence) throws -> Int {
        let range = try TimeRange(
            start: .zero,
            duration: project.settings.frameRate.duration(ofFrames: 24)
        )
        let buffer = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: range,
            sourceProvider: sourceProvider
        )
        for _ in 0..<Self.publishesPerCycle {
            try handoff.publish(RealtimeAudioRenderPlan(buffer: buffer))
            for _ in 0..<Self.callbacksPerPublish {
                handoff.withCurrentPlan { plan in
                    plan.render(into: callbackBuffer)
                }
            }
        }
        return buffer.frameCount
    }
}
