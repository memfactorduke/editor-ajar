// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarAudio

final class AudioEngineResidualPolishTests: XCTestCase {
    func testFRAUD003MutedOrDisabledSoloTracksDoNotSelectPlayback() throws {
        let mutedSoloID = try uuid("00000000-0000-0000-0000-000000085301")
        let disabledSoloID = try uuid("00000000-0000-0000-0000-000000085302")
        let renderedID = try uuid("00000000-0000-0000-0000-000000085303")
        let sequence = try makeSequence(tracks: [
            makeTrack(
                items: [.clip(try makeClip(mediaID: mutedSoloID, duration: time(1, 1)))],
                muted: true,
                solo: true
            ),
            makeTrack(
                items: [.clip(try makeClip(mediaID: disabledSoloID, duration: time(1, 1)))],
                enabled: false,
                solo: true
            ),
            makeTrack(items: [.clip(try makeClip(mediaID: renderedID, duration: time(1, 1)))])
        ])
        let buffer = try render(
            sequence: sequence,
            sources: [
                mutedSoloID: try audioSource(samples: [100, 100, 100, 100]),
                disabledSoloID: try audioSource(samples: [200, 200, 200, 200]),
                renderedID: try audioSource(samples: [2, 2, 2, 2])
            ]
        )

        assertSamples(buffer.samples, equal: [2, 2, 2, 2, 2, 2, 2, 2])
    }

    func testFRAUD003FloatMixBusPreservesAboveUnityHeadroom() throws {
        let firstID = try uuid("00000000-0000-0000-0000-000000085304")
        let secondID = try uuid("00000000-0000-0000-0000-000000085305")
        let sequence = try makeSequence(tracks: [
            makeTrack(items: [.clip(try makeClip(mediaID: firstID, duration: time(1, 1)))]),
            makeTrack(items: [.clip(try makeClip(mediaID: secondID, duration: time(1, 1)))])
        ])
        let buffer = try render(
            sequence: sequence,
            sources: [
                firstID: try audioSource(samples: [1, 1, 1, 1]),
                secondID: try audioSource(samples: [1, 1, 1, 1])
            ]
        )

        assertSamples(buffer.samples, equal: [2, 2, 2, 2, 2, 2, 2, 2])
    }

    func testFRAUD007RealtimeSafetyReportReflectsStorageKindContract() {
        let owned = RealtimeAudioSafetyReport(
            preparedFrameCount: 2,
            storageKind: .ownedPointer
        )
        let locking = RealtimeAudioSafetyReport(
            preparedFrameCount: 2,
            storageKind: .lockedSharedBuffer
        )
        let allocating = RealtimeAudioSafetyReport(
            preparedFrameCount: 2,
            storageKind: .allocatingCallbackBuffer
        )
        let lockedHandoff = RealtimeAudioSafetyReport(
            preparedFrameCount: 2,
            storageKind: .ownedPointer,
            handoffKind: .lockedSharedSlot
        )
        let allocatingAcquire = RealtimeAudioSafetyReport(
            preparedFrameCount: 2,
            storageKind: .ownedPointer,
            handoffKind: .allocatingAcquire
        )

        XCTAssertFalse(owned.usesLocks)
        XCTAssertFalse(owned.allocatesDuringRender)
        XCTAssertEqual(owned.handoffKind, .none)
        XCTAssertFalse(owned.usesHandoffLocks)
        XCTAssertFalse(owned.allocatesDuringAcquire)
        XCTAssertTrue(owned.isRealtimeSafe)
        XCTAssertTrue(locking.usesLocks)
        XCTAssertFalse(locking.allocatesDuringRender)
        XCTAssertFalse(locking.isRealtimeSafe)
        XCTAssertFalse(allocating.usesLocks)
        XCTAssertTrue(allocating.allocatesDuringRender)
        XCTAssertFalse(allocating.isRealtimeSafe)
        XCTAssertTrue(lockedHandoff.usesHandoffLocks)
        XCTAssertFalse(lockedHandoff.allocatesDuringAcquire)
        XCTAssertFalse(lockedHandoff.isRealtimeSafe)
        XCTAssertFalse(allocatingAcquire.usesHandoffLocks)
        XCTAssertTrue(allocatingAcquire.allocatesDuringAcquire)
        XCTAssertFalse(allocatingAcquire.isRealtimeSafe)
    }

    func testFRAUD007RealtimePlanHandoffPublishesAndAcquiresCurrentPlan() throws {
        let handoff = try RealtimeAudioRenderPlanHandoff()
        XCTAssertNil(handoff.withCurrentPlan { plan in
            plan.safetyReport()
        })

        try handoff.publish(try realtimePlan(samples: [1, 2, 3, 4]))
        var firstOutput = [Float](repeating: -1, count: 4)
        let firstCopied = handoff.withCurrentPlan { plan in
            firstOutput.withUnsafeMutableBufferPointer { output in
                plan.render(into: output)
            }
        }

        try handoff.publish(try realtimePlan(samples: [5, 6, 7, 8]))
        var secondOutput = [Float](repeating: -1, count: 4)
        let secondCopied = handoff.withCurrentPlan { plan in
            secondOutput.withUnsafeMutableBufferPointer { output in
                plan.render(into: output)
            }
        }

        XCTAssertEqual(firstCopied, 2)
        XCTAssertEqual(firstOutput, [1, 2, 3, 4])
        XCTAssertEqual(secondCopied, 2)
        XCTAssertEqual(secondOutput, [5, 6, 7, 8])
    }

