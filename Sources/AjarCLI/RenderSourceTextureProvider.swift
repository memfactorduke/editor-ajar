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
    private struct FrameBlendEntry {
        let earlierTexture: MTLTexture
        let laterTexture: MTLTexture
        let laterWeight: Float
    }

    private let textures: [RenderSourceKey: MTLTexture]
    private let blendEntries: [RenderSourceKey: FrameBlendEntry]
    private let retainedFrames: [DecodedFrame]

    init(graph: RenderGraph, project: Project, device: MTLDevice) async throws {
        let decoder = try VideoFrameDecoder(device: device)
        var textures: [RenderSourceKey: MTLTexture] = [:]
        var blendEntries: [RenderSourceKey: FrameBlendEntry] = [:]
        var retainedFrames: [DecodedFrame] = []

        func decodeTexture(from media: MediaRef, at time: RationalTime) async throws -> MTLTexture {
            let frame = try await decoder.decodeFrame(from: media, at: time)
            guard let texture = CVMetalTextureGetTexture(frame.metalTexture) else {
                throw AjarCLIError.decodedTextureUnavailable(media.id)
            }
            retainedFrames.append(frame)
            return texture
        }

        for source in graph.renderSourceNodes() {
            let media = try Self.media(for: source.mediaID, in: project)
            let decodeTime = try Self.decodeTime(for: source, media: media)
            let key = RenderSourceKey(source)

            // This CLI path currently exercises opaque fixtures. Transparent-media import must
            // premultiply decoded colors before handing textures to `MetalRenderExecutor`.
            if let pair = try Self.frameBlendPair(for: source, media: media, at: decodeTime) {
                // FR-SPD-004: decode both adjacent frames at their exact frame start times.
                let earlierTexture = try await decodeTexture(
                    from: media,
                    at: pair.earlierFrameTime
                )
                blendEntries[key] = FrameBlendEntry(
                    earlierTexture: earlierTexture,
                    laterTexture: try await decodeTexture(from: media, at: pair.laterFrameTime),
                    laterWeight: Float(pair.laterWeight.numerator)
                        / Float(pair.laterWeight.denominator)
                )
                // Keep the earlier frame available for the nearest fallback path.
                textures[key] = earlierTexture
            } else {
                textures[key] = try await decodeTexture(from: media, at: decodeTime)
            }
        }

        self.textures = textures
        self.blendEntries = blendEntries
        self.retainedFrames = retainedFrames
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = textures[RenderSourceKey(source)] else {
            throw AjarCLIError.decodedTextureUnavailable(source.mediaID)
        }
        _ = retainedFrames.count
        return texture
    }

    func frameBlendTextures(
        for source: RenderSourceNode
    ) throws -> RenderSourceFrameBlendTextures? {
        guard let entry = blendEntries[RenderSourceKey(source)] else {
            return nil
        }
        return RenderSourceFrameBlendTextures(
            earlierTexture: entry.earlierTexture,
            laterTexture: entry.laterTexture,
            laterWeight: entry.laterWeight
        )
    }

    private static func media(for mediaID: UUID, in project: Project) throws -> MediaRef {
        guard let media = project.mediaPool.first(where: { candidate in
            candidate.id == mediaID
        }) else {
            throw AjarCLIError.missingMediaReference(mediaID)
        }
        return media
    }

    /// Resolves the FR-SPD-004 adjacent frame pair for a frame-blend source node.
    ///
    /// The pair is computed on the resolved decode-time axis (after the discrete reverse
    /// shift), so the fraction is measured toward the later source frame regardless of playback
    /// direction. Returns `nil` for nearest-mode sources, freeze frames
    /// (`resolvedFrameSampling`), integer frame positions, unknown frame rates, and positions
    /// whose later frame would start at or past the decodable span.
    private static func frameBlendPair(
        for source: RenderSourceNode,
        media: MediaRef,
        at decodeTime: RationalTime
    ) throws -> FrameBlendPair? {
        guard source.resolvedFrameSampling == .frameBlend else {
            return nil
        }
        guard let frameRate = media.metadata.conformedFrameRate ?? media.metadata.frameRate else {
            return nil
        }

        var sourceEnd = media.metadata.duration
        if let sourceRange = source.sourceRange {
            sourceEnd = min(sourceEnd, try sourceRange.end())
        }
        return try FrameBlendSampling.blendPair(
            forSourceTime: decodeTime,
            frameRate: frameRate,
            sourceEnd: sourceEnd
        )
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
