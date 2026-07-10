// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreVideo
import Foundation
import Metal
import XCTest

@testable import AjarExport

final class ProxyGenerationTests: XCTestCase {
    func testFRMED004ProRes422ProxyIsProResAndMOVOnly() throws {
        XCTAssertTrue(ExportVideoCodec.proRes422Proxy.isProRes)
        XCTAssertFalse(ExportVideoCodec.proRes422Proxy.requiresHardwareEncoder)

        let video = try ExportVideoSettings(
            codec: .proRes422Proxy,
            resolution: PixelDimensions(width: 640, height: 360),
            frameRate: FrameRate(frames: 24),
            colorSpace: .rec709
        )
        let settings = try ExportSettings(container: .mov, video: video, audio: nil)
        XCTAssertEqual(settings.video.codec, .proRes422Proxy)

        XCTAssertThrowsError(
            try ExportSettings(
                container: .mp4,
                video: video,
                audio: nil
            )
        )
    }

    func testFRMED004ProxyGenerationSessionWithSolidStubCodec() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-proxy-gen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("proxy.mov")
        let request = try makeRequest(
            destinationURL: destination,
            relativePath: "caches/proxies/test.mov",
            frameCount: 3
        )
        let session = ProxyGenerationSession(
            request: request,
            frameProvider: SolidColorProxySourceFrameProvider()
        )
        let result = try await session.run()
        XCTAssertEqual(result.videoFrameCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(result.relativePath, request.relativePath)
    }

    func testFRMED004ProxyGenerationQueueCompletesWithStubProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-proxy-q-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaID = UUID()
        let destination = directory.appendingPathComponent("queued-proxy.mov")
        let request = try makeRequest(
            mediaID: mediaID,
            destinationURL: destination,
            relativePath: "caches/proxies/queued.mov",
            frameCount: 2
        )
        let queue = ProxyGenerationQueue { _, request, onProgress in
            ProxyGenerationSession(
                request: request,
                frameProvider: SolidColorProxySourceFrameProvider(),
                onFrameProgress: onProgress
            )
        }
        let jobID = await queue.enqueue(
            ProxyGenerationJob(
                mediaID: mediaID,
                displayName: "Test proxy",
                request: request
            )
        )

