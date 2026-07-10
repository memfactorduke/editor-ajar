// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Frames + rolling time estimate published by the FR-EXP-005 queue.
public struct ExportProgressEstimate: Equatable, Sendable {
    /// Sequential video frames successfully appended so far in the **current** session run.
    public let framesWritten: Int64

    /// Total video frames planned for the current session run.
    public let totalFrames: Int64

    /// Fraction in `0...1`, **monotonic non-decreasing within a single run**.
    ///
    /// On pause/resume the queue starts a new session and resets progress to zero (full restart).
    public let fractionCompleted: Double

    /// Window-averaged encode rate, when enough samples exist.
    public let averageFramesPerSecond: Double?

    /// Estimated wall-clock seconds remaining from the rolling FPS window, when known.
    public let estimatedSecondsRemaining: TimeInterval?

    /// Creates a progress estimate.
    public init(
        framesWritten: Int64,
        totalFrames: Int64,
        fractionCompleted: Double,
        averageFramesPerSecond: Double? = nil,
        estimatedSecondsRemaining: TimeInterval? = nil
    ) {
        self.framesWritten = framesWritten
        self.totalFrames = totalFrames
        self.fractionCompleted = fractionCompleted
        self.averageFramesPerSecond = averageFramesPerSecond
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }

    /// Zero progress for a newly enqueued or restarted job.
    public static let zero = ExportProgressEstimate(
        framesWritten: 0,
        totalFrames: 0,
        fractionCompleted: 0,
        averageFramesPerSecond: nil,
        estimatedSecondsRemaining: nil
    )
}

/// Rolling-window FPS estimator with a monotonic progress floor (FR-EXP-005).
public struct ExportProgressEstimator: Sendable {
    private struct Sample: Sendable {
        let time: ContinuousClock.Instant
        let framesWritten: Int64
    }

    private let windowDuration: Duration
    private var samples: [Sample] = []
    private var peakFraction: Double = 0

    /// Creates an estimator with a rolling window (default 2 seconds of samples).
    public init(windowSeconds: Double = 2.0) {
        let clamped = max(0.25, windowSeconds)
        windowDuration = .seconds(clamped)
    }

    /// Resets counters when a new session run starts (including after pause/resume restart).
    public mutating func reset() {
        samples = []
        peakFraction = 0
    }

    /// Incorporates a session progress sample and returns a monotonic estimate.
    public mutating func update(
        progress: ExportProgress,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> ExportProgressEstimate {
        let rawFraction: Double
        if progress.totalFrames > 0 {
            rawFraction = min(
                1,
                max(0, Double(progress.framesWritten) / Double(progress.totalFrames))
            )
        } else {
            rawFraction = 0
        }
        peakFraction = max(peakFraction, rawFraction)

        samples.append(Sample(time: now, framesWritten: progress.framesWritten))
        samples.removeAll { now - $0.time > windowDuration }

        let rate = averageFramesPerSecond(at: now)
        let remainingFrames = max(Int64(0), progress.totalFrames - progress.framesWritten)
        let eta: TimeInterval?
        if let rate, rate > 0, remainingFrames > 0 {
            eta = Double(remainingFrames) / rate
        } else if progress.totalFrames > 0, progress.framesWritten >= progress.totalFrames {
            eta = 0
        } else {
            eta = nil
        }

        return ExportProgressEstimate(
            framesWritten: progress.framesWritten,
            totalFrames: progress.totalFrames,
            fractionCompleted: peakFraction,
            averageFramesPerSecond: rate,
            estimatedSecondsRemaining: eta
        )
    }

    private func averageFramesPerSecond(at now: ContinuousClock.Instant) -> Double? {
        guard let first = samples.first, let last = samples.last else {
            return nil
        }
        let frameDelta = last.framesWritten - first.framesWritten
        guard frameDelta > 0 else {
            return nil
        }
        let elapsed = now - first.time
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else {
            return nil
        }
        return Double(frameDelta) / seconds
    }
}
