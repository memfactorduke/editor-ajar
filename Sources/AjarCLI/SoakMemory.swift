// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Typed failures from the `ajar soak` leak/allocations harness (NFR-STAB-005).
enum SoakError: Error, Equatable, CustomStringConvertible {
    /// The run finished with too few post-warmup samples to evaluate a memory trend.
    case insufficientSamples(count: Int, required: Int)

    /// A post-warmup sample exceeded the steady-state growth band above the baseline.
    case memoryGrowthExceededBand(report: SoakMemoryReport)

    /// Post-warmup memory grew monotonically across the run beyond the noise tolerance.
    case monotonicGrowthDetected(report: SoakMemoryReport)

    /// The kernel rejected the mach task-info memory sample.
    case memorySamplingFailed(kernelReturn: Int32)

    /// A human-readable failure description including the growth curve.
    var description: String {
        switch self {
        case .insufficientSamples(let count, let required):
            return "soak needs at least \(required) post-warmup samples, got \(count); "
                + "raise --iterations or --duration-seconds"
        case .memoryGrowthExceededBand(let report):
            return "soak memory left the steady-state growth band "
                + "(+\(SoakMemoryReport.megabytes(report.policy.growthBandBytes)) MiB over "
                + "baseline)\n\(report)"
        case .monotonicGrowthDetected(let report):
            return "soak memory grew monotonically across the run "
                + "(quartile means strictly increasing beyond "
                + "\(SoakMemoryReport.megabytes(report.policy.monotonicToleranceBytes)) MiB)"
                + "\n\(report)"
        case .memorySamplingFailed(let kernelReturn):
            return "task_info memory sampling failed (kern_return \(kernelReturn))"
        }
    }
}

/// One post-iteration memory sample taken via mach `task_info`.
struct SoakMemorySample: Equatable {
    /// Zero-based soak iteration index the sample was taken after.
    let iteration: Int

    /// `phys_footprint`: resident plus compressed plus IOKit-mapped bytes. This is the value
    /// the trend is gated on — unlike raw resident size it cannot shrink under memory pressure
    /// while a leak keeps growing in the compressor.
    let physicalFootprintBytes: UInt64

    /// Raw resident size, reported alongside the footprint for context.
    let residentBytes: UInt64
}

/// Growth thresholds for the post-warmup steady state.
///
/// Defaults and their justification (NFR-STAB-005): after warmup, the loop's caches are all
/// hard-capped (executor RAM tier, texture pool, byte-budgeted disk tier, per-render audio
/// caches), so steady state should be flat apart from malloc-arena and Metal/AVFoundation
/// driver-pool jitter, which stays in the single-digit-MiB range on the reference machine.
/// The 64 MiB band is roughly 10x that observed jitter yet far below what a real per-iteration
/// leak accumulates over a run; the 8 MiB monotonic tolerance keeps a flat-but-jittery run
/// from failing the strict quartile ordering by luck.
struct SoakGrowthPolicy: Equatable {
    /// Maximum allowed rise of any post-warmup sample above the baseline window median.
    let growthBandBytes: UInt64

    /// Minimum quartile-mean rise treated as monotonic growth rather than noise.
    let monotonicToleranceBytes: UInt64

    /// Default policy: 64 MiB band, 8 MiB monotonic tolerance.
    static let standard = SoakGrowthPolicy(
        growthBandBytes: 64 * 1_024 * 1_024,
        monotonicToleranceBytes: 8 * 1_024 * 1_024
    )
}

/// Evaluated post-warmup memory trend, printable as a growth curve.
struct SoakMemoryReport: Equatable, CustomStringConvertible {
    /// Policy the samples were evaluated against.
    let policy: SoakGrowthPolicy

    /// Post-warmup samples in iteration order.
    let samples: [SoakMemorySample]

    /// Median footprint of the leading baseline window.
    let baselineBytes: UInt64

    /// Highest footprint observed after the baseline window.
    let peakBytes: UInt64

