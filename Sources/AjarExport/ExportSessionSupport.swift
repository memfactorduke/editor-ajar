// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreMedia
import Foundation

extension ExportSession {
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
    /// Media-pool ids plus media-backed clip sources are audited so title-only timelines with an
    /// audio media ref still leave a non-empty trail. Proxy adapters (#217) must keep resolving
    /// `.original` here even when playback is in proxy mode.
    func recordSourceSelections(forFrame index: Int64) {
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
        let rows = mediaIDs.sorted { $0.uuidString < $1.uuidString }.map { mediaID in
            ExportFrameSourceSelection(
                frameIndex: index,
                mediaID: mediaID,
                tier: sourceSelectionPolicy.resolvedTier(for: mediaID)
            )
        }
        stateLock.lock()
        sourceSelectionRecordsValue.append(contentsOf: rows)
        stateLock.unlock()
    }
}
