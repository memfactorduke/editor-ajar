// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

/// FR-AUD-007 / FR-CMP-001 realtime playback of compound audio: the callback plan built by
/// `RealtimeAudioRenderPlan.preparingCompoundMix` must agree with the offline render sample-for-
/// sample (exact equality — plan building flattens through the same mixer, so no tolerance is
/// needed) while keeping the render callback lock-free and allocation-free.
final class RealtimeCompoundAudioPlanTests: XCTestCase {
    func testFRAUD007FRCMP001RealtimePlanMatchesOfflineMixForAudioTrackCompound() throws {
        let fixture = try makeAudioTrackCompoundFixture()
        let offline = try offlineMix(fixture)

        let realtime = try realtimeSamples(for: fixture, chunkFrames: 3)

        XCTAssertEqual(offline.samples, [1, 1, 2, 2, 3, 3, 4, 4])
        XCTAssertEqual(realtime, offline.samples)
    }

    func testFRAUD007FRCMP001RealtimePlanMatchesOfflineMixForAudibleVideoTrackCompound() throws {
        let fixture = try makeVideoTrackCompoundFixture()
        let offline = try offlineMix(fixture)

        let realtime = try realtimeSamples(for: fixture, chunkFrames: 4)

        XCTAssertEqual(offline.samples, [3, 3, 3, 3, 3, 3, 3, 3])
        XCTAssertEqual(realtime, offline.samples)
    }

    func testFRAUD007FRCMP001SoloedVisualOnlyCompoundVideoTrackDoesNotSilenceRealtimeMix()
        throws {
        // #156 semantics: a soloed video track whose compound resolves to no audio content
        // never joins the contributor/solo pool, so the audio-track bed keeps playing live.
        let fixture = try makeSoloedVisualOnlyCompoundFixture()
        let offline = try offlineMix(fixture)

        let realtime = try realtimeSamples(for: fixture, chunkFrames: 4)

        XCTAssertEqual(offline.samples, [1, 1, 1, 1, 1, 1, 1, 1])
        XCTAssertEqual(realtime, offline.samples)
    }

    func testFRAUD007FRCMP001RealtimePlanMatchesOfflineMixForNestedCompoundDepthTwo() throws {
        // Video-track compound -> nested sequence holding an audio-track compound -> media.
        let fixture = try makeNestedCompoundDepthTwoFixture()
        let offline = try offlineMix(fixture)

        let realtime = try realtimeSamples(for: fixture, chunkFrames: 2)

        XCTAssertEqual(offline.samples, [1, 1, 2, 2, 3, 3, 4, 4])
        XCTAssertEqual(realtime, offline.samples)
    }

    func testFRAUD002RealtimePlanMatchesOfflineMixForCrossfadedPair() throws {
        // ADR-0015 §9: the realtime plan builder delegates to OfflineAudioMixer.render, so
        // crossfade fade-tail rendering flows into realtime with zero tolerance. The offline
        // expectation is the uncut staircase — a correlated pair under `linear` holds exactly
        // constant amplitude, so the #101 notch cannot reach playback either.
        let fixture = try makeCrossfadedPairFixture()
        let offline = try offlineMix(fixture)

        let realtime = try realtimeSamples(for: fixture, chunkFrames: 3)

        XCTAssertEqual(offline.samples, [1, 1, 2, 2, 3, 3, 4, 4])
        XCTAssertEqual(realtime, offline.samples)
    }

    func testFRAUD007FRCMP001CompoundPlanKeepsCallbackContractLockAndAllocationFree() throws {
        let fixture = try makeVideoTrackCompoundFixture()
        let offline = try offlineMix(fixture)
        let handoff = try RealtimeAudioRenderPlanHandoff()
        try handoff.publish(try makeRealtimePlan(for: fixture))

        let report = try XCTUnwrap(handoff.safetyReport())
        var output = [Float](repeating: -1, count: offline.samples.count)
        let copied = handoff.withCurrentPlan { plan in
            output.withUnsafeMutableBufferPointer { pointer in
                plan.render(into: pointer)
            }
        }

        XCTAssertEqual(report.storageKind, .ownedPointer)
        XCTAssertEqual(report.handoffKind, .lockFreeAtomicSlotRing)
        XCTAssertEqual(report.preparedFrameCount, offline.frameCount)
        XCTAssertFalse(report.usesLocks)
        XCTAssertFalse(report.allocatesDuringRender)
        XCTAssertFalse(report.usesHandoffLocks)
        XCTAssertFalse(report.allocatesDuringAcquire)
        XCTAssertTrue(report.usesCallerOwnedOutput)
        XCTAssertTrue(report.isRealtimeSafe)
        XCTAssertEqual(copied, offline.frameCount)
        XCTAssertEqual(output, offline.samples)
    }

    func testFRAUD007FRCMP001LiveDriverRendersCompoundPlanMatchingOfflineMix() throws {
        let fixture = try makeVideoTrackCompoundFixture()
        let offline = try offlineMix(fixture)
        let driver = try LiveAudioOutputDriver(format: offline.format)
        try driver.publish(try makeRealtimePlan(for: fixture))

        var output = [Float](repeating: -1, count: offline.samples.count)
        let renderedFrames = output.withUnsafeMutableBufferPointer { pointer in
            driver.renderForTesting(into: pointer)
        }

        XCTAssertEqual(renderedFrames, offline.frameCount)
        XCTAssertEqual(output, offline.samples)
    }

    func testFRAUD007FRCMP001ConcurrentCompoundPlanSwapStressKeepsCallbackFramesCoherent()
        throws {
        // Prior review learning: single-threaded green tests are not enough for RT handoff
        // code. This hammers control-side publishes of compound-built plans against a
        // simulated render callback and must run cleanly under Thread Sanitizer.
        let sentinels = (1...8).map(Float.init)
        let plans = try sentinels.map { sentinel in
            try makeRealtimePlan(for: makeStressCompoundFixture(sentinel: sentinel))
        }
        let handoff = try RealtimeAudioRenderPlanHandoff()
        try handoff.publish(plans[0])
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let state = CompoundPlanStressState()

        startCompoundPlanPublisher(
            handoff: handoff,
            plans: plans,
            group: group,
            start: start,
            state: state
        )
        startCompoundPlanObserver(
            handoff: handoff,
            // 0 is legitimate: an exhausted plan zero-fills caller-owned output.
            validSentinels: Set(sentinels).union([0]),
            group: group,
            start: start,
            state: state
        )

        start.signal()
        start.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        let snapshot = state.snapshot()
        XCTAssertTrue(snapshot.failures.isEmpty, snapshot.failures.joined(separator: "\n"))
        XCTAssertGreaterThan(snapshot.observedCount, 0)
    }
}
