// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarExport
import AjarMedia
import AjarRender
import CoreVideo
import Foundation
import Metal

/// MainActor bridge over the headless `ExportQueue` actor (FR-EXP-005).
///
/// The pure state machine and sequential drain live in `AjarExport`. This type only:
/// - builds production `ExportSession`s (render-graph + original-media decode)
/// - mirrors job snapshots into `@Published` for SwiftUI
/// - captures project **value** snapshots at enqueue time
@MainActor
final class EditorAjarExportQueueController: ObservableObject {
    /// Ordered job rows for the queue panel.
    @Published private(set) var jobs: [ExportJobSnapshot] = []

    /// Last enqueue/control error message for the UI (nil when clear).
    @Published private(set) var statusMessage: String?

    private let queue: ExportQueue
    private var observeTask: Task<Void, Never>?

    /// Creates a controller with an injectable session factory (tests use stubs).
    init(sessionFactory: @escaping ExportSessionFactory) {
        queue = ExportQueue(sessionFactory: sessionFactory)
        startObservingQueue()
    }

    /// Creates a controller whose single serial queue can run movie and animated-GIF jobs.
    init(
        sessionFactory: @escaping ExportSessionFactory,
        animatedGIFSessionFactory: @escaping AnimatedGIFExportSessionFactory
    ) {
        queue = ExportQueue(
            sessionFactory: sessionFactory,
            animatedGIFSessionFactory: animatedGIFSessionFactory
        )
        startObservingQueue()
    }

    private func startObservingQueue() {
        observeTask = Task { [weak self] in
            guard let stream = await self?.queue.snapshotStream() else {
                return
            }
            for await snapshots in stream {
                guard let self else {
                    return
                }
                self.jobs = snapshots
            }
        }
    }

    /// Production factory: render-graph frames + AVFoundation hardware encode.
    convenience init() {
        self.init(
            sessionFactory: Self.makeProductionSessionFactory(),
            animatedGIFSessionFactory: Self.makeProductionAnimatedGIFSessionFactory()
        )
    }

    deinit {
        observeTask?.cancel()
    }

    /// Enqueues an export of `project`/`sequence` using a **value snapshot** of the project.
    @discardableResult
    func enqueueExport(
        project: Project,
        sequenceID: UUID,
        range: TimeRange,
        destinationURL: URL,
        settings: ExportSettings,
        displayName: String
    ) async throws -> UUID {
        // `ExportRequest` stores `project` by value — live edits after this line cannot race the job.
        let request = try ExportRequest(
            project: project,
            sequenceID: sequenceID,
            range: range,
            destinationURL: destinationURL,
            settings: settings
        )
        let jobID = try await queue.enqueue(request: request, displayName: displayName)
        statusMessage = nil
        return jobID
    }

    /// Enqueues a deterministic animated-GIF export in the same serial background queue.
    @discardableResult
    func enqueueAnimatedGIFExport(
        project: Project,
        sequenceID: UUID,
        range: TimeRange,
        destinationURL: URL,
        settings: AnimatedGIFExportSettings,
        displayName: String
    ) async throws -> UUID {
        let request = try AnimatedGIFExportRequest(
            project: project,
            sequenceID: sequenceID,
            range: range,
            destinationURL: destinationURL,
            settings: settings
        )
        let jobID = try await queue.enqueue(
            animatedGIFRequest: request,
            displayName: displayName
        )
        statusMessage = nil
        return jobID
    }

    func cancel(jobID: UUID) async throws {
        try await queue.cancel(jobID: jobID)
        statusMessage = nil
    }

    func pause(jobID: UUID) async throws {
        try await queue.pause(jobID: jobID)
        statusMessage = nil
    }

    func resume(jobID: UUID) async throws {
        try await queue.resume(jobID: jobID)
        statusMessage = nil
    }

    func presentError(_ error: Error) {
        statusMessage = String(describing: error)
    }

    /// Default ProRes MOV settings for the active sequence canvas (CI-friendly codec).
    static func defaultSettings(for project: Project) throws -> ExportSettings {
        let colorSpace: ExportColorSpace
        switch project.settings.colorSpace {
        case .displayP3:
            colorSpace = .displayP3
        case .sRGB:
            colorSpace = .sRGB
        case .rec709:
            colorSpace = .rec709
        case .rec2020, .unspecified, .unknown:
            throw ExportError.colorSpaceMismatch(
                project: project.settings.colorSpace,
                export: .rec709
            )
        }
        return try ExportSettings(
            container: .mov,
            video: ExportVideoSettings(
                codec: .proRes422,
                resolution: project.settings.resolution,
                frameRate: project.settings.frameRate,
                colorSpace: colorSpace
            ),
            audio: ExportAudioSettings(
                codec: .linearPCM,
                sampleRate: project.settings.audioSampleRate,
                channelCount: 2
            )
        )
    }

