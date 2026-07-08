// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// ADR-0015 §5/§6/§3 crossfade pair taxonomy and source-handle validation (FR-AUD-002).
final class AudioCrossfadeValidationTests: XCTestCase {
    // MARK: - Valid pairs (ADR-0015 §5)

    func testFRAUD002ValidLinearCrossfadePairValidates() throws {
        let project = try makeCrossfadePairProject(curve: .linear)

        XCTAssertEqual(project.validate(), .valid)
    }

    func testFRAUD002ValidEqualPowerCrossfadePairValidates() throws {
        let project = try makeCrossfadePairProject(curve: .equalPower)

        XCTAssertEqual(project.validate(), .valid)
    }

    // MARK: - Pair agreement taxonomy (ADR-0015 §5)

    func testFRAUD002OneSidedTrailingCrossfadeIsCrossfadeMirrorMissing() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID)
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadeMirrorMissing(
                    edge: .trailingCrossfade,
                    clipID: outgoingID,
                    partnerClipID: incomingID
                )
            ]
        )
    }

    func testFRAUD002OneSidedLeadingCrossfadeIsCrossfadeMirrorMissing() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID)
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: CrossfadeClipSpec())),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadeMirrorMissing(
                    edge: .leadingCrossfade,
                    clipID: incomingID,
                    partnerClipID: outgoingID
                )
            ]
        )
    }

    func testFRAUD002DurationDisagreementIsCrossfadePairMismatched() throws {
        let project = try makeMismatchedPairProject(
            outgoingDurationFrames: 4,
            incomingDurationFrames: 6
        )

        try assertPairMismatchedBothEdges(project)
    }

    func testFRAUD002CurveDisagreementIsCrossfadePairMismatched() throws {
        let project = try makeMismatchedPairProject(
            outgoingCurve: .linear,
            incomingCurve: .equalPower
        )

        try assertPairMismatchedBothEdges(project)
    }

    func testFRAUD002WrongEdgeRecordIsCrossfadeDirectionInvalid() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        // A *leading* record on the first clip naming the *next* clip sits on the
        // wrong edge for its partner's position (ADR-0015 §5).
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.audioMix = try incomingCrossfadeMix(partner: incomingID)
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadeDirectionInvalid(
                    edge: .leadingCrossfade,
                    clipID: outgoingID,
                    partnerClipID: incomingID
                )
            ]
        )
    }

    func testFRAUD002GapSeparatedPartnersAreCrossfadeSeparatedByGap() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID)
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 14
        incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID)
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .gap(try editRange(startFrame: 10, durationFrames: 4)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadeSeparatedByGap(
                    edge: .trailingCrossfade,
                    clipID: outgoingID,
                    partnerClipID: incomingID
                ),
                .crossfadeSeparatedByGap(
                    edge: .leadingCrossfade,
                    clipID: incomingID,
                    partnerClipID: outgoingID
                )
            ]
        )
    }

    func testFRAUD002StalePartnerIsCrossfadePartnerMissing() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        let staleID = try CrossfadeFixtureID.stalePartner()
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: staleID)
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadePartnerMissing(
                    edge: .trailingCrossfade,
                    clipID: outgoingID,
                    partnerClipID: staleID
                )
            ]
        )
    }

    func testFRAUD002FarPartnerIsCrossfadePartnerNotAdjacent() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let middleID = try CrossfadeFixtureID.incomingClip()
        let farID = try CrossfadeFixtureID.extraClip()
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: farID)
        var middleSpec = CrossfadeClipSpec()
        middleSpec.timelineStartFrame = 10
        var farSpec = CrossfadeClipSpec()
        farSpec.timelineStartFrame = 20
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeCrossfadeClip(id: middleID, spec: middleSpec)),
            .clip(try makeCrossfadeClip(id: farID, spec: farSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadePartnerNotAdjacent(
                    edge: .trailingCrossfade,
                    clipID: outgoingID,
                    partnerClipID: farID
                )
            ]
        )
    }

    // MARK: - Fade × crossfade exclusion (ADR-0015 §6)

    func testFRAUD002FadeOutWithTrailingCrossfadeIsRejected() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID, fadeOutFrames: 2)
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID)
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [.crossfadeConflictsWithFade(edge: .trailingCrossfade, clipID: outgoingID)]
        )
    }

    func testFRAUD002FadeInWithLeadingCrossfadeIsRejected() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID)
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID, fadeInFrames: 2)
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [.crossfadeConflictsWithFade(edge: .leadingCrossfade, clipID: incomingID)]
        )
    }

    // MARK: - Curve contract (ADR-0015 §4)

    func testFRAUD002EaseCurveOnCrossfadeEdgesIsRejected() throws {
        let project = try makeCrossfadePairProject(curve: .easeInOut)
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadeCurveUnsupported(
                    edge: .trailingCrossfade,
                    clipID: outgoingID,
                    curve: .easeInOut
                ),
                .crossfadeCurveUnsupported(
                    edge: .leadingCrossfade,
                    clipID: incomingID,
                    curve: .easeInOut
                )
            ]
        )
    }

    func testFRAUD002EqualPowerCurveHoldsConstantPowerAcrossMirroredPair() {
        let curve = ClipAudioFadeCurve.equalPower

        XCTAssertEqual(curve.value(at: 0), 0, accuracy: 0.000001)
        XCTAssertEqual(curve.value(at: 0.5), 0.7071067811865476, accuracy: 0.000001)
        XCTAssertEqual(curve.value(at: 1), 1, accuracy: 0.000001)
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let gainIn = curve.value(at: fraction)
            let gainOut = curve.value(at: 1 - fraction)
            XCTAssertEqual(gainIn * gainIn + gainOut * gainOut, 1, accuracy: 0.000001)
        }
    }

    // MARK: - Retime interaction (ADR-0015 §2)

    func testFRAUD002TimeRemapClipRejectsCrossfadeEdges() throws {
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        var outgoingSpec = CrossfadeClipSpec()
        outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID)
        outgoingSpec.timeRemap = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(0)),
            TimeRemapKeyframe(time: try editTime(10), sourceTime: try editTime(10))
        ])
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID)
        let project = try makeCrossfadeProject(items: [
            .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [.crossfadeUnsupportedWithTimeRemap(edge: .trailingCrossfade, clipID: outgoingID)]
        )
    }

}

