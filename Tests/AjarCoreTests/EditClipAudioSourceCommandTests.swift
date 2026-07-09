// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import AjarCore

final class EditClipAudioSourceCommandTests: XCTestCase {
    func testFRAUD008DetachClipAudioPreservesAudioClipStateAndUndoRedo() throws {
        let fixture = try makeLinkedEditFixture(seed: 1_280)
        let audioMix = try undoableClipAudioSourceMix()
        let mixedProject = try apply(
            .setClipAudioMix(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                audioMix: audioMix
            ),
            to: fixture.project
        )
        let originalAudioClip = try audioSourceAudioClip(in: mixedProject, fixture: fixture)
        var history = EditHistory(project: mixedProject)

        let detached = try history.apply(
            .detachClipAudio(
                sequenceID: fixture.sequenceID,
                trackID: fixture.videoTrackID,
                clipID: fixture.videoClipID
            )
        )
        let detachedVideoClip = try audioSourceVideoClip(in: detached, fixture: fixture)
        let detachedAudioClip = try audioSourceAudioClip(in: detached, fixture: fixture)

        XCTAssertEqual(detached.validate(), .valid)
        XCTAssertNil(detachedVideoClip.linkGroupID)
        XCTAssertNil(detachedAudioClip.linkGroupID)
        XCTAssertEqual(detachedAudioClip.source, originalAudioClip.source)
        XCTAssertEqual(detachedAudioClip.sourceRange, originalAudioClip.sourceRange)
        XCTAssertEqual(detachedAudioClip.timelineRange, originalAudioClip.timelineRange)
        XCTAssertEqual(detachedAudioClip.audioMix, audioMix)
        XCTAssertEqual(history.undo(), mixedProject)
        XCTAssertEqual(try history.redo(), detached)
        XCTAssertEqual(try roundTrippedClipAudioSourceProject(detached), detached)
    }

    func testFRAUD008ReplaceClipAudioSourcePreservesEditsMixAndLinkState() throws {
        let fixture = try makeLinkedEditFixture(seed: 1_281)
        let replacementMedia = try makeAudioOnlyEditMediaRef(id: try editUUID(1_281_100))
        let project = projectAddingMedia(replacementMedia, to: fixture.project)
        let audioMix = try undoableClipAudioSourceMix()
        let mixedProject = try apply(
            .setClipAudioMix(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                audioMix: audioMix
            ),
            to: project
        )
        let originalAudioClip = try audioSourceAudioClip(in: mixedProject, fixture: fixture)
        var history = EditHistory(project: mixedProject)

        let replaced = try history.apply(
            .replaceClipAudioSource(
                sequenceID: fixture.sequenceID,
                trackID: fixture.audioTrackID,
                clipID: fixture.audioClipID,
                mediaID: replacementMedia.id
            )
        )
        let replacedAudioClip = try audioSourceAudioClip(in: replaced, fixture: fixture)

        XCTAssertEqual(replaced.validate(), .valid)
        XCTAssertEqual(replacedAudioClip.source, .media(id: replacementMedia.id))
        XCTAssertEqual(replacedAudioClip.sourceRange, originalAudioClip.sourceRange)
        XCTAssertEqual(replacedAudioClip.timelineRange, originalAudioClip.timelineRange)
        XCTAssertEqual(replacedAudioClip.linkGroupID, originalAudioClip.linkGroupID)
        XCTAssertEqual(replacedAudioClip.audioMix, audioMix)
        XCTAssertEqual(history.undo(), mixedProject)
        XCTAssertEqual(try history.redo(), replaced)
        XCTAssertEqual(try roundTrippedClipAudioSourceProject(replaced), replaced)
    }

    func testNFRSTAB003ReplaceClipAudioSourceRejectsMissingSource() throws {
        let fixture = try makeLinkedEditFixture(seed: 1_282)
        let missingMediaID = try editUUID(1_282_100)

        XCTAssertThrowsError(
            try apply(
                .replaceClipAudioSource(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clipID: fixture.audioClipID,
                    mediaID: missingMediaID
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.replacementAudioSourceNotFound(mediaID: missingMediaID))
            )
        }
    }

