// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import AjarMedia
import Foundation

protocol EditorAjarAudioOutputDriving: AnyObject {
    func publish(_ plan: RealtimeAudioRenderPlan) throws
    func start() throws
    func stop()
    func safetyReport() -> RealtimeAudioSafetyReport?
}

extension LiveAudioOutputDriver: EditorAjarAudioOutputDriving {}

enum EditorAjarAudioPipelineError: Error, Equatable, Sendable, CustomStringConvertible {
    case sourcePreparationFailed(String)
    case renderFailed(String)
    case outputFailed(String)

    var description: String {
        switch self {
        case .sourcePreparationFailed(let reason):
            "Audio source preparation failed: \(reason)"
        case .renderFailed(let reason):
            "Audio render failed: \(reason)"
        case .outputFailed(let reason):
            "Audio output failed: \(reason)"
        }
    }
}

enum EditorAjarLiveAudioEvent: Equatable, Sendable {
    case planPublished
    case failed(EditorAjarAudioPipelineError)
}

typealias EditorAjarAudioSourceProviderFactory = @Sendable (
    _ project: Project,
    _ sequence: Sequence,
    _ range: TimeRange
) async throws -> any AudioSourceProvider

protocol EditorAjarAudioCoordinating: AnyObject {
    func start(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws

    func stop()

    func publishSeek(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws

    func ensurePlaybackPlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws
}

final class EditorAjarLiveAudioCoordinator: EditorAjarAudioCoordinating, @unchecked Sendable {
    private static let renderWindowSeconds: Int64 = 2
    private static let refillMarginSeconds: Int64 = 1
    private static let productionOutputFormat = AudioRenderFormat(
        sampleRate: 48_000,
        channelCount: 2
    )

    private let driver: any EditorAjarAudioOutputDriving
    private let renderQueue: DispatchQueue
    private let sourceProviderFactory: EditorAjarAudioSourceProviderFactory
    private let renderFormat: AudioRenderFormat
    private var publishedRange: Range<Int64>?
    private var pendingRange: Range<Int64>?
    private var pendingTask: Task<Void, Never>?
    private var latestPlanPublishedDeliveryTask: Task<Void, Never>?
    private var latestFailureDeliveryTask: Task<Void, Never>?
    private var latestPlaybackFrame: Int64?
    private var generation: UInt64 = 0
    private var eventHandler: (@MainActor @Sendable (EditorAjarLiveAudioEvent) -> Void)?
    /// Session master monitoring gain. Written from the main actor, read only on `renderQueue`
    /// when preparing plans — never on the real-time audio callback (ADR-0012).
    private var masterGainLinear: Double = AudioMixUISupport.defaultMasterGainLinear

    init(
        driver: any EditorAjarAudioOutputDriving,
        sourceProviderFactory: EditorAjarAudioSourceProviderFactory? = nil,
        renderFormat: AudioRenderFormat = EditorAjarLiveAudioCoordinator.productionOutputFormat,
        renderQueue: DispatchQueue = DispatchQueue(
            label: "org.editorajar.live-audio-coordinator.render",
            qos: .userInitiated
        )
    ) {
        self.driver = driver
        self.sourceProviderFactory = sourceProviderFactory ?? { project, sequence, range in
            try await EditorAjarProjectAudioSourceProvider.prepare(
                project: project,
                sequence: sequence,
                range: range,
                outputSampleRate: renderFormat.sampleRate
            )
        }
        self.renderFormat = renderFormat
        self.renderQueue = renderQueue
    }

    func setEventHandler(
        _ handler: @escaping @MainActor @Sendable (EditorAjarLiveAudioEvent) -> Void
    ) {
        renderQueue.async { [weak self] in
            self?.eventHandler = handler
        }
    }

    /// Updates session master gain. Applied when the next plan is prepared off-thread.
    func setMasterGainLinear(_ linear: Double) {
        let clamped = min(
            AudioMixLimits.maximumGain.doubleValue,
            max(AudioMixLimits.minimumGain.doubleValue, linear)
        )
        renderQueue.async { [weak self] in
            self?.masterGainLinear = clamped
        }
    }

    convenience init() throws {
        try self.init(
            driver: LiveAudioOutputDriver(format: Self.productionOutputFormat),
            renderFormat: Self.productionOutputFormat
        )
    }

    func start(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        try enqueuePlan(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames,
            force: true,
            restartOutputAfterPublish: true
        )
    }

    func stop() {
        renderQueue.async { [weak self] in
            self?.invalidatePendingWork(stopOutput: true)
        }
    }

    func publishSeek(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        try enqueuePlan(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames,
            force: true,
            restartOutputAfterPublish: true
        )
    }

    func ensurePlaybackPlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws {
        try enqueuePlan(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames,
            force: false,
            restartOutputAfterPublish: false
        )
    }

    func drainPendingRendersForTesting() async {
        let task = renderQueue.sync { pendingTask }
        await task?.value
        renderQueue.sync {}
    }

    func drainControlQueueForTesting() {
        renderQueue.sync {}
    }

    func drainPlanPublishedDeliveryForTesting() async {
        let task = renderQueue.sync { latestPlanPublishedDeliveryTask }
        await task?.value
        renderQueue.sync {}
    }

    func drainFailureDeliveryForTesting() async {
        let task = renderQueue.sync { latestFailureDeliveryTask }
        await task?.value
        renderQueue.sync {}
    }

    private func shouldPublishPlan(playheadFrame: Int64, sequence: Sequence) -> Bool {
        if let pendingRange, pendingRange.contains(playheadFrame) {
            return false
        }

        guard let publishedRange else {
            return true
        }
        if !publishedRange.contains(playheadFrame) {
            return true
        }

        let refillMargin = Self.refillMarginFrames(for: sequence)
        return publishedRange.upperBound - playheadFrame <= refillMargin
    }

    private func enqueuePlan(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64,
        force: Bool,
        restartOutputAfterPublish: Bool
    ) throws {
        let request = try Self.renderRequest(
            project: project,
            sequence: sequence,
            playheadFrame: playheadFrame,
            durationFrames: durationFrames
        )

        renderQueue.async { [weak self] in
            guard let self else {
                return
            }
            // Even when a refill is already pending, retain the newest video playhead so the
            // completed audio window can begin at the matching sample instead of replaying the
            // time spent decoding.
            self.latestPlaybackFrame = request.playheadFrame
            guard force || self.shouldPublishPlan(
                playheadFrame: request.playheadFrame,
                sequence: sequence
            ) else {
                return
            }
            self.generation &+= 1
            let token = self.generation
            self.pendingTask?.cancel()
            if force {
                self.driver.stop()
                self.publishedRange = nil
            }
            self.pendingRange = request.publishRange
            let gain = self.masterGainLinear
            let factory = self.sourceProviderFactory
            let renderFormat = self.renderFormat
            self.pendingTask = Task.detached(priority: .userInitiated) { [weak self] in
                let provider: any AudioSourceProvider
                do {
                    provider = try await factory(project, sequence, request.renderRange)
                    try Task.checkCancellation()
                } catch is CancellationError {
                    return
                } catch {
                    self?.finishPlanFailure(
                        .sourcePreparationFailed(String(describing: error)),
                        token: token
                    )
                    return
                }

                let buffer: RenderedAudioBuffer
                do {
                    let cancellationCheck: AudioRenderCancellationCheck = {
                        try Task.checkCancellation()
                    }
                    buffer = try Self.renderBuffer(
                        project: project,
                        sequence: sequence,
                        range: request.renderRange,
                        format: renderFormat,
                        masterGainLinear: gain,
                        sourceProvider: provider,
                        cancellationCheck: cancellationCheck
                    )
                    try Task.checkCancellation()
                } catch is CancellationError {
                    return
                } catch {
                    self?.finishPlanFailure(
                        .renderFailed(String(describing: error)),
                        token: token
                    )
                    return
                }

                self?.finishPlanSuccess(
                    buffer,
                    request: request,
                    token: token,
                    restartOutputAfterPublish: restartOutputAfterPublish
                )
            }
        }
    }

    private func finishPlanSuccess(
        _ buffer: RenderedAudioBuffer,
        request: LiveAudioRenderRequest,
        token: UInt64,
        restartOutputAfterPublish: Bool
    ) {
        renderQueue.async { [weak self] in
            guard let self, self.generation == token else {
                return
            }
            self.pendingTask = nil
            self.pendingRange = nil
            do {
                let currentPlaybackFrame = self.latestPlaybackFrame ?? request.playheadFrame
                let startingAudioFrame = try Self.outputFrameOffset(
                    from: request.playheadFrame,
                    to: currentPlaybackFrame,
                    timelineFrameRate: request.timelineFrameRate,
                    outputSampleRate: buffer.format.sampleRate
                )
                let plan = RealtimeAudioRenderPlan(
                    buffer: buffer,
                    startingAtFrame: startingAudioFrame
                )
                try self.driver.publish(plan)
                self.publishedRange = request.publishRange
                if restartOutputAfterPublish {
                    self.emitInitialPlanThenStartOutput(token: token)
                } else {
                    self.emitPlanPublishedIfCurrent(token: token)
                }
            } catch {
                self.driver.stop()
                self.publishedRange = nil
                self.emitFailureIfCurrent(
                    .outputFailed(String(describing: error)),
                    token: token
                )
            }
        }
    }

    private func startOutputIfCurrent(token: UInt64) {
        guard generation == token, publishedRange != nil else {
            return
        }
        do {
            try driver.start()
        } catch {
            driver.stop()
            publishedRange = nil
            emitFailureIfCurrent(
                .outputFailed(String(describing: error)),
                token: token
            )
        }
    }

    private func finishPlanFailure(
        _ error: EditorAjarAudioPipelineError,
        token: UInt64
    ) {
        renderQueue.async { [weak self] in
            guard let self, self.generation == token else {
                return
            }
            self.pendingTask = nil
            self.pendingRange = nil
            self.publishedRange = nil
            self.driver.stop()
            self.emitFailureIfCurrent(error, token: token)
        }
    }

    private func invalidatePendingWork(stopOutput: Bool) {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        pendingRange = nil
        publishedRange = nil
        latestPlaybackFrame = nil
        if stopOutput {
            driver.stop()
        }
    }

    private static func renderRequest(
        project: Project,
        sequence: Sequence,
        playheadFrame: Int64,
        durationFrames: Int64
    ) throws -> LiveAudioRenderRequest {
        let boundedPlayheadFrame = max(0, min(playheadFrame, max(0, durationFrames - 1)))
        let windowFrames = Self.windowFrames(
            from: boundedPlayheadFrame,
            durationFrames: durationFrames,
            sequence: sequence
        )
        let range = try TimeRange(
            start: RationalTime.atFrame(boundedPlayheadFrame, frameRate: sequence.timebase),
            duration: sequence.timebase.duration(ofFrames: windowFrames)
        )

        return LiveAudioRenderRequest(
            playheadFrame: boundedPlayheadFrame,
            renderRange: range,
            publishRange: boundedPlayheadFrame..<(boundedPlayheadFrame + windowFrames),
            timelineFrameRate: sequence.timebase
        )
    }

    private struct LiveAudioRenderRequest {
        let playheadFrame: Int64
        let renderRange: TimeRange
        let publishRange: Range<Int64>
        let timelineFrameRate: FrameRate
    }

    /// Builds the realtime callback buffer off-thread, flattening compound/nested sources with
    /// the same contributor semantics as the offline mix (FR-AUD-007, FR-CMP-001).
    ///
    /// Session master gain is applied here by scaling the pre-rendered buffer so the RT
    /// callback remains a pure copy (ADR-0012).
    // swiftlint:disable:next function_parameter_count
    private static func renderBuffer(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        format: AudioRenderFormat,
        masterGainLinear: Double,
        sourceProvider: any AudioSourceProvider,
        cancellationCheck: @escaping AudioRenderCancellationCheck
    ) throws -> RenderedAudioBuffer {
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
        return try Self.applyingMasterGain(
            masterGainLinear,
            to: buffer,
            cancellationCheck: cancellationCheck
        )
    }

    private static func outputFrameOffset(
        from requestedPlaybackFrame: Int64,
        to currentPlaybackFrame: Int64,
        timelineFrameRate: FrameRate,
        outputSampleRate: Int
    ) throws -> Int {
        let elapsedTimelineFrames = max(0, currentPlaybackFrame - requestedPlaybackFrame)
        let elapsed = try timelineFrameRate.duration(ofFrames: elapsedTimelineFrames)
        return try sampleFrameIndex(
            for: elapsed,
            sampleRate: outputSampleRate,
            rounding: .nearestOrAwayFromZero
        )
    }

    private static func applyingMasterGain(
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

    fileprivate static func sampleFrameCount(
        for duration: RationalTime,
        sampleRate: Int
    ) throws -> Int {
        let sampleFrames = try duration.value(atTimescale: Int64(sampleRate))
        guard sampleFrames <= Int64(Int.max) else {
            throw AudioRenderError.timeArithmetic("sample frame count \(sampleFrames) is out of range")
        }
        return max(0, Int(sampleFrames))
    }

    fileprivate static func sampleFrameIndex(
        for time: RationalTime,
        sampleRate: Int,
        rounding: FrameRoundingRule
    ) throws -> Int {
        let rate = try FrameRate(frames: Int64(sampleRate))
        let value = try time.frameIndex(at: rate, rounding: rounding)
        guard value >= 0, value <= Int64(Int.max) else {
            throw AudioRenderError.timeArithmetic("sample index \(value) is out of range")
        }
        return Int(value)
    }

    private static func windowFrames(
        from playheadFrame: Int64,
        durationFrames: Int64,
        sequence: Sequence
    ) -> Int64 {
        let remainingFrames = max(1, durationFrames - playheadFrame)
        return min(remainingFrames, renderWindowFrames(for: sequence))
    }

    private static func renderWindowFrames(for sequence: Sequence) -> Int64 {
        max(1, sequence.timebase.frames * renderWindowSeconds / sequence.timebase.seconds)
    }

    private static func refillMarginFrames(for sequence: Sequence) -> Int64 {
        max(1, sequence.timebase.frames * refillMarginSeconds / sequence.timebase.seconds)
    }
}

private extension EditorAjarLiveAudioCoordinator {
    /// Production video remains paused until its MainActor handler observes the prepared plan.
    /// Start the audio device only after that handler returns, preventing audio from running ahead
    /// while the main actor is busy. Tests without a handler retain the direct start path.
    func emitInitialPlanThenStartOutput(token: UInt64) {
        guard let eventHandler else {
            startOutputIfCurrent(token: token)
            return
        }
        latestPlanPublishedDeliveryTask = Task { @MainActor [weak self] in
            guard let self, self.planPublishedEventIsCurrent(token: token) else {
                return
            }
            eventHandler(.planPublished)
            self.renderQueue.async { [weak self] in
                self?.startOutputIfCurrent(token: token)
            }
        }
    }

    func emitPlanPublishedIfCurrent(token: UInt64) {
        guard let eventHandler else {
            return
        }
        latestPlanPublishedDeliveryTask = Task { @MainActor [weak self] in
            guard let self, self.planPublishedEventIsCurrent(token: token) else {
                return
            }
            eventHandler(.planPublished)
        }
    }

    /// Failure delivery crosses to the MainActor. Re-check the generation there so a stop or
    /// seek that wins the race after render-queue failure handling cannot pause a newer session.
    func emitFailureIfCurrent(
        _ error: EditorAjarAudioPipelineError,
        token: UInt64
    ) {
        guard let eventHandler else {
            return
        }
        latestFailureDeliveryTask = Task { @MainActor [weak self] in
            guard let self, self.failureEventIsCurrent(token: token) else {
                return
            }
            eventHandler(.failed(error))
        }
    }

    /// Re-checks generation at MainActor delivery, after any queued seek/stop invalidation.
    func planPublishedEventIsCurrent(token: UInt64) -> Bool {
        renderQueue.sync {
            generation == token && publishedRange != nil
        }
    }

    func failureEventIsCurrent(token: UInt64) -> Bool {
        renderQueue.sync {
            generation == token
        }
    }

}

/// Immutable source provider shared by live playback, meters, preview, and export.
///
/// Production construction is asynchronous because imported media must be decoded before the
/// synchronous mixer can enter its deterministic render pass. The legacy initializer remains as
/// a deliberately narrow sample-project seam for UI tests that never touch platform media.
enum EditorAjarAudioSourcePreparationError: Error, Equatable, Sendable, CustomStringConvertible {
    case sampleCountOverflow(mediaID: UUID, frameCount: Int, channelCount: Int)
    case memoryBudgetExceeded(
        mediaID: UUID,
        preparedBytes: Int,
        requestedBytes: Int,
        maximumBytes: Int
    )

    var description: String {
        switch self {
        case .sampleCountOverflow(let mediaID, let frameCount, let channelCount):
            "audio source \(mediaID) sample count overflows for \(frameCount) frames and "
                + "\(channelCount) channels"
        case .memoryBudgetExceeded(
            let mediaID,
            let preparedBytes,
            let requestedBytes,
            let maximumBytes
        ):
            "audio source preparation for \(mediaID) would retain "
                + "\(Self.byteTotalDescription(preparedBytes, requestedBytes)) bytes, "
                + "exceeding the bounded "
                + "\(maximumBytes)-byte budget"
        }
    }

    private static func byteTotalDescription(_ left: Int, _ right: Int) -> String {
        let total = left.addingReportingOverflow(right)
        return total.overflow ? "more than \(Int.max)" : String(total.partialValue)
    }
}

struct EditorAjarProjectAudioSourceProvider: AudioSourceProvider {
    static let maximumPreparedSourceBytes = 64 * 1_024 * 1_024

    private struct PreparedSource: Sendable {
        let plannedRange: TimeRange
        let buffer: AudioSourceBuffer
    }

    private let sources: [UUID: [PreparedSource]]

    init(project: Project, sequence: Sequence, range: TimeRange) throws {
        let plan = try AudioSourcePlanner.plan(
            project: project,
            sequence: sequence,
            range: range
        )
        let mediaByID = Dictionary(
            project.mediaPool.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var prepared: [UUID: [PreparedSource]] = [:]
        var preparedBytes = 0
        for window in plan.windows {
            guard let media = mediaByID[window.mediaID],
                  media.metadata.codecID == EditorAjarSampleProjectFactory.sampleToneCodecID,
                  let layout = media.metadata.audioChannelLayout
            else {
                throw AudioRenderError.missingAudioSource(window.mediaID)
            }
            let result = try Self.sampleToneSource(
                media: media,
                channelCount: layout.channelCount,
                sampleRate: project.settings.audioSampleRate,
                sourceWindow: window.decodingFrameRange(
                    sampleRate: project.settings.audioSampleRate
                ),
                preparedBytes: preparedBytes
            )
            prepared[window.mediaID, default: []].append(
                PreparedSource(plannedRange: window.range, buffer: result.source)
            )
            preparedBytes = result.totalPreparedBytes
        }
        sources = prepared
    }

    private init(sources: [UUID: [PreparedSource]]) {
        self.sources = sources
    }

    /// Plans exact source-time needs and prepares every referenced media buffer concurrently.
    static func prepare(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        outputSampleRate: Int? = nil,
        cache: EditorAjarDecodedAudioWindowCache = .shared
    ) async throws -> Self {
        let plan = try AudioSourcePlanner.plan(
            project: project,
            sequence: sequence,
            range: range,
            outputSampleRate: outputSampleRate
        )
        let mediaByID = Dictionary(
            project.mediaPool.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let projectSampleRate = project.settings.audioSampleRate

        // Decode serially. The provider must retain its complete planned set for the synchronous
        // deterministic mixer, so unbounded per-media task groups only multiply peak memory and
        // open-reader pressure without reducing that retained set.
        var prepared: [UUID: [PreparedSource]] = [:]
        var preparedBytes = 0
        for window in plan.windows {
            try Task.checkCancellation()
            guard let media = mediaByID[window.mediaID], !media.isOffline else {
                throw AudioRenderError.missingAudioSource(window.mediaID)
            }
            let source: AudioSourceBuffer
            if media.metadata.codecID == EditorAjarSampleProjectFactory.sampleToneCodecID,
               let layout = media.metadata.audioChannelLayout {
                let result = try Self.sampleToneSource(
                    media: media,
                    channelCount: layout.channelCount,
                    sampleRate: projectSampleRate,
                    sourceWindow: window.decodingFrameRange(sampleRate: projectSampleRate),
                    preparedBytes: preparedBytes
                )
                source = result.source
                preparedBytes = result.totalPreparedBytes
            } else {
                let decoded = try await cache.decode(media: media, window: window)
                try Task.checkCancellation()
                source = try AudioSourceBuffer(
                    format: AudioRenderFormat(
                        sampleRate: decoded.sampleRate,
                        channelCount: decoded.channelCount
                    ),
                    frameCount: decoded.frameCount,
                    samples: decoded.samples,
                    frameOffset: decoded.frameOffset
                )
                preparedBytes = try Self.validatedPreparedByteTotal(
                    currentBytes: preparedBytes,
                    frameCount: source.frameCount,
                    channelCount: source.format.channelCount,
                    mediaID: media.id
                )
            }
            prepared[window.mediaID, default: []].append(
                PreparedSource(plannedRange: window.range, buffer: source)
            )
        }
        return Self(sources: prepared)
    }

    func audioSource(for mediaID: UUID) throws -> AudioSourceBuffer {
        guard let source = sources[mediaID]?.first?.buffer else {
            throw AudioRenderError.missingAudioSource(mediaID)
        }
        return source
    }

    func audioSource(
        for mediaID: UUID,
        covering sourceRange: TimeRange
    ) throws -> AudioSourceBuffer {
        guard let candidates = sources[mediaID] else {
            throw AudioRenderError.missingAudioSource(mediaID)
        }
        for candidate in candidates where try Self.range(
            candidate.plannedRange,
            contains: sourceRange
        ) {
            return candidate.buffer
        }
        throw AudioRenderError.missingAudioSource(mediaID)
    }

    private static func range(_ outer: TimeRange, contains inner: TimeRange) throws -> Bool {
        let innerEnd = try inner.end()
        let outerEnd = try outer.end()
        return outer.start <= inner.start && innerEnd <= outerEnd
    }

    private static func sampleToneSource(
        media: MediaRef,
        channelCount: Int,
        sampleRate: Int,
        sourceWindow: Range<Int>?,
        preparedBytes: Int
    ) throws -> (source: AudioSourceBuffer, totalPreparedBytes: Int) {
        let mediaFrameCount = try EditorAjarLiveAudioCoordinator.sampleFrameCount(
            for: media.metadata.duration,
            sampleRate: sampleRate
        )
        let requestedWindow = sourceWindow ?? 0..<mediaFrameCount
        let frameOffset = min(max(0, requestedWindow.lowerBound), mediaFrameCount)
        let upperBound = min(max(frameOffset, requestedWindow.upperBound), mediaFrameCount)
        let frameCount = upperBound - frameOffset
        let totalPreparedBytes = try validatedPreparedByteTotal(
            currentBytes: preparedBytes,
            frameCount: frameCount,
            channelCount: channelCount,
            mediaID: media.id
        )
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * channelCount)

        for frame in 0..<frameCount {
            let absoluteFrame = frameOffset + frame
            let phase = 2.0 * Double.pi * 440.0 * Double(absoluteFrame) / Double(sampleRate)
            let sample = Float(sin(phase) * 0.12)
            for _ in 0..<channelCount {
                samples.append(sample)
            }
        }

        return (
            try AudioSourceBuffer(
                format: AudioRenderFormat(sampleRate: sampleRate, channelCount: channelCount),
                frameCount: frameCount,
                samples: samples,
                frameOffset: frameOffset
            ),
            totalPreparedBytes
        )
    }

    static func validatedPreparedByteTotal(
        currentBytes: Int,
        frameCount: Int,
        channelCount: Int,
        mediaID: UUID
    ) throws -> Int {
        let sampleCount = frameCount.multipliedReportingOverflow(by: channelCount)
        let byteCount = sampleCount.partialValue.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size
        )
        guard frameCount >= 0,
            channelCount > 0,
            currentBytes >= 0,
            !sampleCount.overflow,
            !byteCount.overflow
        else {
            throw EditorAjarAudioSourcePreparationError.sampleCountOverflow(
                mediaID: mediaID,
                frameCount: frameCount,
                channelCount: channelCount
            )
        }
        let total = currentBytes.addingReportingOverflow(byteCount.partialValue)
        guard !total.overflow,
            total.partialValue <= maximumPreparedSourceBytes
        else {
            throw EditorAjarAudioSourcePreparationError.memoryBudgetExceeded(
                mediaID: mediaID,
                preparedBytes: currentBytes,
                requestedBytes: byteCount.partialValue,
                maximumBytes: maximumPreparedSourceBytes
            )
        }
        return total.partialValue
    }
}

/// Bounded decoded-window cache shared across live playback, metering, and export preparation.
/// Four-second chunk alignment lets frequent meter requests reuse the surrounding live-playback
/// decode. Only completed windows are shared, so cancelling one consumer never disrupts another
/// live/export request; failed or cancelled reads are never cached.
actor EditorAjarDecodedAudioWindowCache {
    static let shared = EditorAjarDecodedAudioWindowCache()

    private static let chunkSeconds: Double = 4
    private static let maximumChunkedDurationSeconds: Double = 8
    private static let maximumBytes = 64 * 1_024 * 1_024

    private struct Key: Hashable, Sendable {
        let mediaID: UUID
        let sourceURL: URL
        let playableContentHash: ContentHash?
        let sourceRevision: MediaSourceRevision
        let sourceRange: TimeRange
    }

    private struct Entry: Sendable {
        let window: DecodedAudioWindow
        let byteCount: Int
        var accessOrder: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var totalBytes = 0
    private var accessOrder: UInt64 = 0
    private let identityVerifier: MediaSourceIdentityVerifier

    init(identityVerifier: MediaSourceIdentityVerifier = .shared) {
        self.identityVerifier = identityVerifier
    }

    func decode(
        media: MediaRef,
        window: AudioSourceTimeWindow,
        decoder: AudioPCMDecoder = AudioPCMDecoder()
    ) async throws -> DecodedAudioWindow {
        guard let sourceURL = media.sourceURL else {
            throw AudioPCMDecodeError.missingSourceURL(mediaID: media.id)
        }
        guard !media.isOffline else {
            throw AudioPCMDecodeError.missingSource(sourceURL)
        }
        let verifiedSource: VerifiedMediaSource
        do {
            verifiedSource = try await identityVerifier.verifyBeforeReading(media)
        } catch MediaSourceIdentityVerificationError.sourceUnavailable {
            // Preserve the decoder-facing missing-file contract for an initially absent source.
            throw AudioPCMDecodeError.missingSource(sourceURL)
        }
        let sourceRange = try Self.cacheRange(
            for: window.range,
            mediaDuration: media.metadata.duration
        )
        let key = Key(
            mediaID: media.id,
            sourceURL: sourceURL.standardizedFileURL,
            playableContentHash: verifiedSource.playableContentHash,
            sourceRevision: verifiedSource.sourceRevision,
            sourceRange: sourceRange
        )

        accessOrder &+= 1
        if var entry = entries[key] {
            entry.accessOrder = accessOrder
            entries[key] = entry
            try Task.checkCancellation()
            // A cache hit is still tied to the verified filesystem revision. Re-check just before
            // returning so a replacement racing the lookup cannot revive stale decoded bytes.
            try await identityVerifier.verifyAfterReading(verifiedSource)
            return entry.window
        }

        let decoded = try await decoder.decodeWindow(
            from: media,
            sourceRange: sourceRange,
            leadingFrameCount: 2,
            trailingFrameCount: 1
        )
        try Task.checkCancellation()
        try await identityVerifier.verifyAfterReading(verifiedSource)
        insert(decoded, for: key)
        return decoded
    }

    func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }

    private func insert(_ window: DecodedAudioWindow, for key: Key) {
        let byteCount = window.samples.count.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size
        )
        guard !byteCount.overflow, byteCount.partialValue <= Self.maximumBytes else {
            return
        }
        if let replaced = entries[key] {
            totalBytes -= replaced.byteCount
        }
        accessOrder &+= 1
        entries[key] = Entry(
            window: window,
            byteCount: byteCount.partialValue,
            accessOrder: accessOrder
        )
        totalBytes += byteCount.partialValue

        while totalBytes > Self.maximumBytes,
              let oldest = entries.min(by: { $0.value.accessOrder < $1.value.accessOrder }) {
            totalBytes -= oldest.value.byteCount
            entries.removeValue(forKey: oldest.key)
        }
    }

    private static func cacheRange(
        for range: TimeRange,
        mediaDuration: RationalTime
    ) throws -> TimeRange {
        let end = try range.end()
        let candidate: TimeRange
        if range.duration.seconds <= maximumChunkedDurationSeconds {
            let chunkStartSeconds = floor(range.start.seconds / chunkSeconds) * chunkSeconds
            let chunkEndSeconds = max(
                chunkStartSeconds + chunkSeconds,
                ceil(end.seconds / chunkSeconds) * chunkSeconds
            )
            if chunkStartSeconds.isFinite,
               chunkEndSeconds.isFinite,
               let chunkStart = Int64(exactly: chunkStartSeconds.rounded()),
               let chunkDuration = Int64(
                exactly: (chunkEndSeconds - chunkStartSeconds).rounded()
               ) {
                candidate = try TimeRange(
                    start: RationalTime(value: chunkStart, timescale: 1),
                    duration: RationalTime(value: chunkDuration, timescale: 1)
                )
            } else {
                candidate = range
            }
        } else {
            candidate = range
        }

        // Cache alignment is only a reuse optimization. It must never turn optional space past
        // the probed EOF into required decoder frames, or a healthy final source window would be
        // misreported as truncated media.
        let clampedStart = min(max(candidate.start, .zero), mediaDuration)
        let clampedEnd = max(clampedStart, min(try candidate.end(), mediaDuration))
        return try TimeRange(
            start: clampedStart,
            duration: clampedEnd.subtracting(clampedStart)
        )
    }

}