/// ADR-0015 §3/§7 effective-read-window handle validation (FR-AUD-002): the outgoing
/// tail's source-time image must stay within the declared media bounds.
final class AudioCrossfadeHandleValidationTests: XCTestCase {
    func testFRAUD002ForwardTailPastMediaEndIsCrossfadeExceedsSourceHandle() throws {
        // Media is 240 frames; the outgoing tail needs source frames [240, 244).
        let project = try makeHandleProject(outgoingSourceStartFrame: 230)

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadeExceedsSourceHandle(
                    edge: .trailingCrossfade,
                    clipID: try CrossfadeFixtureID.outgoingClip(),
                    mediaID: try CrossfadeFixtureID.media()
                )
            ]
        )
    }

    func testFRAUD002ForwardTailWithinDeclaredMediaValidates() throws {
        // Source ends at frame 230, tail reads [230, 234) inside the 240-frame media.
        let project = try makeHandleProject(outgoingSourceStartFrame: 220)

        XCTAssertEqual(project.validate(), .valid)
    }

    func testFRAUD002ConstantSpeedMultipliesTailSourceWindow() throws {
        // 4 timeline frames at 2x consume 8 source frames: [234, 242) leaves the media.
        let project = try makeHandleProject(
            outgoingSourceStartFrame: 214,
            outgoingSourceDurationFrames: 20,
            outgoingSpeed: RationalValue(2)
        )

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadeExceedsSourceHandle(
                    edge: .trailingCrossfade,
                    clipID: try CrossfadeFixtureID.outgoingClip(),
                    mediaID: try CrossfadeFixtureID.media()
                )
            ]
        )
    }

    func testFRAUD002ReverseTailReadsBackwardPastMediaStart() throws {
        // A reversed tail keeps reading before sourceRange.start: [−2, 2) leaves the media.
        let project = try makeHandleProject(outgoingSourceStartFrame: 2, outgoingReverse: true)

        XCTAssertEqual(
            projectCrossfadeErrors(in: project),
            [
                .crossfadeExceedsSourceHandle(
                    edge: .trailingCrossfade,
                    clipID: try CrossfadeFixtureID.outgoingClip(),
                    mediaID: try CrossfadeFixtureID.media()
                )
            ]
        )
    }

    func testFRAUD002ReverseTailWithEnoughHeadroomValidates() throws {
        // The reversed tail reads [0, 4) exactly down to the media start.
        let project = try makeHandleProject(outgoingSourceStartFrame: 4, outgoingReverse: true)

        XCTAssertEqual(project.validate(), .valid)
    }

    func testFRAUD002FreezeFrameTailNeedsNoExtraMedia() throws {
        // A freeze tail keeps holding its frame even with zero handle at the media end.
        let project = try makeHandleProject(outgoingSourceStartFrame: 230, outgoingFreeze: true)

        XCTAssertEqual(project.validate(), .valid)
    }

    func testFRAUD002HandleArithmeticOverflowIsTimeArithmeticNotHandleShortfall() throws {
        // Computing sourceRange.end() at the 24-timescale overflows Int64 here; the
        // failure must surface as timeArithmetic, never as a misdiagnosed handle shortfall.
        let outgoingID = try CrossfadeFixtureID.outgoingClip()
        let incomingID = try CrossfadeFixtureID.incomingClip()
        let overflowingDuration = try RationalTime(value: Int64.max, timescale: 1)
        let outgoingClip = Clip(
            id: outgoingID,
            source: .media(id: try CrossfadeFixtureID.media()),
            sourceRange: try TimeRange(start: editTime(0), duration: overflowingDuration),
            timelineRange: try editRange(startFrame: 0, durationFrames: 10),
            kind: .audio,
            name: "Overflowing tail",
            audioMix: try outgoingCrossfadeMix(partner: incomingID)
        )
        var incomingSpec = CrossfadeClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID)
        let project = try makeCrossfadeProject(items: [
            .clip(outgoingClip),
            .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
        ])

        let errors = projectCrossfadeErrors(in: project)
        XCTAssertEqual(errors.count, 1)
        guard case .timeArithmetic(let clipID, _) = errors.first else {
            XCTFail("Expected timeArithmetic, got \(errors)")
            return
        }
        XCTAssertEqual(clipID, outgoingID)
    }
}

