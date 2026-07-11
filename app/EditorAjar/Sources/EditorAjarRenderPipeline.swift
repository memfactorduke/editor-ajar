// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import AjarRender
import CoreVideo
import Foundation
import Metal

final class EditorAjarRenderPipeline {
    let device: MTLDevice
    private let decoder: VideoFrameDecoder
    private let executor: MetalRenderExecutor
    private let diskCache: MetalDiskFrameCache
    private let writeBehindTracker = DiskWriteBehindTracker()
    private let offlineSlateCache: AppOfflineSlateTextureCache
    /// Optional `.ajar` package root for resolving `caches/proxies/` paths (FR-MED-004).
    var packageRootURL: URL?

    init(cacheDirectoryURL: URL? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }
        self.device = device
        decoder = try VideoFrameDecoder(device: device)
        diskCache = try MetalDiskFrameCache(
            device: device,
            directoryURL: cacheDirectoryURL ?? Self.defaultCacheDirectoryURL()
        )
        executor = try MetalRenderExecutor(device: device, diskCache: diskCache)
        offlineSlateCache = AppOfflineSlateTextureCache(device: device)
    }

    func renderFrame(
        project: Project,
        sequence: Sequence,
        frame: Int64,
        allowDiskWriteBehind: Bool = true
    ) async throws -> EditorAjarRenderedFrame {
        let time = try RationalTime.atFrame(frame, frameRate: sequence.timebase)
        let packageRoot = packageRootURL
        let proxyFileExists: @Sendable (UUID) -> Bool = { mediaID in
            guard let media = project.mediaPool.first(where: { $0.id == mediaID }),
                  let relative = media.proxyState.readyRelativePath,
                  let packageRoot
            else {
                return false
            }
            let url = ProxyStorageLayout.absoluteURL(
                packageRootURL: packageRoot,
                relativePath: relative
            )
            return FileManager.default.isReadableFile(atPath: url.path)
        }
        var graph = try buildRenderGraph(
            for: sequence,
            at: time,
            in: project,
            proxyFileExists: proxyFileExists
        )
        let output = RenderOutputDescriptor(pixelDimensions: project.settings.resolution)
        guard let outputNode = graph.outputNode else {
            throw MetalRenderError.missingOutputNode(graph.outputNodeID)
        }
        if let texture = executor.cachedTexture(
            contentHash: outputNode.contentHash,
            output: output
        ) {
            return EditorAjarRenderedFrame(
                texture: texture,
                contentHash: outputNode.contentHash,
                cacheDisposition: .ramHit,
                runtimeOfflineMediaIDs: [],
                mediaIDsNeedingProxyGeneration: []
            )
        }
        let sourceProvider = try await AppSourceTextureProvider(
            graph: graph,
            project: project,
            decoder: decoder,
            offlineSlateCache: offlineSlateCache,
            packageRootURL: packageRoot
        )
        if !sourceProvider.runtimeOfflineMediaIDs.isEmpty {
            let runtimeProject = project.updatingMediaAvailability(
                .offline,
                for: sourceProvider.runtimeOfflineMediaIDs
            )
            graph = try buildRenderGraph(
                for: sequence,
                at: time,
                in: runtimeProject,
                proxyFileExists: proxyFileExists
            )
        }
        let renderedFrame = try executor.render(
            graph: graph,
            output: output,
            sourceProvider: sourceProvider
        )

        try await renderedFrame.waitForCompletion()
        if allowDiskWriteBehind, !renderedFrame.cacheHit {
            await writeBehindTracker.submit(
                diskCache: diskCache,
                frame: renderedFrame,
                output: output
            )
        }
        return EditorAjarRenderedFrame(
            texture: renderedFrame.texture,
            contentHash: renderedFrame.contentHash,
            cacheDisposition: renderedFrame.cacheDisposition,
            runtimeOfflineMediaIDs: sourceProvider.runtimeOfflineMediaIDs,
            mediaIDsNeedingProxyGeneration: sourceProvider.mediaIDsNeedingProxyGeneration
        )
    }

    func removeAllCachedFramesForTesting() {
        executor.removeAllCachedFrames()
    }

    func prefetchCachedFrameForTesting(
        contentHash: ContentHash,
        output: RenderOutputDescriptor
    ) {
        executor.prefetchCachedFrame(contentHash: contentHash, output: output)
    }

    var diskPopulatedFrameCountForTesting: Int {
        executor.diskPopulatedFrameCount
    }

    func waitForDiskWriteBehindForTesting() async {
        await writeBehindTracker.waitForAll()
    }

    private static func defaultCacheDirectoryURL() throws -> URL {
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw EditorAjarRenderError.cacheDirectoryUnavailable
        }
        return cachesURL
            .appendingPathComponent("org.editor-ajar.EditorAjar", isDirectory: true)
            .appendingPathComponent("render-frames", isDirectory: true)
    }
}

