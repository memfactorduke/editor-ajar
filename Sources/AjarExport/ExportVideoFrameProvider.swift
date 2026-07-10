// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import CoreVideo

/// Renders one exact timeline time into a writer-owned pixel buffer.
public protocol ExportVideoFrameProvider: AnyObject {
    /// Produces a delivery-encoded frame for `timelineTime`.
    func renderFrame(
        at timelineTime: RationalTime,
        into pixelBuffer: CVPixelBuffer
    ) async throws
}

/// Prepares original-media textures required by one immutable render graph.
///
/// A caller-owned adapter may use AjarMedia to decode originals. Keeping the adapter injected
/// prevents the export orchestrator from owning import/proxy policy and keeps AjarMedia below it.
public protocol ExportRenderSourceProvider: RenderSourceTextureProvider {
    /// Makes every source texture referenced by `graph` available synchronously to the executor.
    func prepare(graph: RenderGraph) async throws
}
