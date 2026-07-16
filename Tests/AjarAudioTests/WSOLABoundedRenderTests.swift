// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarAudio

final class WSOLABoundedRenderTests: XCTestCase {
    func testFRSPD001OverBudgetClipRefusesBeforeAllocatingWholeSourceExtraction() throws {
        let rate = 1_000
        let sourceFrames = 2_000_000
        let mediaID = try uuid("00000000-0000-0000-0000-000000086020")
        let clipID = try uuid("00000000-0000-0000-0000-000000086021")
        let speed = try RationalValue(numerator: 1, denominator: 2)
        let clip = try makeRetimedClip(
            id: clipID,
            mediaID: mediaID,
            speed: speed,
            retimeMode: .pitchCorrected,
            sourceDurationFrames: sourceFrames,
            sampleRate: rate
        )
        let sequence = try pitchCorrectionSequence(clip: clip)

        // The provider deliberately owns only one frame. The authoritative working-set check
        // uses the requested source bounds and actual mono/1 kHz format, then fails before
        // `extractedWindowSamples` attempts its 2,000,000-frame allocation.
        XCTAssertThrowsError(
            try OfflineAudioMixer.render(
                sequence: sequence,
                range: TimeRange(start: .zero, duration: time(1, Int64(rate))),
                format: AudioRenderFormat(sampleRate: rate, channelCount: 2),
                sourceProvider: InMemoryAudioSourceProvider(sources: [
                    mediaID: try monoSource([0], sampleRate: rate)
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .pitchCorrectedStretchFailed(
                    clipID: clipID,
                    error: .workingSetLimitExceeded(
                        estimatedByteCount: 104_000_480,
                        maximumByteCount: WSOLATimeStretcher.maximumWorkingSetByteCount
                    )
                )
            )
        }
    }

    func testFRSPD001MixerCancellationInterruptsWSOLASimilaritySearch() throws {
        let rate = 48_000
        let mediaID = try uuid("00000000-0000-0000-0000-000000086022")
        let clip = try makeRetimedClip(
            id: try uuid("00000000-0000-0000-0000-000000086023"),
            mediaID: mediaID,
            speed: try RationalValue(numerator: 2, denominator: 1),
            retimeMode: .pitchCorrected,
            sourceDurationFrames: rate,
            sampleRate: rate
        )
        let sequence = try pitchCorrectionSequence(clip: clip)
        let project = try plannerProject(sequences: [sequence], sampleRate: rate)
        let provider = InMemoryAudioSourceProvider(sources: [
            mediaID: try monoSource(
                makeTestSignal(frameCount: rate, channelCount: 1),
                sampleRate: rate
            )
        ])
        // Poll 102 is the first lag candidate of segment 1 after bounded extraction,
        // mono-downmix, and segment 0. Reaching it proves the mixer forwards its caller-owned
        // cancellation hook into WSOLA's similarity search rather than waiting for stretching
        // to finish.
        let probe = PitchCorrectionCancellationProbe(cancelAtPoll: 102)
        var continuation = OfflineAudioRenderContinuation()

        XCTAssertThrowsError(
            try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: TimeRange(start: .zero, duration: time(1, Int64(rate))),
                format: AudioRenderFormat(sampleRate: rate, channelCount: 2),
                sourceProvider: provider,
                continuation: &continuation,
                cancellationCheck: { try probe.poll() }
            )
        ) { error in
            XCTAssertTrue(error is PitchCorrectionCancellationProbe.Cancelled)
        }
        XCTAssertEqual(probe.pollCount, 102)
    }

    private func pitchCorrectionSequence(clip: Clip) throws -> Sequence {
        Sequence(
            id: try uuid("00000000-0000-0000-0000-000000086024"),
            name: "Bounded pitch correction",
            videoTracks: [],
            audioTracks: [try makeTrack(items: [.clip(clip)])],
            markers: [],
            timebase: try FrameRate(frames: 30)
        )
    }
}

private final class PitchCorrectionCancellationProbe: @unchecked Sendable {
    struct Cancelled: Error {}

    private let lock = NSLock()
    private let cancelAtPoll: Int
    private var count = 0

    init(cancelAtPoll: Int) {
        self.cancelAtPoll = cancelAtPoll
    }

    var pollCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func poll() throws {
        lock.lock()
        count += 1
        let shouldCancel = count >= cancelAtPoll
        lock.unlock()
        if shouldCancel {
            throw Cancelled()
        }
    }
}
