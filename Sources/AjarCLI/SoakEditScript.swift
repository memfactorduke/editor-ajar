// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Result of one scripted edit pass, including how much history was exercised.
struct SoakEditScriptResult {
    /// Project after every scripted command was applied (and redone).
    let project: Project

    /// Number of commands applied, undone, and redone.
    let commandCount: Int
}

/// Deterministic scripted edit pass for `ajar soak` (NFR-STAB-005).
///
/// Every parameter comes from the seeded generator, so a run is a pure function of its seed.
/// The pass covers the known-risky edit shapes from the milestone: blade, trim, constant-speed
/// retime, a time-remapped clip, compound make + decompose, crossfade add + remove — then
/// undoes and redoes the full stack so `EditHistory` replay and divergence checking are part
/// of every soak iteration.
enum SoakEditScript {
    /// Applies the scripted commands to `fixture`, exercises undo/redo, and returns the
    /// edited project.
    static func run(
        fixture: SoakProjectFixture,
        using rng: inout SoakDeterministicRandom
    ) throws -> SoakEditScriptResult {
        var history = EditHistory(project: fixture.project)
        let commands = try makeCommands(fixture: fixture, history: &history, using: &rng)

        for _ in 0..<commands.appliedCount {
            history.undo()
        }
        guard history.currentProject == fixture.project else {
            throw AjarCLIError.projectLoadFailed(
                "soak undo stack did not restore the pristine fixture project"
            )
        }
        for _ in 0..<commands.appliedCount {
            try history.redo()
        }

        return SoakEditScriptResult(
            project: history.currentProject,
            commandCount: commands.appliedCount
        )
    }

    private struct AppliedCommands {
        let appliedCount: Int
    }

    private static func makeCommands(
        fixture: SoakProjectFixture,
        history: inout EditHistory,
        using rng: inout SoakDeterministicRandom
    ) throws -> AppliedCommands {
        let timebase = fixture.project.settings.frameRate
        let bladeIndex = rng.int(in: 0...3)
        let bladeOffsetFrames = Int64(rng.int(in: 2...6))
        let bladeRightClipID = rng.uuid()

        try applyBlade(
            fixture: fixture,
            history: &history,
            clipID: fixture.videoClipIDs[bladeIndex],
            offsetFrames: bladeOffsetFrames,
            rightClipID: bladeRightClipID
        )
        try applyTrim(
            fixture: fixture,
            history: &history,
            clipID: bladeRightClipID,
            timebase: timebase
        )
        try history.apply(
            .setClipSpeed(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipIDs[(bladeIndex + 1) % 4],
                speed: rng.bool()
                    ? RationalValue(2)
                    : try RationalValue(numerator: 1, denominator: 2)
            )
        )
        try applyTimeRemapAppend(fixture: fixture, history: &history, using: &rng)
        try history.apply(
            .setClipAudioCrossfade(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.outgoingAudioClipID,
                duration: try timebase.duration(ofFrames: Int64(rng.int(in: 2...4)))
            )
        )
        try applyCompoundRoundTrip(
            fixture: fixture,
            history: &history,
            clipID: fixture.videoClipIDs[(bladeIndex + 2) % 4],
            using: &rng
        )
        try history.apply(
            .removeClipAudioCrossfade(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.outgoingAudioClipID
            )
        )
        return AppliedCommands(appliedCount: history.undoCount)
    }

