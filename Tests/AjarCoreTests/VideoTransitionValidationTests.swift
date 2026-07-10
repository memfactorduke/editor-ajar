// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// FR-FX-001 / ADR-0016 §5 pair-agreement and handle-clamp validation.
final class VideoTransitionValidationTests: XCTestCase {
    func testFRFX001ValidPairHasNoErrors() throws {
        let project = try makeVideoTransitionPairProject()
        XCTAssertTrue(projectVideoTransitionErrors(in: project).isEmpty)
        XCTAssertEqual(project.validate(), .valid)
    }

    func testFRFX001MirrorMissingIsRejected() throws {
        let outgoingID = try VideoTransitionFixtureID.outgoingClip()
        let incomingID = try VideoTransitionFixtureID.incomingClip()
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.trailingTransition = try makeTrailingTransition(partner: incomingID)
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        // No leading mirror.
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let errors = projectVideoTransitionErrors(in: project)
        XCTAssertTrue(
            errors.contains {
                if case .transitionMirrorMissing = $0 { return true }
                return false
            }
        )
    }

    func testFRFX001PairMismatchedKindIsRejected() throws {
        let outgoingID = try VideoTransitionFixtureID.outgoingClip()
        let incomingID = try VideoTransitionFixtureID.incomingClip()
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.trailingTransition = try makeTrailingTransition(
            partner: incomingID,
            kind: .crossDissolve
        )
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.leadingTransition = try makeLeadingTransition(
            partner: outgoingID,
            kind: .push
        )
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let errors = projectVideoTransitionErrors(in: project)
        XCTAssertTrue(
            errors.contains {
                if case .transitionPairMismatched = $0 { return true }
                return false
            }
        )
    }

    func testFRFX001PairMismatchedDurationIsRejected() throws {
        let outgoingID = try VideoTransitionFixtureID.outgoingClip()
        let incomingID = try VideoTransitionFixtureID.incomingClip()
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.trailingTransition = try makeTrailingTransition(
            partner: incomingID,
            durationFrames: 4
        )
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.leadingTransition = try makeLeadingTransition(
            partner: outgoingID,
            durationFrames: 2
        )
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let errors = projectVideoTransitionErrors(in: project)
        XCTAssertTrue(
            errors.contains {
                if case .transitionPairMismatched = $0 { return true }
                return false
            }
        )
    }

    func testFRFX001ExceedsSourceHandleIsRejected() throws {
        // Media is 240 frames (edit fixture default). Source [236, 246) needs 6 more frames
        // of tail for a 4-frame transition at 1x — but only 4 remain after end at 246... wait:
        // source end 246 > media 240 already invalid. Use source [230, 240) with 4-frame
        // transition: no handle past media end → rejected.
        let outgoingID = try VideoTransitionFixtureID.outgoingClip()
        let incomingID = try VideoTransitionFixtureID.incomingClip()
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.sourceStartFrame = 230
        outgoingSpec.sourceDurationFrames = 10
        outgoingSpec.trailingTransition = try makeTrailingTransition(
            partner: incomingID,
            durationFrames: 4
        )
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.leadingTransition = try makeLeadingTransition(
            partner: outgoingID,
            durationFrames: 4
        )
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let errors = projectVideoTransitionErrors(in: project)
        XCTAssertTrue(
            errors.contains {
                if case .transitionExceedsSourceHandle = $0 { return true }
                return false
            }
        )
    }

    func testFRFX001DiagonalPushIsRejected() throws {
        let project = try makeVideoTransitionPairProject(
            kind: .push,
            direction: .topLeft
        )
        let errors = projectVideoTransitionErrors(in: project)
        XCTAssertTrue(
            errors.contains {
                if case .transitionDirectionUnsupportedForKind = $0 { return true }
                return false
            }
        )
    }

    func testFRFX001DiagonalWipeIsAccepted() throws {
        let project = try makeVideoTransitionPairProject(
            kind: .wipe,
            direction: .topLeft
        )
        XCTAssertTrue(projectVideoTransitionErrors(in: project).isEmpty)
    }

    func testFRFX001TimeRemapEdgeIsRejected() throws {
        let remap = try ClipTimeRemap(
            keyframes: [
                TimeRemapKeyframe(time: .zero, sourceTime: .zero),
                TimeRemapKeyframe(
                    time: try editTime(10),
                    sourceTime: try editTime(10)
                )
            ]
        )
        let outgoingID = try VideoTransitionFixtureID.outgoingClip()
        let incomingID = try VideoTransitionFixtureID.incomingClip()
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.timeRemap = remap
        outgoingSpec.trailingTransition = try makeTrailingTransition(partner: incomingID)
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 10
        incomingSpec.leadingTransition = try makeLeadingTransition(partner: outgoingID)
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let errors = projectVideoTransitionErrors(in: project)
        XCTAssertTrue(
            errors.contains {
                if case .transitionUnsupportedWithTimeRemap = $0 { return true }
                return false
            }
        )
    }

    func testFRFX001PartnerNotAdjacentIsRejected() throws {
        let outgoingID = try VideoTransitionFixtureID.outgoingClip()
        let extraID = try VideoTransitionFixtureID.extraClip()
        let incomingID = try VideoTransitionFixtureID.incomingClip()
        var outgoingSpec = VideoTransitionClipSpec()
        outgoingSpec.trailingTransition = try makeTrailingTransition(partner: incomingID)
        var extraSpec = VideoTransitionClipSpec()
        extraSpec.timelineStartFrame = 10
        var incomingSpec = VideoTransitionClipSpec()
        incomingSpec.timelineStartFrame = 20
        incomingSpec.leadingTransition = try makeLeadingTransition(partner: outgoingID)
        let project = try makeVideoTransitionProject(items: [
            .clip(try makeVideoTransitionClip(id: outgoingID, spec: outgoingSpec)),
            .clip(try makeVideoTransitionClip(id: extraID, spec: extraSpec)),
            .clip(try makeVideoTransitionClip(id: incomingID, spec: incomingSpec))
        ])
        let errors = projectVideoTransitionErrors(in: project)
        XCTAssertTrue(
            errors.contains {
                if case .transitionPartnerNotAdjacent = $0 { return true }
                return false
            }
        )
    }
}