    /// The growth curve, capped to at most 16 evenly-spaced points.
    var description: String {
        let curve = Self.curvePoints(samples).map { sample in
            "  iteration \(sample.iteration): "
                + "footprint \(Self.megabytes(sample.physicalFootprintBytes)) MiB, "
                + "resident \(Self.megabytes(sample.residentBytes)) MiB"
        }
        let header = "baseline \(Self.megabytes(baselineBytes)) MiB, "
            + "peak \(Self.megabytes(peakBytes)) MiB, "
            + "\(samples.count) post-warmup samples:"
        return ([header] + curve).joined(separator: "\n")
    }

    static func curvePoints(_ samples: [SoakMemorySample]) -> [SoakMemorySample] {
        guard samples.count > 16 else {
            return samples
        }
        let step = Double(samples.count - 1) / 15.0
        return (0..<16).map { index in
            samples[Int((Double(index) * step).rounded())]
        }
    }

    static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / (1_024.0 * 1_024.0))
    }
}

/// Pure post-warmup trend evaluation, unit-testable without running a soak.
enum SoakMemoryTrend {
    /// Post-warmup samples needed before a trend can be evaluated at all.
    static let minimumSampleCount = 2

    /// Post-warmup samples needed before the quartile monotonic check runs.
    static let monotonicMinimumSampleCount = 8

    /// Evaluates post-warmup `samples` against `policy`; throws a typed `SoakError` with the
    /// growth curve on failure and returns the passing report otherwise.
    ///
    /// Baseline: median footprint of the first `max(1, count / 4)` samples. Band check: every
    /// later sample must stay within `growthBandBytes` of that baseline. Monotonic check (only
    /// with 8+ samples): the four contiguous quartile means must not be strictly increasing
    /// with a total rise beyond `monotonicToleranceBytes`.
    static func evaluate(
        samples: [SoakMemorySample],
        policy: SoakGrowthPolicy
    ) throws -> SoakMemoryReport {
        guard samples.count >= minimumSampleCount else {
            throw SoakError.insufficientSamples(
                count: samples.count,
                required: minimumSampleCount
            )
        }

        let baselineWindow = max(1, samples.count / 4)
        let baseline = median(samples.prefix(baselineWindow).map(\.physicalFootprintBytes))
        let laterSamples = samples.dropFirst(baselineWindow)
        let peak = (laterSamples.isEmpty ? samples : Array(laterSamples))
            .map(\.physicalFootprintBytes)
            .max() ?? baseline
        let report = SoakMemoryReport(
            policy: policy,
            samples: samples,
            baselineBytes: baseline,
            peakBytes: peak
        )

        if peak > baseline, peak - baseline > policy.growthBandBytes {
            throw SoakError.memoryGrowthExceededBand(report: report)
        }
        if hasMonotonicGrowth(samples: samples, policy: policy) {
            throw SoakError.monotonicGrowthDetected(report: report)
        }
        return report
    }

    private static func hasMonotonicGrowth(
        samples: [SoakMemorySample],
        policy: SoakGrowthPolicy
    ) -> Bool {
        guard samples.count >= monotonicMinimumSampleCount else {
            return false
        }

        let quartileMeans = (0..<4).map { quartile -> Double in
            let start = samples.count * quartile / 4
            let end = samples.count * (quartile + 1) / 4
            let footprints = samples[start..<end].map { Double($0.physicalFootprintBytes) }
            return footprints.reduce(0, +) / Double(footprints.count)
        }
        let strictlyIncreasing = zip(quartileMeans, quartileMeans.dropFirst())
            .allSatisfy { $0 < $1 }
        guard strictlyIncreasing, let first = quartileMeans.first,
            let last = quartileMeans.last
        else {
            return false
        }
        return last - first > Double(policy.monotonicToleranceBytes)
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            return 0
        }
        return sorted[sorted.count / 2]
    }
}

/// Samples the current process's memory via mach `task_info` (`TASK_VM_INFO`).
///
/// This is deliberately platform code in `AjarCLI`, not `AjarCore` (ADR-0005).
enum SoakMemorySampler {
    /// Returns the current footprint/resident sample for `iteration`.
    static func sample(iteration: Int) throws -> SoakMemorySample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kernelReturn = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard kernelReturn == KERN_SUCCESS else {
            throw SoakError.memorySamplingFailed(kernelReturn: kernelReturn)
        }
        return SoakMemorySample(
            iteration: iteration,
            physicalFootprintBytes: info.phys_footprint,
            residentBytes: UInt64(info.resident_size)
        )
    }
}
