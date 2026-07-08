// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

/// Blade fidelity for retimed clips (FR-SPD-002, FR-SPD-003, FR-TL-004): blading a
/// reversed clip hands the source TAIL to the left half, blading a time-remapped clip
/// splits the curve at the blade offset with the right half re-anchored to local time
/// zero, and in both cases the bladed halves reproduce the unbladed timeline-to-source
/// mapping exactly at every probe point.
final class BladeRetimedClipTests: XCTestCase {
    // MARK: - Reversed clips (FR-SPD-003)

    func testFRSPD003BladeReversedClipGivesLeftHalfTheSourceTail() throws {
        // Reverse consumes source backward: blading [0, 42) with source [20, 62) at
        // timeline 3 gives left [62 − 3, 62) = [59, 62) and right [20, 59).
        let fixture = try makeEditFixture(seed: 966)
        let clip = try makeRetimedClip(
            fixture: fixture,
            sourceStartFrame: 20,
            sourceDurationFrames: 42,
            reverse: true
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 3), to: project)

        let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
        XCTAssertEqual(left.sourceRange, try editRange(startFrame: 59, durationFrames: 3))
        XCTAssertEqual(left.timelineRange, try editRange(startFrame: 0, durationFrames: 3))
        XCTAssertEqual(right.sourceRange, try editRange(startFrame: 20, durationFrames: 39))
        XCTAssertEqual(right.timelineRange, try editRange(startFrame: 3, durationFrames: 39))
        XCTAssertTrue(left.reverse)
        XCTAssertTrue(right.reverse)
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testFRSPD003FRTL004BladeReversedClipPreservesSourceTimeMappingAcrossCut() throws {
        // Property: for several constant rates and many blade points on an odd 97-step
        // grid, both halves agree RationalTime-exactly with the unbladed clip's mapping
        // at every probe point, so audio renders sample-identically and video renders
        // frame-identically (the render graph consumes this same mapping).
        let speeds: [RationalValue] = [
            .one,
            try RationalValue(numerator: 1, denominator: 2),
            RationalValue(2),
            try RationalValue(numerator: 3, denominator: 2),
            try RationalValue(numerator: 7, denominator: 5)
        ]
        for (speedIndex, speed) in speeds.enumerated() {
            let fixture = try makeEditFixture(seed: 967)
            let clip = try makeRetimedClip(
                fixture: fixture,
                sourceStartFrame: 20,
                sourceDurationFrames: 42,
                speed: speed,
                reverse: true
            )
            let project = try replacingVideoItems([.clip(clip)], in: fixture)
            for bladeStep in stride(from: Int64(1), through: 96, by: 5) {
                let cut = try gridTime(step: bladeStep, of: clip.timelineRange)
                let edited = try apply(
                    bladeCommand(fixture: fixture, atTime: cut),
                    to: project
                )
                try assertBladedMappingMatches(
                    original: clip,
                    edited: edited,
                    fixture: fixture,
                    cut: cut,
                    context: "speed \(speed.numerator)/\(speed.denominator)"
                        + " index \(speedIndex) blade step \(bladeStep)"
                )
            }
        }
    }

    func testFRSPD003BladeReversedClipUndoRedoIdentity() throws {
        let fixture = try makeEditFixture(seed: 968)
        let clip = try makeRetimedClip(
            fixture: fixture,
            sourceStartFrame: 20,
            sourceDurationFrames: 42,
            reverse: true
        )
        let project = try replacingVideoItems([.clip(clip)], in: fixture)

        try assertUndoRedoIdentity(
            project: project,
            command: bladeCommand(fixture: fixture, atFrame: 17)
        )
    }

    // MARK: - Time-remapped clips (FR-SPD-002)

    func testFRSPD002BladeTimeRemappedClipSplitsCurveAtBoundary() throws {
        // Blading at 8 lands inside the zero-slope (freeze) segment (6, 22) → (10, 22):
        // the boundary keyframe evaluates to source 22, the left curve re-terminates at
        // (8, 22), and the right curve re-anchors with its first keyframe at local zero.
        let fixture = try makeEditFixture(seed: 969)
        let clip = try makeRemapClip(fixture: fixture)
        let project = try replacingVideoItems([.clip(clip)], in: fixture)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 8), to: project)

        let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
        XCTAssertEqual(
            try XCTUnwrap(left.timeRemap).keyframes,
            [
                TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(10)),
                TimeRemapKeyframe(time: try editTime(6), sourceTime: try editTime(22)),
                TimeRemapKeyframe(time: try editTime(8), sourceTime: try editTime(22))
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(right.timeRemap).keyframes,
            [
                TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(22)),
                TimeRemapKeyframe(time: try editTime(2), sourceTime: try editTime(22)),
                TimeRemapKeyframe(time: try editTime(16), sourceTime: try editTime(58))
            ]
        )
        // Both halves keep the full source range: the split curves stay in bounds.
        XCTAssertEqual(left.sourceRange, clip.sourceRange)
        XCTAssertEqual(right.sourceRange, clip.sourceRange)
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testFRSPD002BladeTimeRemappedClipExactlyOnKeyframeSplitsWithoutDuplicates() throws {
        let fixture = try makeEditFixture(seed: 970)
        let clip = try makeRemapClip(fixture: fixture)
        let project = try replacingVideoItems([.clip(clip)], in: fixture)

        let edited = try apply(bladeCommand(fixture: fixture, atFrame: 6), to: project)

        let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
        let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
        XCTAssertEqual(
            try XCTUnwrap(left.timeRemap).keyframes,
            [
                TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(10)),
                TimeRemapKeyframe(time: try editTime(6), sourceTime: try editTime(22))
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(right.timeRemap).keyframes,
            [
                TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(22)),
                TimeRemapKeyframe(time: try editTime(4), sourceTime: try editTime(22)),
                TimeRemapKeyframe(time: try editTime(18), sourceTime: try editTime(58))
            ]
        )
        XCTAssertEqual(edited.validate(), .valid)
    }

    func testFRSPD002FRTL004BladeTimeRemappedClipPreservesSourceTimeMapping() throws {
        // Property: blade points on an odd 97-step grid (never frame-aligned) across a
        // multi-segment curve with a zero-slope span; both halves must agree
        // RationalTime-exactly with the unbladed curve at every probe point.
        let fixture = try makeEditFixture(seed: 971)
        let clip = try makeRemapClip(fixture: fixture)
        let project = try replacingVideoItems([.clip(clip)], in: fixture)
        for bladeStep in stride(from: Int64(1), through: 96, by: 5) {
            let cut = try gridTime(step: bladeStep, of: clip.timelineRange)
            let edited = try apply(bladeCommand(fixture: fixture, atTime: cut), to: project)
            try assertBladedMappingMatches(
                original: clip,
                edited: edited,
                fixture: fixture,
                cut: cut,
                context: "remap blade step \(bladeStep)"
            )
        }
    }

    func testFRSPD002BladeTimeRemappedClipUndoRedoIdentity() throws {
        let fixture = try makeEditFixture(seed: 972)
        let clip = try makeRemapClip(fixture: fixture)
        let project = try replacingVideoItems([.clip(clip)], in: fixture)

        try assertUndoRedoIdentity(
            project: project,
            command: bladeCommand(fixture: fixture, atFrame: 11)
        )
    }
}