    func testFRAUD007RealtimePlanHandoffKeepsActivePlanStableDuringInterleavedPublish()
        throws {
        let handoff = try RealtimeAudioRenderPlanHandoff()
        try handoff.publish(try realtimePlan(samples: [1, 1, 1, 1]))
        let secondPlan = try realtimePlan(samples: [2, 2, 2, 2])
        let thirdPlan = try realtimePlan(samples: [3, 3, 3, 3])

        var activeOutput = [Float](repeating: -1, count: 4)
        let activeCopied = handoff.withCurrentPlan { plan in
            XCTAssertTrue((try? handoff.publish(secondPlan)) != nil)
            XCTAssertTrue((try? handoff.publish(thirdPlan)) != nil)
            return activeOutput.withUnsafeMutableBufferPointer { output in
                plan.render(into: output)
            }
        }

        var latestOutput = [Float](repeating: -1, count: 4)
        let latestCopied = handoff.withCurrentPlan { plan in
            latestOutput.withUnsafeMutableBufferPointer { output in
                plan.render(into: output)
            }
        }

        XCTAssertEqual(activeCopied, 2)
        XCTAssertEqual(activeOutput, [1, 1, 1, 1])
        XCTAssertEqual(latestCopied, 2)
        XCTAssertEqual(latestOutput, [3, 3, 3, 3])
    }

    func testFRAUD007ConcurrentPublishAcquireNeverYieldsTornPlan() throws {
        let handoff = try RealtimeAudioRenderPlanHandoff()
        try handoff.publish(try realtimePlan(repeating: 1))
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let state = ConcurrentPlanHandoffRaceState()

        startConcurrentPlanPublisher(handoff: handoff, group: group, start: start, state: state)
        startConcurrentPlanObserver(
            handoff: handoff,
            validSentinels: Set((1...97).map(Float.init)),
            group: group,
            start: start,
            state: state
        )

        start.signal()
        start.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let snapshot = state.snapshot()
        XCTAssertTrue(snapshot.failures.isEmpty, snapshot.failures.joined(separator: "\n"))
        XCTAssertGreaterThan(snapshot.observedCount, 0)
    }

    func testFRAUD007RealtimePlanHandoffSafetyReportDeclaresLockFreeAcquireContract()
        throws {
        let handoff = try RealtimeAudioRenderPlanHandoff()
        try handoff.publish(try realtimePlan(samples: [1, 2, 3, 4]))

        let report = try XCTUnwrap(handoff.safetyReport())

        XCTAssertEqual(report.storageKind, .ownedPointer)
        XCTAssertEqual(report.handoffKind, .lockFreeAtomicSlotRing)
        XCTAssertFalse(report.usesLocks)
        XCTAssertFalse(report.allocatesDuringRender)
        XCTAssertFalse(report.usesHandoffLocks)
        XCTAssertFalse(report.allocatesDuringAcquire)
        XCTAssertTrue(report.usesCallerOwnedOutput)
        XCTAssertTrue(report.isRealtimeSafe)
    }
}

private func realtimePlan(samples: [Float]) throws -> RealtimeAudioRenderPlan {
    RealtimeAudioRenderPlan(
        buffer: try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
            frameCount: samples.count / 2,
            samples: samples
        )
    )
}

private func realtimePlan(repeating sample: Float) throws -> RealtimeAudioRenderPlan {
    try realtimePlan(samples: [Float](repeating: sample, count: 8_192))
}

private func startConcurrentPlanPublisher(
    handoff: RealtimeAudioRenderPlanHandoff,
    group: DispatchGroup,
    start: DispatchSemaphore,
    state: ConcurrentPlanHandoffRaceState
) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            state.markPublisherDone()
            group.leave()
        }
        start.wait()
        for iteration in 0..<2_000 {
            let sentinel = Float((iteration % 97) + 1)
            do {
                try handoff.publish(try realtimePlan(repeating: sentinel))
            } catch {
                state.appendFailure("publish failed: \(error)")
                return
            }
        }
    }
}

private func startConcurrentPlanObserver(
    handoff: RealtimeAudioRenderPlanHandoff,
    validSentinels: Set<Float>,
    group: DispatchGroup,
    start: DispatchSemaphore,
    state: ConcurrentPlanHandoffRaceState
) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer { group.leave() }
        start.wait()
        while !state.isPublisherDone {
            guard let output = renderTwoSamples(from: handoff) else {
                continue
            }
            state.incrementObservedCount()

            if output[0] != output[1] || !validSentinels.contains(output[0]) {
                state.appendFailure("torn or unknown frame: \(output)")
                return
            }
        }
    }
}

private func renderTwoSamples(from handoff: RealtimeAudioRenderPlanHandoff) -> [Float]? {
    var output = [Float](repeating: -1, count: 2)
    let copied = handoff.withCurrentPlan { plan in
        output.withUnsafeMutableBufferPointer { pointer in
            plan.render(into: pointer)
        }
    }
    guard copied != nil else {
        return nil
    }
    return output
}

private final class ConcurrentPlanHandoffRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var publisherDone = false
    private var observedCount = 0
    private var failures: [String] = []

    var isPublisherDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return publisherDone
    }

    func markPublisherDone() {
        lock.lock()
        publisherDone = true
        lock.unlock()
    }

    func incrementObservedCount() {
        lock.lock()
        observedCount += 1
        lock.unlock()
    }

    func appendFailure(_ message: String) {
        lock.lock()
        failures.append(message)
        lock.unlock()
    }

    func snapshot() -> (failures: [String], observedCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (failures, observedCount)
    }
}
