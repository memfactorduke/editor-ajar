// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreVideo
import Foundation
import XCTest

@testable import AjarExport

/// Slow / controllable frame provider for queue isolation and cancel tests.
final class ControllableFrameProvider: ExportVideoFrameProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var rendered = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var releaseCount = 0
    private let holdUntilRelease: Bool
    private let sleepNanoseconds: UInt64
    private let onRender: ((Int, RationalTime) -> Void)?

    private(set) var lastTimelineTimes: [RationalTime] = []

    init(
        holdUntilRelease: Bool = false,
        sleepNanoseconds: UInt64 = 0,
        onRender: ((Int, RationalTime) -> Void)? = nil
    ) {
        self.holdUntilRelease = holdUntilRelease
        self.sleepNanoseconds = sleepNanoseconds
        self.onRender = onRender
    }

    var renderedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rendered
    }

    func releaseOneFrame() {
        lock.lock()
        releaseCount += 1
        let continuation = gate
        gate = nil
        lock.unlock()
        continuation?.resume()
    }

    func releaseAll() {
        lock.lock()
        releaseCount = .max
        let continuation = gate
        gate = nil
        lock.unlock()
        continuation?.resume()
    }

    func renderFrame(
        at timelineTime: RationalTime,
        into _: CVPixelBuffer
    ) async throws {
        if sleepNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        if holdUntilRelease {
            try await renderHeldFrame(timelineTime: timelineTime)
        } else {
            noteRendered(timelineTime: timelineTime)
        }
    }

    private func renderHeldFrame(timelineTime: RationalTime) async throws {
        while true {
            if tryTakeReleaseToken() {
                noteRendered(timelineTime: timelineTime)
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if releaseCount > 0 {
                    lock.unlock()
                    continuation.resume()
                } else {
                    gate = continuation
                    lock.unlock()
                }
            }
            try Task.checkCancellation()
        }
    }

    private func tryTakeReleaseToken() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard releaseCount > 0 else {
            return false
        }
        if releaseCount != .max {
            releaseCount -= 1
        }
        return true
    }

    private func noteRendered(timelineTime: RationalTime) {
        lock.lock()
        rendered += 1
        lastTimelineTimes.append(timelineTime)
        let count = rendered
        lock.unlock()
        onRender?(count, timelineTime)
    }
}

enum ExportQueueFixtures {
    static func makeRequest(
        destinationURL: URL,
        frameCount: Int64,
        sequenceName: String = "Queue",
        destinationCollisionPolicy: ExportDestinationCollisionPolicy = .replaceExisting,
        projectMutator: ((inout Project) -> Void)? = nil
    ) throws -> ExportRequest {
        let frameRate = try FrameRate(frames: 30)
        let duration = try frameRate.duration(ofFrames: frameCount)
        let range = try TimeRange(start: .zero, duration: duration)
        let sequenceID = UUID()
        let sequence = Sequence(
            id: sequenceID,
            name: sequenceName,
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(range)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        var project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 64, height: 64),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: [sequence]
        )
        projectMutator?(&project)
        let settings = try ExportSettings(
            container: .mp4,
            video: ExportVideoSettings(
                codec: .h264,
                resolution: PixelDimensions(width: 64, height: 64),
                frameRate: frameRate,
                averageBitRate: 500_000,
                colorSpace: .rec709
            ),
            audio: nil
        )
        return try ExportRequest(
            project: project,
            sequenceID: sequenceID,
            range: range,
            destinationURL: destinationURL,
            settings: settings,
            destinationCollisionPolicy: destinationCollisionPolicy
        )
    }

    static func waitUntil(
        timeout: TimeInterval = 2,
        pollNanoseconds: UInt64 = 5_000_000,
        predicate: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64(timeout * 1_000))
        )
        while ContinuousClock.now < deadline {
            if await predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return await predicate()
    }
}
