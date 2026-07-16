// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class AudioSourcePlannerTests: XCTestCase {
    func testLongUnitRateClipPlansOnlyRenderIntersectionAtNativeSourceRate() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277001")
        let clip = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: time(100, 1),
            sourceDuration: time(3_600, 1),
            timelineStart: .zero,
            timelineDuration: time(3_600, 1)
        )

        let plan = try plannerPlan(
            clip: clip,
            range: plannerRange(time(10, 1), time(2, 1))
        )

        let window = try XCTUnwrap(plan.window(for: mediaID))
        XCTAssertEqual(window.range, try plannerRange(time(110, 1), time(2, 1)))
        XCTAssertEqual(try window.decodingFrameRange(sampleRate: 44_100), 4_850_998..<4_939_201)
    }

    func testNativeRatePartialBufferKeepsAbsoluteAddressingInDifferentRateProject() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277002")
        let clip = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: time(10, 1),
            sourceDuration: time(20, 1),
            timelineStart: .zero,
            timelineDuration: time(20, 1)
        )
        let sequence = try plannerSequence(tracks: [makeTrack(items: [.clip(clip)])])
        let project = try plannerProject(sequences: [sequence], sampleRate: 4)
        let range = try plannerRange(time(1, 1), time(1, 1))
        let plan = try AudioSourcePlanner.plan(project: project, sequence: sequence, range: range)
        let nativeFrames = try XCTUnwrap(plan.window(for: mediaID))
            .decodingFrameRange(sampleRate: 8)
        let source = try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: 8, channelCount: 1),
            frameCount: nativeFrames.count,
            samples: nativeFrames.map(Float.init),
            frameOffset: nativeFrames.lowerBound
        )

        let rendered = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: range,
            sourceProvider: InMemoryAudioSourceProvider(sources: [mediaID: source])
        )

        XCTAssertEqual(nativeFrames, 86..<97)
        XCTAssertEqual(rendered.samples, [88, 88, 90, 90, 92, 92, 94, 94])
    }

    func testOffRangeClipIsAbsentAndDoesNotAcquireMixerOrDuckingSource() throws {
        let targetID = try uuid("00000000-0000-0000-0000-000000277011")
        let offRangeID = try uuid("00000000-0000-0000-0000-000000277012")
        let triggerTrackID = try uuid("00000000-0000-0000-0000-000000277013")
        let targetTrackID = try uuid("00000000-0000-0000-0000-000000277014")
        let offRange = try plannerClip(
            source: .media(id: offRangeID),
            sourceStart: .zero,
            sourceDuration: time(1, 1),
            timelineStart: time(10, 1),
            timelineDuration: time(1, 1)
        )
        let target = try makeClip(mediaID: targetID, duration: time(1, 1))
        let triggerTrack = try makeTrack(id: triggerTrackID, items: [.clip(offRange)])
        let targetTrack = try makeTrack(id: targetTrackID, items: [.clip(target)])
        let rule = AudioDuckingRule(
            triggerTrackID: triggerTrackID,
            targetTrackIDs: [targetTrackID],
            threshold: .zero,
            reductionGain: .zero,
            attack: .zero,
            release: .zero
        )
        let sequence = try plannerSequence(
            tracks: [triggerTrack, targetTrack],
            ducking: [rule]
        )
        let range = try plannerRange(.zero, time(1, 1))
        let project = try plannerProject(sequences: [sequence], sampleRate: 4)

        let plan = try AudioSourcePlanner.plan(project: project, sequence: sequence, range: range)
        let rendered = try OfflineAudioMixer.render(
            project: project,
            sequence: sequence,
            range: range,
            sourceProvider: InMemoryAudioSourceProvider(
                sources: [targetID: try audioSource(samples: [1, 1, 1, 1])]
            )
        )

        XCTAssertNil(plan.window(for: offRangeID))
        XCTAssertNotNil(plan.window(for: targetID))
        XCTAssertEqual(rendered.samples, [1, 1, 1, 1, 1, 1, 1, 1])
    }

    func testConstantSpeedReverseAndFreezeMapExactIntersectionEndpoints() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277021")
        let twoX = try RationalValue(numerator: 2, denominator: 1)
        let renderRange = try plannerRange(time(2, 1), time(1, 1))
        let forward = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: time(10, 1),
            sourceDuration: time(20, 1),
            timelineStart: .zero,
            timelineDuration: time(10, 1),
            speed: twoX
        )
        let reverse = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: time(10, 1),
            sourceDuration: time(20, 1),
            timelineStart: .zero,
            timelineDuration: time(10, 1),
            speed: twoX,
            reverse: true
        )
        let freeze = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: time(7, 1),
            sourceDuration: time(10, 1),
            timelineStart: .zero,
            timelineDuration: time(10, 1),
            freezeFrame: true
        )

        XCTAssertEqual(
            try plannerPlan(clip: forward, range: renderRange).windows.first?.range,
            try plannerRange(time(14, 1), time(2, 1))
        )
        XCTAssertEqual(
            try plannerPlan(clip: reverse, range: renderRange).windows.first?.range,
            try plannerRange(time(24, 1), time(2, 1))
        )
        XCTAssertEqual(
            try plannerPlan(clip: freeze, range: renderRange).windows.first?.range,
            try plannerRange(time(7, 1), .zero)
        )
    }

    func testMonotonicTimeRemapIsIntersectionBoundedButPitchCorrectionUsesFullWindow() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277031")
        let curve = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: .zero, sourceTime: time(5, 1)),
            TimeRemapKeyframe(time: time(2, 1), sourceTime: time(6, 1)),
            TimeRemapKeyframe(time: time(4, 1), sourceTime: time(10, 1))
        ])
        let remapped = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: time(5, 1),
            sourceDuration: time(5, 1),
            timelineStart: .zero,
            timelineDuration: time(4, 1),
            timeRemap: curve
        )
        let pitchCorrected = try plannerClip(
            source: .media(id: mediaID),
            sourceStart: time(10, 1),
            sourceDuration: time(20, 1),
            timelineStart: .zero,
            timelineDuration: time(10, 1),
            audioMix: ClipAudioMix(retimeMode: .pitchCorrected),
            speed: RationalValue(numerator: 2, denominator: 1)
        )

        XCTAssertEqual(
            try plannerPlan(
                clip: remapped,
                range: plannerRange(time(1, 1), time(2, 1))
            ).windows.first?.range,
            try plannerRange(time(11, 2), time(5, 2))
        )
        XCTAssertEqual(
            try plannerPlan(
                clip: pitchCorrected,
                range: plannerRange(time(2, 1), time(1, 1))
            ).windows.first?.range,
            try plannerRange(time(10, 1), time(20, 1))
        )
    }

    func testPitchCorrectedWholeWindowOverBudgetFailsDuringPlanningBeforeDecode() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000277032")
        let clipID = try uuid("00000000-0000-0000-0000-000000277033")
        let speed = try RationalValue(numerator: 1, denominator: 2)
        let clip = try plannerClip(
            id: clipID,
            source: .media(id: mediaID),
            sourceStart: .zero,
            sourceDuration: time(2_000, 1),
            timelineStart: .zero,
            timelineDuration: time(4_000, 1),
            audioMix: ClipAudioMix(retimeMode: .pitchCorrected),
            speed: speed
        )

        XCTAssertThrowsError(
            try plannerPlan(
                clip: clip,
                range: plannerRange(.zero, time(1, 1)),
                sampleRate: 1_000
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .pitchCorrectedStretchFailed(
                    clipID: clipID,
                    error: .workingSetLimitExceeded(
                        estimatedByteCount: 160_000_640,
                        maximumByteCount: WSOLATimeStretcher.maximumWorkingSetByteCount
                    )
                )
            )
        }
    }

    // swiftlint:disable:next function_body_length
    func testCrossfadeTailUsesTailMappingAndSameMediaKeepsDisjointWindowsSparse() throws {
        let outgoingMediaID = try uuid("00000000-0000-0000-0000-000000277041")
        let incomingMediaID = try uuid("00000000-0000-0000-0000-000000277042")
        let outgoingClipID = try uuid("00000000-0000-0000-0000-000000277043")
        let incomingClipID = try uuid("00000000-0000-0000-0000-000000277044")
        let crossfade = try time(2, 1)
        let outgoing = try plannerClip(
            id: outgoingClipID,
            source: .media(id: outgoingMediaID),
            sourceStart: .zero,
            sourceDuration: time(5, 1),
            timelineStart: .zero,
            timelineDuration: time(5, 1),
            audioMix: ClipAudioMix(
                trailingCrossfade: ClipAudioCrossfade(
                    partnerClipID: incomingClipID,
                    duration: crossfade,
                    curve: .linear
                )
            )
        )
        let incoming = try plannerClip(
            id: incomingClipID,
            source: .media(id: incomingMediaID),
            sourceStart: .zero,
            sourceDuration: time(5, 1),
            timelineStart: time(5, 1),
            timelineDuration: time(5, 1),
            audioMix: ClipAudioMix(
                leadingCrossfade: ClipAudioCrossfade(
                    partnerClipID: outgoingClipID,
                    duration: crossfade,
                    curve: .linear
                )
            )
        )
        let hullClip = try plannerClip(
            source: .media(id: incomingMediaID),
            sourceStart: time(20, 1),
            sourceDuration: time(5, 1),
            timelineStart: time(5, 1),
            timelineDuration: time(5, 1)
        )
        let sequence = try plannerSequence(tracks: [
            makeTrack(items: [.clip(outgoing), .clip(incoming)]),
            makeTrack(items: [.clip(hullClip)])
        ])
        let plan = try AudioSourcePlanner.plan(
            project: plannerProject(sequences: [sequence]),
            sequence: sequence,
            range: plannerRange(time(11, 2), time(1, 2))
        )

        XCTAssertEqual(
            plan.window(for: outgoingMediaID)?.range,
            try plannerRange(time(11, 2), time(1, 2))
        )
        XCTAssertEqual(
            plan.windows(for: incomingMediaID).map(\.range),
            [
                try plannerRange(time(1, 2), time(1, 2)),
                try plannerRange(time(41, 2), time(1, 2))
            ]
        )
        XCTAssertNil(plan.window(for: incomingMediaID), "sparse media has no single safe window")
    }

}