    func testNFRSTAB003ReplaceClipAudioSourceRejectsMediaWithoutAudio() throws {
        let fixture = try makeLinkedEditFixture(seed: 1_283)
        let replacementMedia = try makeVideoOnlyEditMediaRef(id: try editUUID(1_283_100))
        let project = projectAddingMedia(replacementMedia, to: fixture.project)

        XCTAssertThrowsError(
            try apply(
                .replaceClipAudioSource(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.audioTrackID,
                    clipID: fixture.audioClipID,
                    mediaID: replacementMedia.id
                ),
                to: project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.replacementAudioSourceHasNoAudio(mediaID: replacementMedia.id))
            )
        }
    }

    func testNFRSTAB003ReplaceClipAudioSourceRequiresAudioClipTarget() throws {
        let fixture = try makeLinkedEditFixture(seed: 1_284)
        let replacementMedia = try makeAudioOnlyEditMediaRef(id: try editUUID(1_284_100))
        let project = projectAddingMedia(replacementMedia, to: fixture.project)

        XCTAssertThrowsError(
            try apply(
                .replaceClipAudioSource(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.videoClipID,
                    mediaID: replacementMedia.id
                ),
                to: project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(
                    .replaceAudioRequiresAudioClip(
                        clipID: fixture.videoClipID,
                        kind: .video
                    )
                )
            )
        }
    }

    func testNFRSTAB003DetachClipAudioRequiresLinkedAVGroup() throws {
        let fixture = try makeLinkedEditFixture(seed: 1_285, linked: false)

        XCTAssertThrowsError(
            try apply(
                .detachClipAudio(
                    sequenceID: fixture.sequenceID,
                    trackID: fixture.videoTrackID,
                    clipID: fixture.videoClipID
                ),
                to: fixture.project
            )
        ) { error in
            XCTAssertEqual(
                error as? EditReducerError,
                .invalidEdit(.detachAudioRequiresLinkedAudio(clipID: fixture.videoClipID))
            )
        }
    }
}

func makeClipAudioSourceCommandCases(seed: Int) throws -> [EditCommandCase] {
    let detachFixture = try makeLinkedEditFixture(seed: 1_300 + seed)
    let replaceFixture = try makeLinkedEditFixture(seed: 1_320 + seed)
    let replacementMedia = try makeAudioOnlyEditMediaRef(id: try editUUID(1_320_100 + seed))
    let replaceProject = projectAddingMedia(replacementMedia, to: replaceFixture.project)

    return [
        EditCommandCase(
            project: detachFixture.project,
            command: .detachClipAudio(
                sequenceID: detachFixture.sequenceID,
                trackID: detachFixture.videoTrackID,
                clipID: detachFixture.videoClipID
            )
        ),
        EditCommandCase(
            project: replaceProject,
            command: .replaceClipAudioSource(
                sequenceID: replaceFixture.sequenceID,
                trackID: replaceFixture.audioTrackID,
                clipID: replaceFixture.audioClipID,
                mediaID: replacementMedia.id
            )
        )
    ]
}

private func undoableClipAudioSourceMix() throws -> ClipAudioMix {
    ClipAudioMix(
        gain: .constant(try RationalValue(numerator: 3, denominator: 2)),
        pan: .constant(try RationalValue(numerator: -1, denominator: 2)),
        fadeIn: ClipAudioFade(duration: try editTime(2), curve: .easeIn),
        fadeOut: ClipAudioFade(duration: try editTime(2), curve: .easeOut)
    )
}

private func audioSourceVideoClip(in project: Project, fixture: LinkedEditFixture) throws -> Clip {
    try requiredClip(
        fixture.videoClipID,
        trackID: fixture.videoTrackID,
        in: project,
        sequenceID: fixture.sequenceID
    )
}

private func audioSourceAudioClip(in project: Project, fixture: LinkedEditFixture) throws -> Clip {
    try requiredClip(
        fixture.audioClipID,
        trackID: fixture.audioTrackID,
        in: project,
        sequenceID: fixture.sequenceID
    )
}

private func roundTrippedClipAudioSourceProject(_ project: Project) throws -> Project {
    let package = try AjarProjectCodec.encodeNewDocument(project)
    let loadResult = try AjarProjectCodec.decode(
        projectJSON: package.projectJSON,
        mediaJSON: package.mediaJSON
    )
    guard case .editable(let loadedProject) = loadResult else {
        XCTFail("Expected editable project")
        throw ClipAudioSourceTestError.expectedEditableProject
    }
    return loadedProject
}

private func makeAudioOnlyEditMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).wav"),
        contentHash: ContentHash.sha256(data: Data("audio-\(id.uuidString)".utf8)),
        metadata: MediaMetadata(
            codecID: "pcm_f32le",
            pixelDimensions: nil,
            frameRate: nil,
            duration: try editTime(240),
            colorSpace: .unspecified,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeVideoOnlyEditMediaRef(id: UUID) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/\(id.uuidString).mov"),
        contentHash: ContentHash.sha256(data: Data("video-\(id.uuidString)".utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try editTime(240),
            colorSpace: .rec709,
            audioChannelLayout: nil,
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func projectAddingMedia(_ media: MediaRef, to project: Project) -> Project {
    Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool + [media],
        sequences: project.sequences
    )
}

private enum ClipAudioSourceTestError: Error {
    case expectedEditableProject
}
