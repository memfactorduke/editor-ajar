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

    init(_ source: RenderSourceNode) {
        mediaID = source.mediaID
        clipID = source.clipID
        sourceTime = source.sourceTime
    }
}

final class PredecodedSourceTextureProvider: RenderSourceTextureProvider {
    private let textures: [RenderSourceKey: MTLTexture]
    private let retainedFrames: [DecodedFrame]

    init(graph: RenderGraph, project: Project, device: MTLDevice) async throws {
        let decoder = try VideoFrameDecoder(device: device)
        var textures: [RenderSourceKey: MTLTexture] = [:]
        var retainedFrames: [DecodedFrame] = []

        for node in graph.nodes {
            guard case .source(let source) = node.kind else {
                continue
            }

            let media = try Self.media(for: source.mediaID, in: project)
            let frame = try await decoder.decodeFrame(from: media, at: source.sourceTime)
            guard let texture = CVMetalTextureGetTexture(frame.metalTexture) else {
                throw AjarCLIError.decodedTextureUnavailable(source.mediaID)
            }

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
}