// MARK: - Private helpers

private func makeMismatchedPairProject(
    outgoingDurationFrames: Int64 = 4,
    incomingDurationFrames: Int64 = 4,
    outgoingCurve: ClipAudioFadeCurve = .linear,
    incomingCurve: ClipAudioFadeCurve = .linear
) throws -> Project {
    let outgoingID = try CrossfadeFixtureID.outgoingClip()
    let incomingID = try CrossfadeFixtureID.incomingClip()
    var outgoingSpec = CrossfadeClipSpec()
    outgoingSpec.audioMix = try outgoingCrossfadeMix(
        partner: incomingID,
        durationFrames: outgoingDurationFrames,
        curve: outgoingCurve
    )
    var incomingSpec = CrossfadeClipSpec()
    incomingSpec.timelineStartFrame = 10
    incomingSpec.audioMix = try incomingCrossfadeMix(
        partner: outgoingID,
        durationFrames: incomingDurationFrames,
        curve: incomingCurve
    )
    return try makeCrossfadeProject(items: [
        .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
        .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
    ])
}

private func assertPairMismatchedBothEdges(
    _ project: Project,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(
        projectCrossfadeErrors(in: project),
        [
            .crossfadePairMismatched(
                edge: .trailingCrossfade,
                clipID: try CrossfadeFixtureID.outgoingClip(),
                partnerClipID: try CrossfadeFixtureID.incomingClip()
            ),
            .crossfadePairMismatched(
                edge: .leadingCrossfade,
                clipID: try CrossfadeFixtureID.incomingClip(),
                partnerClipID: try CrossfadeFixtureID.outgoingClip()
            )
        ],
        file: file,
        line: line
    )
}

private func makeHandleProject(
    outgoingSourceStartFrame: Int64,
    outgoingSourceDurationFrames: Int64 = 10,
    outgoingSpeed: RationalValue = .one,
    outgoingReverse: Bool = false,
    outgoingFreeze: Bool = false
) throws -> Project {
    let outgoingID = try CrossfadeFixtureID.outgoingClip()
    let incomingID = try CrossfadeFixtureID.incomingClip()
    var outgoingSpec = CrossfadeClipSpec()
    outgoingSpec.sourceStartFrame = outgoingSourceStartFrame
    outgoingSpec.sourceDurationFrames = outgoingSourceDurationFrames
    outgoingSpec.speed = outgoingSpeed
    outgoingSpec.reverse = outgoingReverse
    outgoingSpec.freezeFrame = outgoingFreeze
    outgoingSpec.audioMix = try outgoingCrossfadeMix(partner: incomingID)
    var incomingSpec = CrossfadeClipSpec()
    incomingSpec.timelineStartFrame = 10
    incomingSpec.audioMix = try incomingCrossfadeMix(partner: outgoingID)
    return try makeCrossfadeProject(items: [
        .clip(try makeCrossfadeClip(id: outgoingID, spec: outgoingSpec)),
        .clip(try makeCrossfadeClip(id: incomingID, spec: incomingSpec))
    ])
}
