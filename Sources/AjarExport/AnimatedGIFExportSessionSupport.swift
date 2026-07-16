// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension AnimatedGIFExportSession {
    func beginRun() throws {
        try stateLock.withLock {
            if stateValue == .cancelled || (stateValue == .ready && cancellationRequested) {
                stateValue = .cancelled
                throw ExportError.cancelled
            }
            guard stateValue == .ready else {
                throw ExportError.invalidSessionState(stateValue)
            }
            stateValue = .preparing
        }
    }

    func checkCancellation() throws {
        let requested = stateLock.withLock { cancellationRequested }
        if requested || Task.isCancelled {
            throw ExportError.cancelled
        }
    }

    func transition(to next: ExportSessionState) throws {
        let cancelled = stateLock.withLock {
            let cancelled = cancellationRequested || Task.isCancelled
            stateValue = cancelled ? .cancelling : next
            return cancelled
        }
        if cancelled {
            throw ExportError.cancelled
        }
    }

    func publish(_ transaction: ExportOutputTransaction) throws {
        try stateLock.withLock {
            guard !cancellationRequested, !Task.isCancelled else {
                stateValue = .cancelling
                throw ExportError.cancelled
            }
            try transaction.commit()
            stateValue = .completed
        }
    }

    func setTotalFrames(_ total: Int64) {
        let snapshot = stateLock.withLock {
            totalFramesValue = total
            framesWrittenValue = 0
            return ExportProgress(framesWritten: 0, totalFrames: total)
        }
        onFrameProgress?(snapshot)
    }

    func recordFrameWritten() {
        let snapshot = stateLock.withLock {
            framesWrittenValue += 1
            return ExportProgress(
                framesWritten: framesWrittenValue,
                totalFrames: totalFramesValue
            )
        }
        onFrameProgress?(snapshot)
    }

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
            rows = fallbackSourceSelections(forFrame: index)
        }
        stateLock.withLock {
            sourceSelectionRecordsValue.append(contentsOf: rows)
        }
    }

    private func fallbackSourceSelections(forFrame index: Int64) -> [ExportFrameSourceSelection] {
        var mediaIDs = Set(request.project.mediaPool.map(\.id))
        for track in request.sequence.videoTracks + request.sequence.audioTracks {
            for item in track.items {
                guard case .clip(let clip) = item,
                      case .media(let mediaID) = clip.source
                else {
                    continue
                }
                mediaIDs.insert(mediaID)
            }
        }
        return mediaIDs.sorted { $0.uuidString < $1.uuidString }.map { mediaID in
            ExportFrameSourceSelection(
                frameIndex: index,
                mediaID: mediaID,
                tier: sourceSelectionPolicy.resolvedTier(for: mediaID)
            )
        }
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

    private func mapRunError(_ error: Error) -> ExportError {
        let cancelled = stateLock.withLock { cancellationRequested || Task.isCancelled }
        if cancelled {
            return .cancelled
        }
        return ExportErrorMapper.map(error, destinationURL: request.destinationURL)
    }

    private func setTerminalState(_ state: ExportSessionState) {
        stateLock.withLock {
            stateValue = state
        }
    }
}