struct EditorAjarRenderedFrame {
    let texture: MTLTexture
    let contentHash: ContentHash
    let cacheDisposition: RenderFrameCacheDisposition
    let runtimeOfflineMediaIDs: Set<UUID>
    let mediaIDsNeedingProxyGeneration: Set<UUID>
}

private actor DiskWriteBehindTracker {
    private static let maximumPendingWrites = 2
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func submit(
        diskCache: MetalDiskFrameCache,
        frame: RenderedFrame,
        output: RenderOutputDescriptor
    ) {
        guard tasks.count < Self.maximumPendingWrites else {
            return
        }
        let id = UUID()
        tasks[id] = Task.detached(priority: .background) { [weak self] in
            try? await diskCache.persist(frame: frame, output: output)
            await self?.complete(id)
        }
    }

    func waitForAll() async {
        let pending = tasks.values
        for task in pending {
            await task.value
        }
    }

    private func complete(_ id: UUID) {
        tasks[id] = nil
    }
}

private struct AppSourceTextureKey: Hashable {
    let mediaID: UUID
    let clipID: UUID
    let sourceTime: RationalTime

    init(_ source: RenderSourceNode) {
        mediaID = source.mediaID
        clipID = source.clipID
        sourceTime = source.sourceTime
    }
}

private final class AppSourceTextureProvider: RenderSourceTextureProvider {
    private let textures: [AppSourceTextureKey: MTLTexture]
    private let retainedFrames: [DecodedFrame]
    let runtimeOfflineMediaIDs: Set<UUID>
    let mediaIDsNeedingProxyGeneration: Set<UUID>

    init(
        graph: RenderGraph,
        project: Project,
        decoder: VideoFrameDecoder,
        offlineSlateCache: AppOfflineSlateTextureCache,
        packageRootURL: URL?
    ) async throws {
        var textures: [AppSourceTextureKey: MTLTexture] = [:]
        var retainedFrames: [DecodedFrame] = []
        var runtimeOfflineMediaIDs = Set<UUID>()
        var mediaIDsNeedingProxyGeneration = Set<UUID>()

        for source in graph.renderSourceNodes() {
            let media = try Self.media(for: source.mediaID, in: project)
            if source.mediaAvailability == .offline || media.isOffline {
                textures[AppSourceTextureKey(source)] = try offlineSlateCache.texture(
                    dimensions: source.offlineSlateDimensions
                        ?? media.metadata.pixelDimensions
                        ?? project.settings.resolution
                )
                continue
            }

            // Re-enqueue signal uses an independent existence probe (may disagree with the
            // graph when the file disappeared after graph build). Decode tier follows the
            // graph node so content-hash and decode stay aligned (no cross-session cache
            // poisoning if a stale probe disagrees with `source.mediaSourceTier`).
            let proxyExists = Self.proxyFileExists(media: media, packageRootURL: packageRootURL)
            let decision = MediaProxyPlaybackResolver.resolve(
                preferProxy: project.settings.preferProxyPlayback,
                proxyState: media.proxyState,
                proxyFileExists: proxyExists
            )
            if decision.shouldReenqueueGeneration {
                mediaIDsNeedingProxyGeneration.insert(media.id)
            }

            do {
                let frame: DecodedFrame
                if source.mediaSourceTier == .proxy,
                   let relative = media.proxyState.readyRelativePath,
                   let packageRootURL {
                    let proxyURL = ProxyStorageLayout.absoluteURL(
                        packageRootURL: packageRootURL,
                        relativePath: relative
                    )
                    frame = try await decoder.decodeFrame(from: proxyURL, at: source.sourceTime)
                } else {
                    frame = try await decoder.decodeFrame(from: media, at: source.sourceTime)
                }
                guard let texture = CVMetalTextureGetTexture(frame.metalTexture) else {
                    throw EditorAjarRenderError.decodedTextureUnavailable(source.mediaID)
                }
                textures[AppSourceTextureKey(source)] = texture
                retainedFrames.append(frame)
            } catch let error as MediaDecodeError where error.indicatesOfflineSource {
                // The file may disappear after open-time reconciliation. Keep playback running.
                runtimeOfflineMediaIDs.insert(media.id)
                textures[AppSourceTextureKey(source)] = try offlineSlateCache.texture(
                    dimensions: source.offlineSlateDimensions
                        ?? media.metadata.pixelDimensions
                        ?? project.settings.resolution
                )
            }
        }

        self.textures = textures
        self.retainedFrames = retainedFrames
        self.runtimeOfflineMediaIDs = runtimeOfflineMediaIDs
        self.mediaIDsNeedingProxyGeneration = mediaIDsNeedingProxyGeneration
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = textures[AppSourceTextureKey(source)] else {
            throw EditorAjarRenderError.decodedTextureUnavailable(source.mediaID)
        }
        _ = retainedFrames.count
        return texture
    }

