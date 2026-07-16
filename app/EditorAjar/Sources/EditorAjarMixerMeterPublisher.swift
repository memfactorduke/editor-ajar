// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

typealias EditorAjarMixerMeterMeasurement = @Sendable (
    Project,
    Sequence,
    Int64,
    any AudioSourceProvider,
    Double,
    EditorAjarMixerMeterAnalysisCancellation
) throws -> MixerMeterSnapshot

private struct EditorAjarMixerMeterRequest: Sendable {
    let project: Project
    let sequence: Sequence
    let playheadFrame: Int64
    let range: TimeRange
    let sourceProviderFactory: EditorAjarAudioSourceProviderFactory
    let gain: Double
    let generation: Int
    let cancellation: EditorAjarMixerMeterAnalysisCancellation
}

/// Publishes FR-AUD-003 mixer meter levels using **offline** analysis only.
///
/// Measurement runs on a dedicated utility queue via `AudioMixerMeterAnalyzer` and (for master
/// true-peak) `AudioMixerMeterAnalyzer.measureProgramLoudness`. The real-time audio callback is
/// never entered from this type (ADR-0012 / FR-AUD-007).
@MainActor
final class EditorAjarMixerMeterPublisher {
    /// Queue label — asserted by tests so the publish path cannot silently move onto the RT path.
    static let analysisQueueLabel = "org.editorajar.mixer-meter.analysis"

    private let analysisQueue: DispatchQueue
    private let analysisScheduler: EditorAjarMixerMeterAnalysisScheduler
    private let measureSnapshotOperation: EditorAjarMixerMeterMeasurement
    private let publish: @MainActor (MixerMeterSnapshot) -> Void
    private let publishError: @MainActor (EditorAjarAudioPipelineError?) -> Void
    private var preparationTask: Task<Void, Never>?
    private var analysisCancellation: EditorAjarMixerMeterAnalysisCancellation?
    /// Monotonic request/cancel generation. Stale async results are dropped when it advances.
    /// Test seam for live-meter refresh while playing.
    private(set) var generation = 0

    /// Creates a publisher that always delivers snapshots on the main actor.
    convenience init(publish: @escaping @MainActor (MixerMeterSnapshot) -> Void) {
        self.init(
            publish: publish,
            publishError: { _ in },
            measureSnapshot: Self.productionMeasurement
        )
    }

    convenience init(
        publish: @escaping @MainActor (MixerMeterSnapshot) -> Void,
        publishError: @escaping @MainActor (EditorAjarAudioPipelineError?) -> Void
    ) {
        self.init(
            publish: publish,
            publishError: publishError,
            measureSnapshot: Self.productionMeasurement
        )
    }

    /// Measurement injection is an app-test seam for deterministic cancellation/backlog tests.
    init(
        publish: @escaping @MainActor (MixerMeterSnapshot) -> Void,
        publishError: @escaping @MainActor (EditorAjarAudioPipelineError?) -> Void,
        measureSnapshot: @escaping EditorAjarMixerMeterMeasurement
    ) {
        let queue = DispatchQueue(label: Self.analysisQueueLabel, qos: .utility)
        analysisQueue = queue
        analysisScheduler = EditorAjarMixerMeterAnalysisScheduler(queue: queue)
        measureSnapshotOperation = measureSnapshot
        self.publish = publish
        self.publishError = publishError
    }

    private static let productionMeasurement: EditorAjarMixerMeterMeasurement = { project,
        sequence, playheadFrame, provider, gain, cancellation in
        try measureSnapshotThrowing(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            sourceProvider: provider,
            masterGainLinear: gain,
            cancellationCheck: { try cancellation.check() }
        )
    }

    /// Test seam: expose the analysis queue label without touching audio hardware.
    var analysisQueueLabelForTesting: String {
        analysisQueue.label
    }

    /// Whether work is scheduled on the off-RT analysis queue (not the audio render callback).
    var publishesOnOffRealtimePath: Bool {
        analysisQueue.label == Self.analysisQueueLabel
    }

    /// Highest number of analysis jobs retained at once; bounded to active + latest pending.
    var maximumRetainedAnalysisCountForTesting: Int {
        analysisScheduler.maximumRetainedJobCount
    }

    /// Schedules offline metering for a short window around the playhead.
    ///
    /// `masterGainLinear` is applied to the summed mix before peak / true-peak extraction so the
    /// master clip indicator tracks the monitoring master fader (FR-AUD-003).
    func requestMeter(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        sourceProvider: any AudioSourceProvider,
        masterGainLinear: Double
    ) {
        requestMeter(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            sourceProviderFactory: { _, _, _ in sourceProvider },
            masterGainLinear: masterGainLinear
        )
    }

