// SPDX-License-Identifier: GPL-3.0-or-later

import AjarRender
import Foundation
import Metal
import XCTest

@testable import EditorAjar

final class EditorAjarRenderPipelineCacheTests: XCTestCase {
    func testFRPLAY005FreshRenderWritesBehindAndReloadsAfterRAMEviction() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable")
        }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-disk-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let pipeline = try EditorAjarRenderPipeline(cacheDirectoryURL: cacheDirectory)
        let project = try EditorAjarSampleProjectFactory.makeSampleProject()
        let sequence = try XCTUnwrap(project.sequences.first)
        let output = RenderOutputDescriptor(pixelDimensions: project.settings.resolution)

        let first = try await pipeline.renderFrame(
            project: project,
            sequence: sequence,
            frame: 0
        )
        await pipeline.waitForDiskWriteBehindForTesting()
        pipeline.removeAllCachedFramesForTesting()
        pipeline.prefetchCachedFrameForTesting(contentHash: first.contentHash, output: output)

        for _ in 0..<100 where pipeline.diskPopulatedFrameCountForTesting == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(pipeline.diskPopulatedFrameCountForTesting, 1)

        let reloaded = try await pipeline.renderFrame(
            project: project,
            sequence: sequence,
            frame: 0,
            allowDiskWriteBehind: false
        )
        XCTAssertEqual(reloaded.cacheDisposition, .ramHit)
    }
}