        let state = try await waitForTerminalState(queue: queue, jobID: jobID)
        XCTAssertEqual(state, .done)
        let result = await queue.result(for: jobID)
        XCTAssertEqual(result?.mediaID, mediaID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFRMED004CancelMidWriteLeavesNoProxyFileAndCancelledState() async throws {
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-proxy-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let proxiesDir = packageRoot
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent("proxies", isDirectory: true)
        try FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)

        let mediaID = UUID()
        let relativePath = "caches/proxies/\(mediaID.uuidString.lowercased())-cancel.mov"
        let destination = proxiesDir.appendingPathComponent(
            "\(mediaID.uuidString.lowercased())-cancel.mov"
        )
        let request = try makeRequest(
            mediaID: mediaID,
            destinationURL: destination,
            relativePath: relativePath,
            frameCount: 30
        )
        let queue = ProxyGenerationQueue { _, request, onProgress in
            ProxyGenerationSession(
                request: request,
                frameProvider: SlowSolidProxySourceFrameProvider(
                    delayNanoseconds: 200_000_000
                ),
                onFrameProgress: onProgress
            )
        }
        let jobID = await queue.enqueue(
            ProxyGenerationJob(
                mediaID: mediaID,
                displayName: "Cancel proxy",
                request: request
            )
        )

        let runningDeadline = Date().addingTimeInterval(10)
        while Date() < runningDeadline {
            if await queue.state(for: jobID) == .running {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let runningState = await queue.state(for: jobID)
        XCTAssertEqual(runningState, .running)

        try await queue.cancel(jobID: jobID)
        let state = try await waitForTerminalState(queue: queue, jobID: jobID, timeout: 30)
        XCTAssertEqual(state, .cancelled)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "cancel must not publish a proxy under caches/proxies/"
        )
        // No partial destination; temp .ajar-partial files are cleaned up by the session.
        let residual = try FileManager.default.contentsOfDirectory(
            at: proxiesDir,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            residual.isEmpty,
            "proxies directory should have no residual files after cancel, got \(residual)"
        )
    }

    func testFRMED004FailMidWriteLeavesNoProxyFileAndFailedState() async throws {
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-proxy-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let proxiesDir = packageRoot
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent("proxies", isDirectory: true)
        try FileManager.default.createDirectory(at: proxiesDir, withIntermediateDirectories: true)

        let mediaID = UUID()
        let relativePath = "caches/proxies/\(mediaID.uuidString.lowercased())-fail.mov"
        let destination = proxiesDir.appendingPathComponent(
            "\(mediaID.uuidString.lowercased())-fail.mov"
        )
        let request = try makeRequest(
            mediaID: mediaID,
            destinationURL: destination,
            relativePath: relativePath,
            frameCount: 8
        )
        let queue = ProxyGenerationQueue { _, request, onProgress in
            ProxyGenerationSession(
                request: request,
                frameProvider: FailAfterFramesProxySourceFrameProvider(failAfterIndex: 1),
                onFrameProgress: onProgress
            )
        }
        let jobID = await queue.enqueue(
            ProxyGenerationJob(
                mediaID: mediaID,
                displayName: "Fail proxy",
                request: request
            )
        )

        let state = try await waitForTerminalState(queue: queue, jobID: jobID, timeout: 60)
        XCTAssertEqual(state, .failed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "failed job must not publish a proxy under caches/proxies/"
        )
        let residual = try FileManager.default.contentsOfDirectory(
            at: proxiesDir,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            residual.isEmpty,
            "proxies directory should have no residual files after fail, got \(residual)"
        )
    }

    func testFRMED004ExportUsesOriginalsViaAuditHookEvenWhenProxyPreferenceOn() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-proxy-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try makeProxyExportAuditFixture()
        let project = fixture.project
        let sequence = fixture.sequence
        let frameRate = fixture.frameRate
        let duration = fixture.duration

        // Sanity: playback graph would select proxy if the file probe returned true.
        try assertPlaybackGraphSelectsProxy(project: project, sequence: sequence)

        let destination = directory.appendingPathComponent("export.mov")
        let settings = try ExportSettings(
            container: .mov,
            video: ExportVideoSettings(
                codec: .proRes422,
                resolution: PixelDimensions(width: 64, height: 36),
                frameRate: frameRate,
                colorSpace: .rec709
            ),
            audio: nil
        )
        let request = try ExportRequest(
            project: project,
            sequenceID: sequence.id,
            range: try TimeRange(start: .zero, duration: duration),
            destinationURL: destination,
            settings: settings
        )
        let frameProvider = try RenderGraphExportFrameProvider(
            project: project,
            sequence: sequence,
            videoSettings: settings.video,
            sourceProvider: try SolidTextureExportProvider()
        )
        let session = ExportSession(
            request: request,
            frameProvider: frameProvider,
            sourceSelectionPolicy: .alwaysOriginalForProxyEnabledProject
        )
        _ = try await session.run()

        let records = session.sourceSelectionRecords
        XCTAssertFalse(records.isEmpty, "export must record per-frame source tiers from the graph")
        XCTAssertTrue(
            records.allSatisfy { $0.tier == .original },
            "FR-EXP-007: export graph must stay original-only even when preferProxyPlayback is on"
        )
        XCTAssertFalse(records.contains { $0.tier == .proxy })
    }

    // MARK: - Helpers

    private func makeRequest(
        mediaID: UUID = UUID(),
        destinationURL: URL,
        relativePath: String,
        frameCount: Int64
    ) throws -> ProxyGenerationRequest {
        ProxyGenerationRequest(
            mediaID: mediaID,
            sourceURL: URL(fileURLWithPath: "/unused/original.mov"),
            destinationURL: destinationURL,
            relativePath: relativePath,
            resolution: PixelDimensions(width: 64, height: 36),
            frameCount: frameCount,
            frameRate: try FrameRate(frames: 24)
        )
    }