    private static func applyBlade(
        fixture: SoakProjectFixture,
        history: inout EditHistory,
        clipID: UUID,
        offsetFrames: Int64,
        rightClipID: UUID
    ) throws {
        let timebase = fixture.project.settings.frameRate
        let clip = try currentClip(
            clipID,
            trackID: fixture.videoTrackID,
            fixture: fixture,
            history: history
        )
        try history.apply(
            .bladeClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: clipID,
                atTime: try clip.timelineRange.start.adding(
                    timebase.duration(ofFrames: offsetFrames)
                ),
                rightClipID: rightClipID
            )
        )
    }

    /// Shrinks the blade's right half in place by one frame, keeping source and timeline
    /// durations matched for the unit-speed clip.
    private static func applyTrim(
        fixture: SoakProjectFixture,
        history: inout EditHistory,
        clipID: UUID,
        timebase: FrameRate
    ) throws {
        let clip = try currentClip(
            clipID,
            trackID: fixture.videoTrackID,
            fixture: fixture,
            history: history
        )
        let trimmedDuration = try clip.timelineRange.duration.subtracting(
            timebase.duration(ofFrames: 1)
        )
        try history.apply(
            .trimClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: clipID,
                sourceRange: try TimeRange(
                    start: clip.sourceRange.start,
                    duration: trimmedDuration
                ),
                timelineRange: try TimeRange(
                    start: clip.timelineRange.start,
                    duration: trimmedDuration
                )
            )
        )
    }

    /// Appends an FR-SPD-002 time-remapped clip: a two-segment ramp whose midpoint source
    /// time is drawn from the seeded generator.
    private static func applyTimeRemapAppend(
        fixture: SoakProjectFixture,
        history: inout EditHistory,
        using rng: inout SoakDeterministicRandom
    ) throws {
        let timebase = fixture.project.settings.frameRate
        let midpointSourceFrames = Int64(8 + rng.int(in: 2...16))
        let curve = try ClipTimeRemap(keyframes: [
            TimeRemapKeyframe(
                time: .zero,
                sourceTime: try RationalTime.atFrame(8, frameRate: timebase)
            ),
            TimeRemapKeyframe(
                time: try RationalTime.atFrame(6, frameRate: timebase),
                sourceTime: try RationalTime.atFrame(midpointSourceFrames, frameRate: timebase)
            ),
            TimeRemapKeyframe(
                time: try RationalTime.atFrame(12, frameRate: timebase),
                sourceTime: try RationalTime.atFrame(26, frameRate: timebase)
            )
        ])
        try history.apply(
            .appendClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.compoundTrackID,
                clip: Clip(
                    id: rng.uuid(),
                    source: .media(id: fixture.videoMediaID),
                    sourceRange: try TimeRange(
                        start: RationalTime.atFrame(8, frameRate: timebase),
                        duration: timebase.duration(ofFrames: 18)
                    ),
                    timelineRange: try TimeRange(start: .zero, duration: curve.duration),
                    kind: .video,
                    name: "Soak remap clip",
                    timeRemap: curve
                )
            )
        )
    }

    private static func applyCompoundRoundTrip(
        fixture: SoakProjectFixture,
        history: inout EditHistory,
        clipID: UUID,
        using rng: inout SoakDeterministicRandom
    ) throws {
        let compoundClipID = rng.uuid()
        try history.apply(
            .makeCompoundClip(
                sequenceID: fixture.sequenceID,
                compoundSequenceID: rng.uuid(),
                compoundClipID: compoundClipID,
                selectedClips: [
                    ClipReference(trackID: fixture.videoTrackID, clipID: clipID)
                ],
                name: "Soak scripted compound"
            )
        )
        try history.apply(
            .decomposeCompoundClip(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: compoundClipID
            )
        )
    }

    private static func currentClip(
        _ clipID: UUID,
        trackID: UUID,
        fixture: SoakProjectFixture,
        history: EditHistory
    ) throws -> Clip {
        let project = history.currentProject
        guard
            let sequence = project.sequences.first(where: { $0.id == fixture.sequenceID }),
            let track = (sequence.videoTracks + sequence.audioTracks)
                .first(where: { $0.id == trackID })
        else {
            throw AjarCLIError.missingSequence
        }
        for item in track.items {
            if case .clip(let clip) = item, clip.id == clipID {
                return clip
            }
        }
        throw AjarCLIError.projectLoadFailed(
            "soak script could not find clip \(clipID) on track \(trackID)"
        )
    }
}
