// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarRender
import Foundation
import Metal

extension BenchmarkCommand {
    /// Measures one FR-SPD-005 retimed-playback or FR-AUD-007 realtime plan-build metric.
    static func measureRetimeMetric(_ metric: BenchmarkMetric) async throws -> Double {
        if let retimeCase = Self.retimeCase(for: metric) {
            return try await measureRetimedPlayback(retimeCase: retimeCase)
        }
        if let fixture = try Self.audioPlanFixture(for: metric) {
            return try await measureRealtimeAudioPlanBuild(fixture: fixture)
        }
        throw AjarCLIError.benchmarkFailed("metric \(metric.rawValue) has no retime measurement")
    }

    private static func retimeCase(
        for metric: BenchmarkMetric
    ) -> BenchmarkRetimedPlaybackFixture.RetimeCase? {
        switch metric {
        case .retimedConstant2xPlayback:
            .constant2x
        case .retimedConstantHalfPlayback:
            .constantHalf
        case .retimedTimeRemapRampPlayback:
            .timeRemapRamp
        case .retimedReversePlayback:
            .reverse
        case .retimedFreezeFramePlayback:
            .freezeFrame
        case .retimedFrameBlendHalfPlayback:
            .frameBlendHalf
        case .retimedNestedCompoundPlayback:
            .nestedCompound
        default:
            nil
        }
    }

    private static func audioPlanFixture(
        for metric: BenchmarkMetric
    ) throws -> BenchmarkRealtimeAudioPlanFixture? {
        switch metric {
        case .realtimeAudioPlanBuildRetimed:
            try BenchmarkRealtimeAudioPlanFixture.retimedTimeline()
        case .realtimeAudioPlanBuildNestedCompound:
            try BenchmarkRealtimeAudioPlanFixture.nestedCompoundTimeline()
        case .realtimeAudioPlanBuildWideTimeline:
            try BenchmarkRealtimeAudioPlanFixture.wideTimeline()
        default:
            nil
        }
    }

    /// One cold retimed frame per iteration: graph build, source decode, GPU composite, and
    /// completion wait, mirroring the other playback metrics (FR-SPD-005).
    private static func measureRetimedPlayback(
        retimeCase: BenchmarkRetimedPlaybackFixture.RetimeCase
    ) async throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.metalDeviceUnavailable
        }

        let fixture = try BenchmarkRetimedPlaybackFixture(retimeCase: retimeCase)
        defer {
            fixture.removeGeneratedFiles()
        }

        let executor = try MetalRenderExecutor(device: device)
        return try await medianMilliseconds {
            executor.removeAllCachedFrames()
            let graph = try buildRenderGraph(
                for: fixture.sequence,
                at: fixture.renderTime,
                in: fixture.project
            )
            let sourceProvider = try await PredecodedSourceTextureProvider(
                graph: graph,
                project: fixture.project,
                device: device
            )
            let frame = try executor.render(
                graph: graph,
                output: RenderOutputDescriptor(
                    pixelDimensions: fixture.project.settings.resolution
                ),
                sourceProvider: sourceProvider
            )
            try await frame.waitForCompletion()
        }
    }

    /// One full look-ahead plan build per iteration: the same off-realtime-thread flatten the
    /// live coordinator runs when its published window needs a refill (FR-AUD-007).
    private static func measureRealtimeAudioPlanBuild(
        fixture: BenchmarkRealtimeAudioPlanFixture
    ) async throws -> Double {
        try await medianMilliseconds {
            _ = try RealtimeAudioRenderPlan.preparingCompoundMix(
                project: fixture.project,
                sequence: fixture.sequence,
                range: fixture.range,
                sourceProvider: fixture.sourceProvider
            )
        }
    }
}
