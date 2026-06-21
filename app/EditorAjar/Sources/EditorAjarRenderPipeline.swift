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

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }
        self.device = device
        decoder = try VideoFrameDecoder(device: device)
        executor = try MetalRenderExecutor(device: device)
    }

    func renderFrame(project: Project, sequence: Sequence, frame: Int64) async throws -> MTLTexture {
        let time = try RationalTime.atFrame(frame, frameRate: sequence.timebase)
        let graph = try buildRenderGraph(for: sequence, at: time, in: project)
        let sourceProvider = try await AppSourceTextureProvider(
            graph: graph,
            project: project,
            decoder: decoder
        )
        let renderedFrame = try executor.render(
            graph: graph,
            output: RenderOutputDescriptor(pixelDimensions: project.settings.resolution),
            sourceProvider: sourceProvider
        )

        try await renderedFrame.waitForCompletion()
        return renderedFrame.texture
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

    init(graph: RenderGraph, project: Project, decoder: VideoFrameDecoder) async throws {
        var textures: [AppSourceTextureKey: MTLTexture] = [:]
        var retainedFrames: [DecodedFrame] = []

        for node in graph.nodes {
            guard case .source(let source) = node.kind else {
                continue
            }

            let media = try Self.media(for: source.mediaID, in: project)
            let frame = try await decoder.decodeFrame(from: media, at: source.sourceTime)
            guard let texture = CVMetalTextureGetTexture(frame.metalTexture) else {
                throw EditorAjarRenderError.decodedTextureUnavailable(source.mediaID)
            }
            textures[AppSourceTextureKey(source)] = texture
            retainedFrames.append(frame)
        }

        self.textures = textures
        self.retainedFrames = retainedFrames
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = textures[AppSourceTextureKey(source)] else {
            throw EditorAjarRenderError.decodedTextureUnavailable(source.mediaID)
        }
        _ = retainedFrames.count
        return texture
    }

    private static func media(for mediaID: UUID, in project: Project) throws -> MediaRef {
        guard let media = project.mediaPool.first(where: { candidate in candidate.id == mediaID }) else {
            throw EditorAjarRenderError.missingMedia(mediaID)
        }
        return media
    }
}

enum EditorAjarRenderError: Error, CustomStringConvertible {
    case missingMedia(UUID)
    case decodedTextureUnavailable(UUID)

    var description: String {
        switch self {
        case .missingMedia(let mediaID):
            "missing media \(mediaID)"
        case .decodedTextureUnavailable(let mediaID):
            "decoded media \(mediaID) did not expose a Metal texture"
        }
    }
}
