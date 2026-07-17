// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import CoreMedia
import Foundation

extension ExportSession {
    func executeRun() async throws -> ExportResult {
        var transaction: ExportOutputTransaction?
        var writer: (any ExportWriting)?
        do {
            return try await performExport(
                transaction: &transaction,
                writer: &writer
            )
        } catch {
            writer?.cancel()
            throw finalizeFailure(error, transaction: transaction)
        }
    }

    func performExport(
        transaction: inout ExportOutputTransaction?,
        writer: inout (any ExportWriting)?
    ) async throws -> ExportResult {
        try checkCancellation()
        let preparedTransaction = try ExportOutputTransaction(
            destinationURL: request.destinationURL,
            destinationCollisionPolicy: request.destinationCollisionPolicy
        )
        transaction = preparedTransaction
        let preparedWriter = try writerFactory(
            preparedTransaction.temporaryURL,
            request.settings
        )
        writer = preparedWriter
        try installActiveWriter(preparedWriter)
        let audioStream = try await prepareAudioIfRequested()
        try checkCancellation()
        try preparedWriter.start()
        try transition(to: .writing)

        let videoFrameCount = try request.videoFrameCount()
        setTotalFrames(videoFrameCount)
        try await appendMedia(
            writer: preparedWriter,
            videoFrameCount: videoFrameCount,
            audioStream: audioStream
        )
        try checkCancellation()
        try transition(to: .finishing)
        // Use the video frame-rate CMTime basis for frame-aligned ranges so endSession compares
        // cleanly against presentationTime stamps (see ExportTimeMapping.endTime).
        try await preparedWriter.finish(
            at: try ExportTimeMapping.endTime(
                for: request.range.duration,
                frameRate: request.settings.video.frameRate
            )
        )
        beforePublish?()
        try publish(preparedTransaction)
        let sourceSelections = sourceSelectionRecords
        return ExportResult(
            destinationURL: request.destinationURL,
            duration: request.range.duration,
            videoFrameCount: videoFrameCount,
            audioFrameCount: audioStream?.totalFrameCount ?? 0,
            sourceSelectionRecordCount: sourceSelections.count,
            usedProxyMedia: sourceSelections.contains { $0.tier == .proxy }
        )
    }

    func finalizeFailure(
        _ error: Error,
        transaction: ExportOutputTransaction?
    ) -> ExportError {
        let mapped = mapRunError(error)
        do {
            try transaction?.cleanUp()
        } catch let cleanup as ExportCleanupFailure {
            setTerminalState(.failed)
            return .cleanupFailed(
                rootCause: mapped,
                temporaryURL: cleanup.temporaryURL,
                reason: cleanup.reason
            )
        } catch {
            setTerminalState(.failed)
            return .cleanupFailed(
                rootCause: mapped,
                temporaryURL: transaction?.temporaryURL ?? request.destinationURL,
                reason: String(describing: error)
            )
        }
        setTerminalState(mapped == .cancelled ? .cancelled : .failed)
        return mapped
    }

