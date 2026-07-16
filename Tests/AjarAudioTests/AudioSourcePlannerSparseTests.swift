// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class AudioSourcePlannerSparseTests: XCTestCase {
    func testSameMediaOneSecondWindowsHoursApartRemainBoundedAndOrdered() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277051")
        let first = try sparseClip(mediaID: mediaID, sourceStart: .zero, timelineStart: .zero)
        let distant = try sparseClip(
            mediaID: mediaID,
            sourceStart: time(3_600, 1),
            timelineStart: .zero
        )
        let sequence = try plannerSequence(tracks: [
            makeTrack(items: [.clip(first)]),
            makeTrack(items: [.clip(distant)])
        ])

        let plan = try AudioSourcePlanner.plan(
            project: plannerProject(sequences: [sequence]),
            sequence: sequence,
            range: plannerRange(.zero, time(1, 1))
        )

        XCTAssertEqual(
            plan.windows(for: mediaID).map(\.range),
            [
                try plannerRange(.zero, time(1, 1)),
                try plannerRange(time(3_600, 1), time(1, 1))
            ]
        )
        XCTAssertEqual(plan.windows.count, 2)
    }

    func testMixerSelectsSparseSameMediaWindowAndPreservesAbsoluteSamples() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277061")
        let first = try sparseClip(mediaID: mediaID, sourceStart: .zero, timelineStart: .zero)
        let distant = try sparseClip(
            mediaID: mediaID,
            sourceStart: time(3_600, 1),
            timelineStart: time(1, 1)
        )
        let sequence = try plannerSequence(tracks: [
            makeTrack(items: [.clip(first), .clip(distant)])
        ])
        let project = try plannerProject(sequences: [sequence], sampleRate: 4)
        let renderRange = try plannerRange(.zero, time(2, 1))
        let plan = try AudioSourcePlanner.plan(
            project: project,
            sequence: sequence,
            range: renderRange
        )
        let buffers = try plan.windows(for: mediaID).map { window in
            let frames = try window.decodingFrameRange(sampleRate: 4)
            return try AudioSourceBuffer(
                format: AudioRenderFormat(sampleRate: 4, channelCount: 1),
                frameCount: frames.count,
                samples: frames.map(Float.init),
                frameOffset: frames.lowerBound
            )
        }
        let provider = SparsePlannerTestSourceProvider(mediaID: mediaID, sources: buffers)

        let rendered = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: renderRange,
            sourceProvider: provider
        )

        XCTAssertEqual(
            rendered.samples,
            [
                0, 0, 1, 1, 2, 2, 3, 3,
                14_400, 14_400, 14_401, 14_401, 14_402, 14_402, 14_403, 14_403
            ]
        )
    }

    private func sparseClip(
        mediaID: UUID,
        sourceStart: RationalTime,
        timelineStart: RationalTime
    ) throws -> Clip {
        try plannerClip(
            source: .media(id: mediaID),
            sourceStart: sourceStart,
            sourceDuration: time(1, 1),
            timelineStart: timelineStart,
            timelineDuration: time(1, 1)
        )
    }
}

private struct SparsePlannerTestSourceProvider: AudioSourceProvider {
    let mediaID: UUID
    let sources: [AudioSourceBuffer]

    func audioSource(for mediaID: UUID) throws -> AudioSourceBuffer {
        throw AudioRenderError.missingAudioSource(mediaID)
    }

    func audioSource(
        for requestedMediaID: UUID,
        covering sourceRange: TimeRange
    ) throws -> AudioSourceBuffer {
        guard requestedMediaID == mediaID else {
            throw AudioRenderError.missingAudioSource(requestedMediaID)
        }
        for source in sources {
            let requestedFrames = try AudioSourceTimeWindow(
                mediaID: mediaID,
                range: sourceRange
            ).decodingFrameRange(sampleRate: source.format.sampleRate)
            let sourceEnd = source.frameOffset + source.frameCount
            if source.frameOffset <= requestedFrames.lowerBound,
                requestedFrames.upperBound <= sourceEnd {
                return source
            }
        }
        throw AudioRenderError.missingAudioSource(requestedMediaID)
    }
}