// MARK: - Shared helpers

/// The right-half clip ID used by every blade in this file.
private func bladeRightID() throws -> UUID {
    try editUUID(966_500)
}

private func bladeCommand(fixture: EditFixture, atFrame frame: Int64) throws -> EditCommand {
    try bladeCommand(fixture: fixture, atTime: editTime(frame))
}

private func bladeCommand(fixture: EditFixture, atTime: RationalTime) throws -> EditCommand {
    .bladeClip(
        sequenceID: fixture.sequenceID,
        trackID: fixture.videoTrackID,
        clipID: fixture.clipID,
        atTime: atTime,
        rightClipID: try bladeRightID()
    )
}

/// A retimed video clip starting at timeline zero with a custom source placement.
private func makeRetimedClip(
    fixture: EditFixture,
    sourceStartFrame: Int64,
    sourceDurationFrames: Int64,
    speed: RationalValue = .one,
    reverse: Bool = false,
    timeRemap: ClipTimeRemap? = nil
) throws -> Clip {
    let sourceDuration = try editTime(sourceDurationFrames)
    let timelineDuration: RationalTime
    if let timeRemap {
        timelineDuration = timeRemap.duration
    } else {
        timelineDuration = try Clip.timelineDuration(
            forSourceDuration: sourceDuration,
            speed: speed
        )
    }
    return Clip(
        id: fixture.clipID,
        source: .media(id: fixture.mediaID),
        sourceRange: try TimeRange(start: editTime(sourceStartFrame), duration: sourceDuration),
        timelineRange: try TimeRange(start: editTime(0), duration: timelineDuration),
        kind: .video,
        name: "Retimed clip",
        speed: speed,
        reverse: reverse,
        timeRemap: timeRemap
    )
}

/// A time-remapped clip on `[0, 24)` over source `[10, 58)` with a ramp, a zero-slope
/// freeze span, and a final segment ending on the exclusive source end.
private func makeRemapClip(fixture: EditFixture) throws -> Clip {
    let curve = try ClipTimeRemap(keyframes: [
        TimeRemapKeyframe(time: try editTime(0), sourceTime: try editTime(10)),
        TimeRemapKeyframe(time: try editTime(6), sourceTime: try editTime(22)),
        TimeRemapKeyframe(time: try editTime(10), sourceTime: try editTime(22)),
        TimeRemapKeyframe(time: try editTime(24), sourceTime: try editTime(58))
    ])
    return try makeRetimedClip(
        fixture: fixture,
        sourceStartFrame: 10,
        sourceDurationFrames: 48,
        timeRemap: curve
    )
}

/// The odd-grid time at `start + duration × step / 97`, so probes and blade points never
/// divide evenly into common timescales.
private func gridTime(step: Int64, of range: TimeRange) throws -> RationalTime {
    try range.start.adding(range.duration.multiplied(by: step).divided(by: 97))
}

/// Asserts both bladed halves agree RationalTime-exactly with the unbladed clip's
/// timeline-to-source mapping on the 97-step probe grid spanning the whole clip.
private func assertBladedMappingMatches(
    original: Clip,
    edited: Project,
    fixture: EditFixture,
    cut: RationalTime,
    context: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let left = try requiredClip(fixture.clipID, in: edited, fixture: fixture)
    let right = try requiredClip(bladeRightID(), in: edited, fixture: fixture)
    for step in Int64(0)...96 {
        let probe = try gridTime(step: step, of: original.timelineRange)
        let half = probe < cut ? left : right
        XCTAssertEqual(
            try half.sourceTime(at: probe),
            try original.sourceTime(at: probe),
            "\(context): mapping diverged at probe step \(step)",
            file: file,
            line: line
        )
    }
    // The two halves must agree with each other exactly at the cut.
    XCTAssertEqual(
        try right.sourceTime(at: cut),
        try original.sourceTime(at: cut),
        "\(context): right half diverged at the cut",
        file: file,
        line: line
    )
}