    func beginRun() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        // cancel() before run() leaves the session in `.cancelled` with the cancellation flag set;
        // produce the clean cancelled outcome instead of invalidSessionState.
        if stateValue == .cancelled || (stateValue == .ready && cancellationRequested) {
            stateValue = .cancelled
            throw ExportError.cancelled
        }
        guard stateValue == .ready else {
            throw ExportError.invalidSessionState(stateValue)
        }
        stateValue = .preparing
    }

    func prepareAudioIfRequested() async throws -> ExportAudioStream? {
        guard let audioSettings = request.settings.audio else {
            return nil
        }
        do {
            try checkCancellation()
            let totalFrameCount = try audioFrameCount(
                duration: request.range.duration,
                sampleRate: audioSettings.sampleRate
            )
            let stream = ExportAudioStream(
                settings: audioSettings,
                totalFrameCount: totalFrameCount,
                firstChunk: nil
            )
            if totalFrameCount > 0 {
                try await renderNextAudioChunk(in: stream)
            }
            return stream
        } catch {
            try checkCancellation()
            throw ExportError.audioMixFailed(String(describing: error))
        }
    }

    func renderNextAudioChunk(in stream: ExportAudioStream) async throws {
        do {
            try checkCancellation()
            let frameOffset = stream.nextChunkFrameOffset
            let remainingFrames = stream.totalFrameCount - frameOffset
            guard remainingFrames > 0 else {
                return
            }
            let maximumFrames = stream.settings.sampleRate
                * Self.audioRenderChunkDurationSeconds
            let frameCount = min(maximumFrames, remainingFrames)
            let range = try audioChunkRange(
                frameOffset: frameOffset,
                frameCount: frameCount,
                totalFrameCount: stream.totalFrameCount,
                sampleRate: stream.settings.sampleRate
            )
            let provider = try await audioProvider(for: range)
            try checkCancellation()
            let buffer = try OfflineAudioMixer.render(
                project: request.project,
                sequence: request.sequence,
                range: range,
                format: AudioRenderFormat(
                    sampleRate: stream.settings.sampleRate,
                    channelCount: stream.settings.channelCount
                ),
                sourceProvider: provider,
                continuation: &stream.continuation,
                cancellationCheck: { [weak self] in
                    try self?.checkCancellation()
                }
            )
            guard buffer.frameCount == frameCount else {
                throw ExportError.audioMixFailed(
                    "bounded audio render returned \(buffer.frameCount) frames, expected "
                        + "\(frameCount)"
                )
            }
            try checkCancellation()
            stream.currentChunk = ExportAudioChunk(
                buffer: buffer,
                presentationFrameOffset: frameOffset,
                appendedFrameCount: 0
            )
            stream.nextChunkFrameOffset = frameOffset + frameCount
        } catch {
            try checkCancellation()
            if let exportError = error as? ExportError {
                throw exportError
            }
            throw ExportError.audioMixFailed(String(describing: error))
        }
    }

    func audioProvider(for range: TimeRange) async throws -> any AudioSourceProvider {
        if let audioSourceProviderFactory {
            let task = Task<any AudioSourceProvider, Error> {
                try await audioSourceProviderFactory(range)
            }
            try installActiveAudioProviderTask(task)
            defer { clearActiveAudioProviderTask() }
            return try await task.value
        }
        if let audioSourceProvider {
            return audioSourceProvider
        }
        throw ExportError.missingAudioSourceProvider
    }

    func audioChunkRange(
        frameOffset: Int,
        frameCount: Int,
        totalFrameCount: Int,
        sampleRate: Int
    ) throws -> TimeRange {
        let offset = try RationalTime(
            value: Int64(frameOffset),
            timescale: Int64(sampleRate)
        )
        let start = try request.range.start.adding(offset)
        let duration: RationalTime
        if frameOffset + frameCount == totalFrameCount {
            duration = try request.range.end().subtracting(start)
        } else {
            duration = try RationalTime(
                value: Int64(frameCount),
                timescale: Int64(sampleRate)
            )
        }
        return try TimeRange(start: start, duration: duration)
    }

    func audioFrameCount(duration: RationalTime, sampleRate: Int) throws -> Int {
        let rate = try FrameRate(frames: Int64(sampleRate))
        let value = try duration.frameIndex(at: rate, rounding: .nearestOrAwayFromZero)
        guard value >= 0, value <= Int64(Int.max) else {
            throw ExportError.audioMixFailed("audio frame count \(value) is out of range")
        }
        return Int(value)
    }

    func checkCancellation() throws {
        stateLock.lock()
        let requested = cancellationRequested
        stateLock.unlock()
        if requested || Task.isCancelled {
            throw ExportError.cancelled
        }
    }

    func installActiveWriter(_ writer: any ExportWriting) throws {
        stateLock.lock()
        activeWriter = writer
        let cancelled = cancellationRequested || Task.isCancelled
        if cancelled {
            stateValue = .cancelling
        }
        stateLock.unlock()
        if cancelled {
            writer.cancel()
            throw ExportError.cancelled
        }
    }

    func installActiveAudioProviderTask(
        _ task: Task<any AudioSourceProvider, Error>
    ) throws {
        stateLock.lock()
        activeAudioProviderTask = task
        let cancelled = cancellationRequested || Task.isCancelled
        if cancelled {
            stateValue = .cancelling
        }
        stateLock.unlock()
        if cancelled {
            task.cancel()
            throw ExportError.cancelled
        }
    }

    func clearActiveAudioProviderTask() {
        stateLock.lock()
        activeAudioProviderTask = nil
        stateLock.unlock()
    }

    func transition(to next: ExportSessionState) throws {
        stateLock.lock()
        let cancelled = cancellationRequested || Task.isCancelled
        stateValue = cancelled ? .cancelling : next
        stateLock.unlock()
        if cancelled {
            throw ExportError.cancelled
        }
    }

    func publish(_ transaction: ExportOutputTransaction) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancellationRequested, !Task.isCancelled else {
            stateValue = .cancelling
            throw ExportError.cancelled
        }
        try transaction.commit()
        activeWriter = nil
        activeAudioProviderTask = nil
        stateValue = .completed
    }

    func mapRunError(_ error: Error) -> ExportError {
        stateLock.lock()
        let cancelled = cancellationRequested || Task.isCancelled
        stateLock.unlock()
        if cancelled {
            return .cancelled
        }
        return ExportErrorMapper.map(error, destinationURL: request.destinationURL)
    }

    func setTerminalState(_ state: ExportSessionState) {
        stateLock.lock()
        activeWriter = nil
        activeAudioProviderTask = nil
        stateValue = state
        stateLock.unlock()
    }

    func setTotalFrames(_ total: Int64) {
        stateLock.lock()
        totalFramesValue = total
        framesWrittenValue = 0
        let snapshot = ExportProgress(framesWritten: 0, totalFrames: total)
        stateLock.unlock()
        onFrameProgress?(snapshot)
    }

    func recordFrameWritten() {
        stateLock.lock()
        framesWrittenValue += 1
        let snapshot = ExportProgress(
            framesWritten: framesWrittenValue,
            totalFrames: totalFramesValue
        )
        stateLock.unlock()
        onFrameProgress?(snapshot)
    }

    /// Records the resolved media tier for every media id visible to this export (FR-EXP-007).
    ///
    /// Prefer tiers observed on the **executed** render graph when the frame provider
    /// implements ``ExportGraphSourceAuditing`` (production path). Fall back to the session
    /// policy for stub providers. Production graphs must never carry `.proxy` (ADR-0019).
    func recordSourceSelections(forFrame index: Int64) {
        let rows: [ExportFrameSourceSelection]
        if let auditing = frameProvider as? ExportGraphSourceAuditing,
            !auditing.lastRenderedExportSourceTiers.isEmpty {
            rows = auditing.lastRenderedExportSourceTiers.map { entry in
                ExportFrameSourceSelection(
                    frameIndex: index,
                    mediaID: entry.mediaID,
                    tier: entry.tier
                )
            }
        } else {
            var mediaIDs = Set(request.project.mediaPool.map(\.id))
            for track in request.sequence.videoTracks + request.sequence.audioTracks {
                for item in track.items {
                    guard case .clip(let clip) = item else {
                        continue
                    }
                    if case .media(let mediaID) = clip.source {
                        mediaIDs.insert(mediaID)
                    }
                }
            }
            rows = mediaIDs.sorted { $0.uuidString < $1.uuidString }.map { mediaID in
                ExportFrameSourceSelection(
                    frameIndex: index,
                    mediaID: mediaID,
                    tier: sourceSelectionPolicy.resolvedTier(for: mediaID)
                )
            }
        }
        stateLock.lock()
        sourceSelectionRecordsValue.append(contentsOf: rows)
        stateLock.unlock()
    }
}