    private func waitForTerminalState(
        queue: ProxyGenerationQueue,
        jobID: UUID,
        timeout: TimeInterval = 60
    ) async throws -> ExportJobState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = await queue.state(for: jobID) {
                switch state {
                case .done, .failed, .cancelled:
                    return state
                case .pending, .running, .pausedWillRestart:
                    break
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for proxy job \(jobID)")
        return .failed
    }
}

/// Immutable inputs for the FR-EXP-007 export-audit test (built at file scope to keep the
/// test type body small).
private struct ProxyExportAuditFixture {
    let project: Project
    let sequence: Sequence
    let frameRate: FrameRate
    let duration: RationalTime
}

/// Asserts the playback graph (probe = ready) would select the proxy tier for the fixture.
private func assertPlaybackGraphSelectsProxy(
    project: Project,
    sequence: Sequence,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let graph = try buildRenderGraph(
        for: sequence,
        at: .zero,
        in: project,
        proxyFileExists: { _ in true }
    )
    let tiers = graph.nodes.compactMap { node -> MediaSourceTier? in
        if case .source(let source) = node.kind {
            return source.mediaSourceTier
        }
        return nil
    }
    XCTAssertEqual(tiers, [.proxy], file: file, line: line)
}

/// Builds a one-clip project whose media has a `.ready` proxy and `preferProxyPlayback = true`.
private func makeProxyExportAuditFixture() throws -> ProxyExportAuditFixture {
    let frameRate = try FrameRate(frames: 30)
    let duration = try frameRate.duration(ofFrames: 4)
    let mediaID = UUID()
    let relativePath = "caches/proxies/\(mediaID.uuidString.lowercased())-ready.mov"
    let media = MediaRef(
        id: mediaID,
        sourceURL: URL(fileURLWithPath: "/media/original.mov"),
        contentHash: ContentHash.sha256(data: Data("export-proxy-audit".utf8)),
        metadata: MediaMetadata(
            codecID: "prores",
            pixelDimensions: PixelDimensions(width: 64, height: 36),
            frameRate: frameRate,
            duration: duration,
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        ),
        proxyState: .ready(relativePath: relativePath)
    )
    let clip = Clip(
        id: UUID(),
        source: .media(id: mediaID),
        sourceRange: try TimeRange(start: .zero, duration: duration),
        timelineRange: try TimeRange(start: .zero, duration: duration),
        kind: .video,
        name: "Proxy audit"
    )
    let sequence = Sequence(
        id: UUID(),
        name: "Export proxy audit",
        videoTracks: [Track(id: UUID(), kind: .video, items: [.clip(clip)])],
        audioTracks: [],
        markers: [],
        timebase: frameRate
    )
    let project = Project(
        schemaVersion: AjarProjectCodec.currentSchemaVersion,
        settings: ProjectSettings(
            frameRate: frameRate,
            resolution: PixelDimensions(width: 64, height: 36),
            colorSpace: .rec709,
            audioSampleRate: 48_000,
            preferProxyPlayback: true
        ),
        mediaPool: [media],
        sequences: [sequence]
    )
    return ProxyExportAuditFixture(
        project: project,
        sequence: sequence,
        frameRate: frameRate,
        duration: duration
    )
}

/// Supplies a solid opaque texture for every source node so the export graph actually renders.
///
/// The strengthened FR-EXP-007 audit records tiers from the **executed** graph, so the export must
/// complete a frame; `SourceLessExportProvider` rejects media nodes and cannot be used here.
private final class SolidTextureExportProvider: ExportRenderSourceProvider {
    private let device: MTLDevice
    private var textures: [UUID: MTLTexture] = [:]

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExportError.frameRenderFailed(frameIndex: 0, reason: "no Metal device")
        }
        self.device = device
    }

    func prepare(graph: RenderGraph) async throws {
        for node in graph.nodes {
            guard case .source(let source) = node.kind else {
                continue
            }
            if textures[source.mediaID] == nil {
                textures[source.mediaID] = try makeSolidTexture()
            }
        }
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = textures[source.mediaID] else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "no stub texture for \(source.mediaID)"
            )
        }
        return texture
    }

    private func makeSolidTexture() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 64,
            height: 36,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ExportError.frameRenderFailed(
                frameIndex: 0,
                reason: "stub texture allocation failed"
            )
        }
        return texture
    }
}

/// Solid fill with a cooperative delay so cancel can land mid-write.
private final class SlowSolidProxySourceFrameProvider: ProxySourceFrameProvider,
@unchecked Sendable {
    private let delayNanoseconds: UInt64
    private let solid = SolidColorProxySourceFrameProvider()

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func provideFrame(index: Int64, into pixelBuffer: CVPixelBuffer) async throws {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        try await solid.provideFrame(index: index, into: pixelBuffer)
    }
}

/// Solid fill that throws after a successful first frame (mid-write failure).
private final class FailAfterFramesProxySourceFrameProvider: ProxySourceFrameProvider,
@unchecked Sendable {
    private let failAfterIndex: Int64
    private let solid = SolidColorProxySourceFrameProvider()

    init(failAfterIndex: Int64) {
        self.failAfterIndex = failAfterIndex
    }

    func provideFrame(index: Int64, into pixelBuffer: CVPixelBuffer) async throws {
        if index >= failAfterIndex {
            throw ExportError.frameRenderFailed(
                frameIndex: index,
                reason: "injected mid-write proxy failure"
            )
        }
        try await solid.provideFrame(index: index, into: pixelBuffer)
    }
}
