// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import AjarRender
import CoreVideo
import Foundation
import Metal

struct RenderSourceKey: Hashable {
    let mediaID: UUID
    let clipID: UUID
    let sourceTime: RationalTime
    let reverse: Bool
    let freezeFrame: Bool

    init(_ source: RenderSourceNode) {
        mediaID = source.mediaID
        clipID = source.clipID
        sourceTime = source.sourceTime
        reverse = source.reverse
        freezeFrame = source.freezeFrame
    }
}

final class PredecodedSourceTextureProvider: RenderSourceTextureProvider {
    private let textures: [RenderSourceKey: MTLTexture]
    private let retainedFrames: [DecodedFrame]

    init(graph: RenderGraph, project: Project, device: MTLDevice) async throws {
        let decoder = try VideoFrameDecoder(device: device)
        var textures: [RenderSourceKey: MTLTexture] = [:]
        var retainedFrames: [DecodedFrame] = []

        for source in graph.renderSourceNodes() {
            let media = try Self.media(for: source.mediaID, in: project)
            let frame = try await decoder.decodeFrame(
                from: media,
                at: try Self.decodeTime(for: source, media: media)
            )
            guard let texture = CVMetalTextureGetTexture(frame.metalTexture) else {
                throw AjarCLIError.decodedTextureUnavailable(source.mediaID)
            }

            // This CLI path currently exercises opaque fixtures. Transparent-media import must
            // premultiply decoded colors before handing textures to `MetalRenderExecutor`.
            textures[RenderSourceKey(source)] = texture
            retainedFrames.append(frame)
        }

        self.textures = textures
        self.retainedFrames = retainedFrames
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = textures[RenderSourceKey(source)] else {
            throw AjarCLIError.decodedTextureUnavailable(source.mediaID)
        }
        _ = retainedFrames.count
        return texture
    }

    private static func media(for mediaID: UUID, in project: Project) throws -> MediaRef {
        guard let media = project.mediaPool.first(where: { candidate in
            candidate.id == mediaID
        }) else {
            throw AjarCLIError.missingMediaReference(mediaID)
        }
        return media
    }

    private static func decodeTime(
        for source: RenderSourceNode,
        media: MediaRef
    ) throws -> RationalTime {
        guard
            source.reverse,
            !source.freezeFrame,
            let sourceRange = source.sourceRange
        else {
            return source.sourceTime
        }

        let sourceEnd = try sourceRange.end()
        let sourceOffsetFromEnd = try sourceEnd.subtracting(source.sourceTime)
        guard let frameRate = media.metadata.conformedFrameRate ?? media.metadata.frameRate else {
            return source.sourceTime
        }
        let frameDuration = try frameRate.duration(ofFrames: 1)
        let lastFrameTime = max(sourceRange.start, try sourceEnd.subtracting(frameDuration))
        return max(sourceRange.start, try lastFrameTime.subtracting(sourceOffsetFromEnd))
    }
}

private extension RenderGraph {
    func renderSourceNodes() -> [RenderSourceNode] {
        var sources: [RenderSourceNode] = []
        appendRenderSourceNodes(to: &sources)
        return sources
    }

    func appendRenderSourceNodes(to sources: inout [RenderSourceNode]) {
        for node in nodes {
            switch node.kind {
            case .source(let source):
                sources.append(source)
            case .compound(let compound):
                compound.graph.appendRenderSourceNodes(to: &sources)
            case .composite:
                continue
            }
        }
    }
}
