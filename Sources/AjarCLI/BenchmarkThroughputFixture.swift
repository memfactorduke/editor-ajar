// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarExport
import Foundation

/// Real-time-ratio throughput benchmarks that drive the production export / proxy pipelines
/// end to end and report ×-real-time (media seconds ÷ wall seconds).
///
/// These are **report-only** and carry no `BenchmarkBudget`: absolute throughput is bound to the
/// host's hardware encoder, so they are compared to the SPEC §5 targets (NFR-PERF-008 ≥ 3×,
/// NFR-PERF-011 ≥ 5×) on the reference machine rather than gated on hosted runners. The H.264
/// case capability-skips cleanly where no hardware encoder is available (the same discipline as
/// the FR-EXP-007 export-golden encode smokes); ProRes-Proxy encodes everywhere and never skips.
enum BenchmarkThroughputFixture {
    /// Frames for the synthetic 1080p30 timeline. ~90 frames = 3 s of media keeps each run short
    /// while giving a stable wall-clock over a real multi-frame render+encode.
    private static let frameCount: Int64 = 90

    /// Measures H.264 1080p30 export throughput through the real ``ExportSession`` (NFR-PERF-008).
    ///
    /// Returns a skipped row (sentinel value 0) when the hardware encoder is unavailable.
    static func measureExportThroughput1080p30H264() async throws -> BenchmarkResult {
        let metric = BenchmarkMetric.exportThroughput1080p30H264
        let fixture = try ExportGoldenFixture(
            frameCount: frameCount,
            width: 1_920,
            height: 1_080,
            frameRate: try FrameRate(frames: 30),
            colorSpace: .rec709
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let settings = try fixture.movieSettings(container: .mp4, codec: .h264)
        let destination = fixture.directoryURL
            .appendingPathComponent("export-throughput-1080p30.mp4")

        let media = mediaSeconds(
            frameCount: frameCount,
            frameRate: fixture.sequence.timebase
        )
        do {
            let wall = try await wallClockSeconds {
                _ = try await fixture.exportMovie(to: destination, settings: settings)
            }
            return throughputResult(metric: metric, mediaSeconds: media, wallSeconds: wall)
        } catch let error as ExportError where error.isHardwareEncoderUnavailable(for: .h264) {
            return skippedResult(metric: metric)
        }
    }

    /// Measures ProRes-Proxy 1080p generation throughput via ``ProxyGenerationSession`` on a
    /// synthetic solid-color 1080p source (NFR-PERF-011). ProRes encodes on CI, so this never
    /// capability-skips; real encoder failures propagate.
    static func measureProxyGenerationThroughput1080p() async throws -> BenchmarkResult {
        let metric = BenchmarkMetric.proxyGenerationThroughput1080p
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ajar-proxy-throughput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let frameRate = try FrameRate(frames: 30)
        let request = ProxyGenerationRequest(
            mediaID: UUID(),
            sourceURL: URL(fileURLWithPath: "/unused/original.mov"),
            destinationURL: directory.appendingPathComponent("proxy-throughput-1080p.mov"),
            relativePath: "caches/proxies/throughput.mov",
            resolution: PixelDimensions(width: 1_920, height: 1_080),
            frameCount: frameCount,
            frameRate: frameRate
        )

        let media = mediaSeconds(frameCount: frameCount, frameRate: frameRate)
        let wall = try await wallClockSeconds {
            let session = ProxyGenerationSession(
                request: request,
                frameProvider: SolidColorProxySourceFrameProvider()
            )
            _ = try await session.run()
        }
        return throughputResult(metric: metric, mediaSeconds: media, wallSeconds: wall)
    }

    // MARK: - Helpers

    private static func mediaSeconds(frameCount: Int64, frameRate: FrameRate) -> Double {
        // frameRate = `frames` per `seconds`; media duration = frameCount / (frames/seconds).
        Double(frameCount) * Double(frameRate.seconds) / Double(frameRate.frames)
    }

    private static func wallClockSeconds(
        _ operation: () async throws -> Void
    ) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000_000.0
    }

    private static func throughputResult(
        metric: BenchmarkMetric,
        mediaSeconds: Double,
        wallSeconds: Double
    ) -> BenchmarkResult {
        // Report-only ratio; unbudgeted (see file doc). Round to milli-x for a stable report.
        let ratio = wallSeconds > 0 ? mediaSeconds / wallSeconds : 0
        return BenchmarkResult(
            metric: metric.rawValue,
            value: (ratio * 1_000).rounded() / 1_000,
            unit: metric.unit,
            requirementID: metric.requirementID
        )
    }

    private static func skippedResult(metric: BenchmarkMetric) -> BenchmarkResult {
        BenchmarkResult(
            metric: metric.rawValue,
            value: 0,
            unit: metric.unit,
            requirementID: metric.requirementID,
            skipped: true
        )
    }
}
