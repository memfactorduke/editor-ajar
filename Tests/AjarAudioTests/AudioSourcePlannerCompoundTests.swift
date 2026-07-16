// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class AudioSourcePlannerCompoundTests: XCTestCase {
    func testAudibleVideoTrackCompoundUsesTheMixerContributorRules() throws {
        let fixture = try makeVideoTrackCompoundFixture()

        let plan = try AudioSourcePlanner.plan(
            project: fixture.project,
            sequence: fixture.sequence,
            range: fixture.range
        )

        XCTAssertEqual(Set(plan.windows.map(\.mediaID)), Set(fixture.sources.keys))
    }

    func testNestedCompoundUsesPartialPaddedWindowAndNativeMediaAddressing() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277101")
        let nestedID = try uuid("00000000-0000-0000-0000-000000277102")
        let parentID = try uuid("00000000-0000-0000-0000-000000277103")
        let nestedMediaClip = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: time(100, 1),
            sourceDuration: time(200, 1),
            timelineStart: .zero,
            timelineDuration: time(200, 1)
        )
        let nested = try plannerSequence(
            id: nestedID,
            tracks: [makeTrack(items: [.clip(nestedMediaClip)])]
        )
        let compound = try plannerClip(
            source: .sequence(id: nestedID),
            sourceStart: time(20, 1),
            sourceDuration: time(100, 1),
            timelineStart: .zero,
            timelineDuration: time(100, 1)
        )
        let parent = try plannerSequence(
            id: parentID,
            tracks: [makeTrack(items: [.clip(compound)])]
        )
        let project = try plannerProject(sequences: [parent, nested], sampleRate: 100)

        let plan = try AudioSourcePlanner.plan(
            project: project,
            sequence: parent,
            range: plannerRange(time(10, 1), time(2, 1))
        )

        let window = try XCTUnwrap(plan.window(for: mediaID))
        XCTAssertEqual(window.range, try plannerRange(time(6_499, 50), time(203, 100)))
        XCTAssertEqual(try window.decodingFrameRange(sampleRate: 44_100), 5_732_116..<5_821_642)

        let nativeFrames = try window.decodingFrameRange(sampleRate: 100)
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 100, channelCount: 1),
            frameCount: nativeFrames.count,
            samples: [Float](repeating: 1, count: nativeFrames.count),
            frameOffset: nativeFrames.lowerBound
        )
        let rendered = try OfflineAudioMixer.render(
            project: project,
            sequence: parent,
            range: plannerRange(time(10, 1), time(2, 1)),
            sourceProvider: InMemoryAudioSourceProvider(sources: [mediaID: source])
        )
        XCTAssertEqual(rendered.samples, [Float](repeating: 1, count: 400))
    }

    func testNestedCompoundPaddingUses48kOutputRateIn44k1Project() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277104")
        let nestedID = try uuid("00000000-0000-0000-0000-000000277105")
        let nestedClip = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: .zero,
            sourceDuration: time(1, 1),
            timelineStart: .zero,
            timelineDuration: time(1, 1)
        )
        let nested = try plannerSequence(
            id: nestedID,
            tracks: [makeTrack(items: [.clip(nestedClip)])]
        )
        let compound = try plannerClip(
            source: .sequence(id: nestedID),
            sourceStart: .zero,
            sourceDuration: time(1, 1),
            timelineStart: .zero,
            timelineDuration: time(1, 1)
        )
        let parent = try plannerSequence(tracks: [makeTrack(items: [.clip(compound)])])
        let project = try plannerProject(sequences: [parent, nested], sampleRate: 44_100)
        let oneOutputFrame = try time(1, 48_000)

        let plan = try AudioSourcePlanner.plan(
            project: project,
            sequence: parent,
            range: plannerRange(oneOutputFrame, oneOutputFrame),
            outputSampleRate: 48_000
        )

        // The compound guard window is frames 0..<3 at the actual 48 kHz mix rate. Using the
        // 44.1 kHz project rate here would incorrectly request 3/44,100 seconds instead.
        XCTAssertEqual(
            plan.window(for: mediaID)?.range,
            try plannerRange(.zero, time(3, 48_000))
        )
    }

    func testMutedAndNonSoloTracksDoNotEnterPlan() throws {
        let normalID = try uuid("00000000-0000-0000-0000-000000277111")
        let mutedID = try uuid("00000000-0000-0000-0000-000000277112")
        let soloID = try uuid("00000000-0000-0000-0000-000000277113")
        let clip: (UUID) throws -> Clip = { mediaID in
            try plannerClip(
                source: .media(id: mediaID),
                sourceStart: .zero,
                sourceDuration: time(1, 1),
                timelineStart: .zero,
                timelineDuration: time(1, 1)
            )
        }
        let sequence = try plannerSequence(tracks: [
            makeTrack(items: [.clip(clip(normalID))]),
            makeTrack(items: [.clip(clip(mutedID))], muted: true),
            makeTrack(items: [.clip(clip(soloID))], solo: true)
        ])

        let plan = try AudioSourcePlanner.plan(
            project: plannerProject(sequences: [sequence]),
            sequence: sequence,
            range: plannerRange(.zero, time(1, 1))
        )

        XCTAssertNil(plan.window(for: normalID))
        XCTAssertNil(plan.window(for: mutedID))
        XCTAssertNotNil(plan.window(for: soloID))
    }

    func testPaddedFrameRangeClampsAtZeroAndRejectsInvalidRate() throws {
        let window = AudioSourceTimeWindow(
            mediaID: UUID(),
            range: try plannerRange(.zero, time(1, 44_100))
        )

        XCTAssertEqual(try window.decodingFrameRange(sampleRate: 44_100), 0..<2)
        XCTAssertThrowsError(try window.decodingFrameRange(sampleRate: 0)) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .invalidFormat(sampleRate: 0, channelCount: 1, frameCount: 0)
            )
        }
    }
}