    private static func media(for mediaID: UUID, in project: Project) throws -> MediaRef {
        guard let media = project.mediaPool.first(where: { candidate in candidate.id == mediaID })
        else {
            throw EditorAjarRenderError.missingMedia(mediaID)
        }
        return media
    }

    private static func proxyFileExists(media: MediaRef, packageRootURL: URL?) -> Bool {
        guard let relative = media.proxyState.readyRelativePath,
              let packageRootURL
        else {
            return false
        }
        let url = ProxyStorageLayout.absoluteURL(
            packageRootURL: packageRootURL,
            relativePath: relative
        )
        return FileManager.default.isReadableFile(atPath: url.path)
    }
}

/// Pipeline-lifetime, thread-safe cache: an offline clip never reallocates its slate per frame.
private final class AppOfflineSlateTextureCache {
    private struct Entry {
        let texture: MTLTexture
        let byteCount: Int
        var lastAccess: UInt64
    }

    /// Bounds worst-case retained slate storage while allowing several common 4K sizes.
    private static let maximumCachedByteCount = 256 * 1_024 * 1_024
    private let device: MTLDevice
    private let lock = NSLock()
    private var entries: [PixelDimensions: Entry] = [:]
    private var cachedByteCount = 0
    private var accessCounter: UInt64 = 0

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(dimensions: PixelDimensions) throws -> MTLTexture {
        lock.lock()
        defer { lock.unlock() }
        accessCounter &+= 1
        if var entry = entries[dimensions] {
            entry.lastAccess = accessCounter
            entries[dimensions] = entry
            return entry.texture
        }
        let texture = try OfflineSlateRenderer.makeTexture(
            device: device,
            dimensions: dimensions
        )
        let estimatedByteCount = dimensions.width * dimensions.height * 4
        let byteCount = max(texture.allocatedSize, estimatedByteCount)
        guard byteCount <= Self.maximumCachedByteCount else {
            return texture
        }
        evictUntilSpaceIsAvailable(for: byteCount)
        entries[dimensions] = Entry(
            texture: texture,
            byteCount: byteCount,
            lastAccess: accessCounter
        )
        cachedByteCount += byteCount
        return texture
    }

    private func evictUntilSpaceIsAvailable(for byteCount: Int) {
        while cachedByteCount + byteCount > Self.maximumCachedByteCount,
            let oldest = entries.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            }) {
            entries[oldest.key] = nil
            cachedByteCount -= oldest.value.byteCount
        }
    }
}

enum EditorAjarRenderError: Error, CustomStringConvertible {
    case cacheDirectoryUnavailable
    case missingMedia(UUID)
    case decodedTextureUnavailable(UUID)

    var description: String {
        switch self {
        case .cacheDirectoryUnavailable:
            "the user cache directory is unavailable"
        case .missingMedia(let mediaID):
            "missing media \(mediaID)"
        case .decodedTextureUnavailable(let mediaID):
            "decoded media \(mediaID) did not expose a Metal texture"
        }
    }
}

private extension RenderGraph {
    func renderSourceNodes() -> [RenderSourceNode] {
        var sources: [RenderSourceNode] = []
        for node in nodes {
            switch node.kind {
            case .source(let source):
                sources.append(source)
            case .compound(let compound):
                sources.append(contentsOf: compound.graph.renderSourceNodes())
            case .title, .transition, .composite:
                continue
            }
        }
        return sources
    }
}