    /// Asynchronously prepares platform media sources, then performs deterministic analysis on
    /// the dedicated non-real-time queue. New requests cancel/coalesce stale preparation.
    func requestMeter(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        sourceProviderFactory: @escaping EditorAjarAudioSourceProviderFactory,
        masterGainLinear: Double
    ) {
        generation += 1
        let token = generation
        let gain = masterGainLinear
        preparationTask?.cancel()
        analysisCancellation?.cancel()
        let cancellation = EditorAjarMixerMeterAnalysisCancellation()
        analysisCancellation = cancellation
        let range: TimeRange
        do {
            range = try Self.meterRange(
                sequence: sequence,
                playheadFrame: playheadFrame,
                windowFrames: 4
            )
        } catch {
            cancellation.cancel()
            analysisCancellation = nil
            publishFailure(.renderFailed(String(describing: error)), token: token)
            return
        }
        let request = EditorAjarMixerMeterRequest(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            range: range,
            sourceProviderFactory: sourceProviderFactory,
            gain: gain,
            generation: token,
            cancellation: cancellation
        )
        preparationTask = Task { [weak self] in
            await self?.prepareAndSchedule(request)
        }
    }

    private func prepareAndSchedule(_ request: EditorAjarMixerMeterRequest) async {
        let provider: any AudioSourceProvider
        do {
            provider = try await request.sourceProviderFactory(
                request.project,
                request.sequence,
                request.range
            )
            try Task.checkCancellation()
            try request.cancellation.check()
        } catch is CancellationError {
            return
        } catch {
            publishFailure(
                .sourcePreparationFailed(String(describing: error)),
                token: request.generation
            )
            return
        }

        let measurement = measureSnapshotOperation
        analysisScheduler.submit(
            cancellation: request.cancellation,
            operation: {
                try measurement(
                    request.project,
                    request.sequence,
                    request.playheadFrame,
                    provider,
                    request.gain,
                    request.cancellation
                )
            },
            completion: { [weak self] outcome in
                Task { @MainActor [weak self] in
                    self?.completeAnalysis(
                        outcome,
                        token: request.generation,
                        cancellation: request.cancellation
                    )
                }
            }
        )
    }

    private func completeAnalysis(
        _ outcome: EditorAjarMixerMeterAnalysisOutcome,
        token: Int,
        cancellation: EditorAjarMixerMeterAnalysisCancellation
    ) {
        guard generation == token,
              analysisCancellation === cancellation,
              !cancellation.isCancelled
        else {
            return
        }
        analysisCancellation = nil
        switch outcome {
        case .success(let snapshot):
            publish(snapshot)
            publishError(nil)
        case .failure(let reason):
            publishFailure(.renderFailed(reason), token: token)
        }
    }

    private func publishFailure(_ error: EditorAjarAudioPipelineError, token: Int) {
        guard generation == token else {
            return
        }
        publish(.empty)
        publishError(error)
    }

    /// Clears pending generations so a closed project does not publish stale meters.
    func cancel() {
        generation += 1
        preparationTask?.cancel()
        preparationTask = nil
        analysisCancellation?.cancel()
        analysisCancellation = nil
        analysisScheduler.cancelAll()
        publish(.empty)
        publishError(nil)
    }

    /// Pure offline measure used by both production and unit tests.
    nonisolated static func measureSnapshot(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        sourceProvider: any AudioSourceProvider,
        windowFrames: Int64 = 4,
        masterGainLinear: Double = 1.0
    ) -> MixerMeterSnapshot {
        (try? measureSnapshotThrowing(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            sourceProvider: sourceProvider,
            windowFrames: windowFrames,
            masterGainLinear: masterGainLinear
        )) ?? .empty
    }

    nonisolated static func measureSnapshotThrowing(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        sourceProvider: any AudioSourceProvider,
        windowFrames: Int64 = 4,
        masterGainLinear: Double = 1.0,
        cancellationCheck: @escaping AudioRenderCancellationCheck = {}
    ) throws -> MixerMeterSnapshot {
        try cancellationCheck()
        let range = try meterRange(
            sequence: sequence,
            playheadFrame: playheadFrame,
            windowFrames: windowFrames
        )
        let report = try AudioMixerMeterAnalyzer.measure(
            project: project,
            sequence: sequence,
            range: range,
            sourceProvider: sourceProvider,
            channelCount: 2,
            cancellationCheck: cancellationCheck
        )
        var trackMap: [UUID: [AudioMeterChannelLevel]] = [:]
        for reading in report.trackLevels {
            trackMap[reading.trackID] = reading.levels
        }

        let format = AudioRenderFormat(
            sampleRate: project.settings.audioSampleRate,
            channelCount: 2
        )
        var continuation = OfflineAudioRenderContinuation()
        let buffer = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: range,
            format: format,
            sourceProvider: sourceProvider,
            continuation: &continuation,
            cancellationCheck: cancellationCheck
        )
        // Master fader is monitoring-only and post-mix — scale before master peak/true-peak.
        let meteredBuffer = try applyingMasterGain(
            masterGainLinear,
            to: buffer,
            cancellationCheck: cancellationCheck
        )
        let mixLevels = try AudioMixerMeterAnalyzer.measure(
            buffer: meteredBuffer,
            cancellationCheck: cancellationCheck
        )
        let truePeak: Double?
        if meteredBuffer.frameCount > 0 {
            truePeak = try AudioMixerMeterAnalyzer.measureProgramLoudness(
                buffer: meteredBuffer,
                cancellationCheck: cancellationCheck
            ).truePeak
        } else {
            try cancellationCheck()
            truePeak = nil
        }