    private static func makeProductionSessionFactory() -> ExportSessionFactory {
        { jobID, request, onProgress in
            do {
                let sourceProvider = try EditorAjarExportSourceProvider(
                    project: request.project
                )
                let frameProvider = try RenderGraphExportFrameProvider(
                    project: request.project,
                    sequence: request.sequence,
                    videoSettings: request.settings.video,
                    sourceProvider: sourceProvider
                )
                return ExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: frameProvider,
                    audioSourceProviderFactory: { audioRange in
                        try await EditorAjarProjectAudioSourceProvider.prepare(
                            project: request.project,
                            sequence: request.sequence,
                            range: audioRange,
                            outputSampleRate: request.settings.audio?.sampleRate
                        )
                    },
                    onFrameProgress: onProgress
                )
            } catch {
                return ExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: FailingExportFrameProvider(
                        reason: String(describing: error)
                    ),
                    audioSourceProviderFactory: { audioRange in
                        try await EditorAjarProjectAudioSourceProvider.prepare(
                            project: request.project,
                            sequence: request.sequence,
                            range: audioRange,
                            outputSampleRate: request.settings.audio?.sampleRate
                        )
                    },
                    onFrameProgress: onProgress
                )
            }
        }
    }

    private static func makeProductionAnimatedGIFSessionFactory()
        -> AnimatedGIFExportSessionFactory
    {
        { jobID, request, onProgress in
            do {
                let sourceProvider = try EditorAjarExportSourceProvider(
                    project: request.project
                )
                let frameProvider = try RenderGraphExportFrameProvider(
                    project: request.project,
                    sequence: request.sequence,
                    resolution: request.settings.resolution,
                    colorSpace: request.settings.sourceColorSpace,
                    sourceProvider: sourceProvider
                )
                return AnimatedGIFExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: frameProvider,
                    onFrameProgress: onProgress
                )
            } catch {
                return AnimatedGIFExportSession(
                    id: jobID,
                    request: request,
                    frameProvider: FailingExportFrameProvider(
                        reason: String(describing: error)
                    ),
                    onFrameProgress: onProgress
                )
            }
        }
    }
}

/// Original-media texture provider for export (ADR-0019 injects decode; no AjarMedia in AjarExport).
final class EditorAjarExportSourceProvider: ExportRenderSourceProvider, @unchecked Sendable {
    private struct SourceKey: Hashable {
        let mediaID: UUID
        let clipID: UUID
        let sourceTime: RationalTime

        init(_ source: RenderSourceNode) {
            mediaID = source.mediaID
            clipID = source.clipID
            sourceTime = source.sourceTime
        }
    }

    private let project: Project
    private let decoder: VideoFrameDecoder
    private let lock = NSLock()
    private var textures: [SourceKey: MTLTexture] = [:]
    private var retainedFrames: [DecodedFrame] = []

    init(project: Project) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "Metal device unavailable for export decode"
            )
        }
        self.project = project
        decoder = try VideoFrameDecoder(device: device)
    }

    func prepare(graph: RenderGraph) async throws {
        var nextTextures: [SourceKey: MTLTexture] = [:]
        var nextRetained: [DecodedFrame] = []
        // A compound node owns another complete render graph. Preparing only the outer graph
        // leaves its nested media undecoded, so the executor later fails when it descends into the
        // compound. Walk every nested graph up front and keep those decoded frames alive alongside
        // ordinary top-level sources for the duration of this export frame.
        for source in Self.sourceNodes(in: graph) {
            guard let media = project.mediaPool.first(where: { $0.id == source.mediaID }) else {
                throw ExportError.frameRenderFailed(
                    frameIndex: 0,
                    reason: "missing media \(source.mediaID)"
                )
            }
            let frame = try await decoder.decodeFrame(from: media, at: source.sourceTime)
            guard let texture = CVMetalTextureGetTexture(frame.metalTexture) else {
                throw ExportError.frameRenderFailed(
                    frameIndex: 0,
                    reason: "decoded media \(source.mediaID) has no Metal texture"
                )
            }
            nextTextures[SourceKey(source)] = texture
            nextRetained.append(frame)
        }
        lock.lock()
        textures = nextTextures
        retainedFrames = nextRetained
        lock.unlock()
    }

    private static func sourceNodes(in graph: RenderGraph) -> [RenderSourceNode] {
        graph.nodes.flatMap { node in
            switch node.kind {
            case .source(let source):
                return [source]
            case .compound(let compound):
                return sourceNodes(in: compound.graph)
            case .title, .transition, .composite:
                return []
            }
        }
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        lock.lock()
        defer { lock.unlock() }
        guard let texture = textures[SourceKey(source)] else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "export source texture unavailable for media \(source.mediaID)"
            )
        }
        _ = retainedFrames.count
        return texture
    }
}

/// Surfaces session-factory construction failures as a typed frame error on first pull.
private final class FailingExportFrameProvider: ExportVideoFrameProvider, @unchecked Sendable {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func renderFrame(
        at _: RationalTime,
        into _: CVPixelBuffer
    ) async throws {
        throw ExportError.frameRenderFailed(frameIndex: 0, reason: reason)
    }
}
