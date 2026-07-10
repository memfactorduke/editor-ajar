// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import simd

extension MetalRenderExecutor {
    struct TransitionSourceRequest {
        let graph: RenderGraph
        let transitionNode: RenderNode
        let transition: RenderTransitionNode
        let input: RenderCompositeInput
        let sourceProvider: any RenderSourceTextureProvider
        let commandBuffer: MTLCommandBuffer
    }

    /// Resolves a transition composite input: two sources → linear working textures →
    /// transition fragment → single linear working result for the track composite.
    func transitionSourceInput(_ request: TransitionSourceRequest) throws -> SourceCompositeInput {
        let transitionNode = request.transitionNode
        let transition = request.transition
        let graph = request.graph
        guard transitionNode.inputIDs.count == 2 else {
            throw MetalRenderError.unsupportedInputNode(transitionNode.id)
        }
        guard
            let outgoingNode = graph.node(withID: transitionNode.inputIDs[0]),
            let incomingNode = graph.node(withID: transitionNode.inputIDs[1]),
            case .source(let outgoingSource) = outgoingNode.kind,
            case .source(let incomingSource) = incomingNode.kind
        else {
            throw MetalRenderError.unsupportedInputNode(transitionNode.id)
        }

        let outgoingTexture = try decodeTransitionSide(
            source: outgoingSource,
            effectStack: transition.outgoingEffectStack ?? .empty,
            sourceProvider: request.sourceProvider,
            commandBuffer: request.commandBuffer
        )
        let incomingTexture = try decodeTransitionSide(
            source: incomingSource,
            effectStack: transition.incomingEffectStack ?? .empty,
            sourceProvider: request.sourceProvider,
            commandBuffer: request.commandBuffer
        )

        let result = try encodeVideoTransition(
            transition: transition,
            outgoing: outgoingTexture.texture,
            incoming: incomingTexture.texture,
            commandBuffer: request.commandBuffer
        )

        let synthetic = RenderSourceNode(
            mediaID: transition.outgoingClipID,
            clipID: transition.outgoingClipID,
            sourceTime: .zero,
            colorSpace: outgoingSource.colorSpace
        )
        return SourceCompositeInput(
            source: synthetic,
            texture: result,
            transform: .identity,
            effects: .none,
            effectStack: .empty,
            trackOpacity: request.input.trackOpacity,
            trackBlendMode: request.input.trackBlendMode,
            sourceColorSpace: outgoingSource.colorSpace,
            sourceIsLinearWorking: true,
            retainedFrame: nil,
            blendTexture: nil,
            effectTextures: outgoingTexture.intermediates + incomingTexture.intermediates
                + [result]
        )
    }

    private struct TransitionSideTexture {
        let texture: MTLTexture
        let intermediates: [MTLTexture]
    }

    private func decodeTransitionSide(
        source: RenderSourceNode,
        effectStack: ClipEffectStack,
        sourceProvider: any RenderSourceTextureProvider,
        commandBuffer: MTLCommandBuffer
    ) throws -> TransitionSideTexture {
        let sourceTexture: MTLTexture
        do {
            sourceTexture = try sourceProvider.texture(for: source)
        } catch {
            throw MetalRenderError.sourceTextureUnavailable(
                RenderNodeID(rawValue: "source:\(source.clipID.uuidString)"),
                String(describing: error)
            )
        }

        let linearTexture = try encodeSourceToLinearWorking(
            sourceTexture,
            source: source,
            commandBuffer: commandBuffer
        )
        if effectStack.nodes.contains(where: \.enabled) {
            let effected = try applyEffectStack(
                effectStack,
                to: linearTexture,
                commandBuffer: commandBuffer
            )
            return TransitionSideTexture(
                texture: effected.texture,
                intermediates: [linearTexture] + effected.intermediates
            )
        }
        return TransitionSideTexture(texture: linearTexture, intermediates: [linearTexture])
    }

    private func encodeVideoTransition(
        transition: RenderTransitionNode,
        outgoing: MTLTexture,
        incoming: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let width = max(outgoing.width, incoming.width)
        let height = max(outgoing.height, incoming.height)
        let result = try makeReusableTexture(
            pixelFormat: Self.linearWorkingPixelFormat,
            width: width,
            height: height
        )
        let pipeline = try pipelineState(
            fragmentFunctionName: "ajar_video_transition_fragment",
            pixelFormat: result.pixelFormat
        )
        let descriptor = renderPassDescriptor(for: result)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw MetalRenderError.commandBufferCreationFailed
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(outgoing, index: 0)
        encoder.setFragmentTexture(incoming, index: 1)

        let progress =
            Float(transition.progress.numerator)
            / Float(max(transition.progress.denominator, 1))
        let bytes = MetalEffectUniformLayout.packVideoTransition(
            progress: progress,
            kindCode: Float(kindCode(transition.kind)),
            directionCode: Float(directionCode(transition.direction)),
            dipColor: SIMD4<Float>(
                Float(transition.color.red.numerator)
                    / Float(max(transition.color.red.denominator, 1)),
                Float(transition.color.green.numerator)
                    / Float(max(transition.color.green.denominator, 1)),
                Float(transition.color.blue.numerator)
                    / Float(max(transition.color.blue.denominator, 1)),
                1
            )
        )
        encoder.setFragmentBytes(bytes, length: bytes.count, index: 0)
        // `ajar_fullscreen_vertex` indexes a 6-vertex two-triangle quad (same as
        // `MetalClipEffectStackPasses.encodeFullscreen`). vertexCount: 3 draws only the
        // first triangle and leaves the upper-right diagonal undrawn (dontCare/clear).
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        return result
    }

    private func kindCode(_ kind: ClipVideoTransitionKind) -> Int {
        switch kind {
        case .crossDissolve: 0
        case .dipToColor: 1
        case .fade: 2
        case .push: 3
        case .slide: 4
        case .wipe: 5
        case .zoom: 6
        }
    }

    private func directionCode(_ direction: ClipVideoTransitionDirection) -> Int {
        switch direction {
        case .left: 0
        case .right: 1
        case .top: 2
        case .bottom: 3
        case .topLeft: 4
        case .topRight: 5
        case .bottomLeft: 6
        case .bottomRight: 7
        }
    }
}