        return MixerMeterSnapshot(
            trackLevels: trackMap,
            mixLevels: mixLevels,
            masterTruePeak: truePeak
        )
    }

    nonisolated private static func meterRange(
        sequence: Sequence,
        playheadFrame: Int64,
        windowFrames: Int64
    ) throws -> TimeRange {
        try TimeRange(
            start: RationalTime.atFrame(max(0, playheadFrame), frameRate: sequence.timebase),
            duration: sequence.timebase.duration(ofFrames: max(1, windowFrames))
        )
    }

    /// Mirrors `EditorAjarLiveAudioCoordinator.applyingMasterGain` for offline metering.
    nonisolated private static func applyingMasterGain(
        _ linear: Double,
        to buffer: RenderedAudioBuffer,
        cancellationCheck: @escaping AudioRenderCancellationCheck
    ) throws -> RenderedAudioBuffer {
        try cancellationCheck()
        guard linear != 1.0, linear.isFinite else {
            return buffer
        }
        let gain = Float(linear)
        var samples: [Float] = []
        samples.reserveCapacity(buffer.samples.count)
        for (index, sample) in buffer.samples.enumerated() {
            if index & 1_023 == 0 {
                try cancellationCheck()
            }
            samples.append(sample * gain)
        }
        try cancellationCheck()
        return try RenderedAudioBuffer(
            format: buffer.format,
            frameCount: buffer.frameCount,
            samples: samples
        )
    }
}

enum EditorAjarMixerMeterAnalysisOutcome: Sendable {
    case success(MixerMeterSnapshot)
    case failure(String)
}

final class EditorAjarMixerMeterAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    func check() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

/// Serial latest-only scheduler: one active job and at most one replacement are retained.
final class EditorAjarMixerMeterAnalysisScheduler: @unchecked Sendable {
    typealias Operation = @Sendable () throws -> MixerMeterSnapshot
    typealias Completion = @Sendable (EditorAjarMixerMeterAnalysisOutcome) -> Void

    private struct Job: Sendable {
        let cancellation: EditorAjarMixerMeterAnalysisCancellation
        let operation: Operation
        let completion: Completion
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pendingJob: Job?
    private var activeCancellation: EditorAjarMixerMeterAnalysisCancellation?
    private var workerScheduled = false
    private var maximumRetainedJobCountValue = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var maximumRetainedJobCount: Int {
        lock.withLock { maximumRetainedJobCountValue }
    }

    func submit(
        cancellation: EditorAjarMixerMeterAnalysisCancellation,
        operation: @escaping Operation,
        completion: @escaping Completion
    ) {
        let shouldSchedule = lock.withLock { () -> Bool in
            activeCancellation?.cancel()
            pendingJob?.cancellation.cancel()
            pendingJob = Job(
                cancellation: cancellation,
                operation: operation,
                completion: completion
            )
            let retainedCount = (activeCancellation == nil ? 0 : 1) + 1
            maximumRetainedJobCountValue = max(maximumRetainedJobCountValue, retainedCount)
            guard !workerScheduled else {
                return false
            }
            workerScheduled = true
            return true
        }
        guard shouldSchedule else {
            return
        }
        queue.async { [self] in
            drain()
        }
    }

    func cancelAll() {
        lock.withLock {
            activeCancellation?.cancel()
            pendingJob?.cancellation.cancel()
            pendingJob = nil
        }
    }

    private func drain() {
        while let job = nextJob() {
            run(job)
            lock.withLock {
                if activeCancellation === job.cancellation {
                    activeCancellation = nil
                }
            }
        }
    }

    private func nextJob() -> Job? {
        lock.withLock {
            guard let job = pendingJob else {
                workerScheduled = false
                return nil
            }
            pendingJob = nil
            activeCancellation = job.cancellation
            return job
        }
    }

    private func run(_ job: Job) {
        do {
            try job.cancellation.check()
            let snapshot = try job.operation()
            try job.cancellation.check()
            job.completion(.success(snapshot))
        } catch is CancellationError {
            // Superseded work is intentionally silent; only the latest generation may publish.
        } catch {
            guard !job.cancellation.isCancelled else {
                return
            }
            job.completion(.failure(String(describing: error)))
        }
    }
}
