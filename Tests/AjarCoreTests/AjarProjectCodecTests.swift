// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable file_length

import Foundation
import XCTest

@testable import AjarCore

final class AjarProjectCodecRoundTripTests: XCTestCase {
    func testFRPROJ001FRPROJ003RoundTripPropertyOverGeneratedProjects() throws {
        for seed in 0..<16 {
            let project = try makeCodecProject(seed: seed)
            let package = try AjarProjectCodec.encode(project)
            let loaded = try AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )

            XCTAssertEqual(loaded, .editable(project))
        }
    }

    func testFRPROJ001CanonicalOrderReencodingUnchangedProjectIsByteIdentical() throws {
        let project = try makeCodecProject(seed: 100)
        let firstPackage = try AjarProjectCodec.encode(project)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: firstPackage.projectJSON,
                mediaJSON: firstPackage.mediaJSON
            )
        )
        let secondPackage = try AjarProjectCodec.encode(loadedProject)

        XCTAssertEqual(secondPackage.projectJSON, firstPackage.projectJSON)
        XCTAssertEqual(secondPackage.mediaJSON, firstPackage.mediaJSON)
    }

    func testFRPROJ001MediaManifestCarriesMediaReferencesOutsideProjectJSON() throws {
        let project = try makeCodecProject(seed: 110)
        let package = try AjarProjectCodec.encode(project)
        let projectDocument = try JSONDecoder().decode(Project.self, from: package.projectJSON)
        let mediaManifest = try JSONDecoder().decode(
            AjarMediaManifest.self,
            from: package.mediaJSON
        )

        XCTAssertEqual(projectDocument.mediaPool, [])
        XCTAssertEqual(mediaManifest.media, project.mediaPool)
        XCTAssertEqual(mediaManifest.schemaVersion, AjarProjectCodec.currentSchemaVersion)
    }

    func testFRTL008MarkerFieldsRoundTripThroughProjectCodec() throws {
        let project = try makeCodecProject(seed: 120)
        let package = try AjarProjectCodec.encode(project)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let marker = try XCTUnwrap(loadedProject.sequences.first?.markers.first)

        XCTAssertEqual(marker.color, .orange)
        XCTAssertEqual(marker.note, "FR-TL-008 marker note")
        XCTAssertEqual(
            marker.anchor,
            .clip(
                trackID: try codecUUID(120_004),
                clipID: try codecUUID(120_006)
            )
        )
    }

    func testFRTL008LegacyMarkerFieldsDefaultWhenMissingFromProjectCodec() throws {
        let project = try makeCodecProject(seed: 130)
        let package = try AjarProjectCodec.encode(project)
        let legacyProjectJSON = try projectJSONWithoutMarkerDetailFields(package.projectJSON)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let marker = try XCTUnwrap(loadedProject.sequences.first?.markers.first)

        XCTAssertEqual(marker.color, .blue)
        XCTAssertEqual(marker.note, "")
        XCTAssertEqual(marker.anchor, .timeline)
    }

    func testFRTL009ClipLinkGroupRoundTripsThroughProjectCodec() throws {
        let project = try makeCodecProject(seed: 140)
        let package = try AjarProjectCodec.encode(project)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))
        let audioClip = try XCTUnwrap(clip(in: sequence.audioTracks.first))

        XCTAssertNotNil(videoClip.linkGroupID)
        XCTAssertEqual(videoClip.linkGroupID, audioClip.linkGroupID)
    }

    func testFRTL011TwoSequencesRoundTripThroughProjectCodec() throws {
        let project = try makeCodecProject(seed: 150)
        let secondSequence = Sequence(
            id: try codecUUID(150_050),
            name: "Second Codec Sequence",
            videoTracks: [Track(id: try codecUUID(150_051), kind: .video, items: [])],
            audioTracks: [Track(id: try codecUUID(150_052), kind: .audio, items: [])],
            markers: [],
            timebase: try FrameRate(frames: 24)
        )
        let twoSequenceProject = Project(
            schemaVersion: project.schemaVersion,
            settings: project.settings,
            mediaPool: project.mediaPool,
            sequences: project.sequences + [secondSequence]
        )

        let package = try AjarProjectCodec.encode(twoSequenceProject)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )

        XCTAssertEqual(loadedProject, twoSequenceProject)
        let sequenceNames = loadedProject.sequences.map(\.name)

        XCTAssertEqual(sequenceNames, [
            "Codec Sequence 150",
            "Second Codec Sequence"
        ])
    }

    func testFRXFORM001To005ClipTransformRoundTripsThroughProjectCodec() throws {
        let project = try makeCodecProject(seed: 160)
        let transform = try makeNonIdentityClipTransform()
        let transformedProject = try replacingFirstCodecClipTransform(
            in: project,
            with: transform
        )

        let package = try AjarProjectCodec.encode(transformedProject)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))

        XCTAssertEqual(loadedProject, transformedProject)
        XCTAssertEqual(videoClip.transform, transform)
    }

    func testFRKEY001FRXFORM008KeyframedTransformRoundTripsThroughProjectCodec() throws {
        let project = try makeCodecProject(seed: 165)
        let animation = try makeKeyframedCodecTransform()
        let transformedProject = try replacingFirstCodecClipTransformAnimation(
            in: project,
            with: animation
        )

        let package = try AjarProjectCodec.encode(transformedProject)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))

        XCTAssertEqual(loadedProject, transformedProject)
        XCTAssertEqual(videoClip.transformAnimation, animation)
        XCTAssertEqual(
            videoClip.transformAnimation.value(at: try codecTime(4)).position,
            CanvasPoint(x: RationalValue(4), y: RationalValue(8))
        )
    }

    func testFRXFORM001To005LegacyClipWithoutTransformDefaultsToIdentity() throws {
        let project = try makeCodecProject(seed: 170)
        let package = try AjarProjectCodec.encode(project)
        let legacyProjectJSON = try projectJSONWithoutClipTransformFields(package.projectJSON)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.transform, .identity)
        XCTAssertEqual(videoClip.transformAnimation, .identity)
    }

    func testFRCOMP001ClipEffectsRoundTripThroughProjectCodec() throws {
        let project = try makeCodecProject(seed: 180)
        let effects = try makeCodecClipEffects()
        let effectsProject = try replacingFirstCodecClipEffects(
            in: project,
            with: effects
        )

        let package = try AjarProjectCodec.encode(effectsProject)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))

        XCTAssertEqual(loadedProject, effectsProject)
        XCTAssertEqual(videoClip.effects, effects)
    }

    func testFRCOMP001LegacyClipWithoutEffectsDefaultsToNone() throws {
        let project = try makeCodecProject(seed: 190)
        let package = try AjarProjectCodec.encode(project)
        let legacyProjectJSON = try projectJSONWithoutClipEffectsField(package.projectJSON)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.effects, .none)
    }

    func testFRPROJ005FRCOMP001LegacyChromaKeyDefaultsNewNestedFields() throws {
        let project = try makeCodecProject(seed: 195)
        let effects = try makeCodecClipEffects()
        let effectsProject = try replacingFirstCodecClipEffects(
            in: project,
            with: effects
        )
        let package = try AjarProjectCodec.encode(effectsProject)
        let legacyProjectJSON = try projectJSONWithoutChromaKeyChokeAndViewMatte(
            package.projectJSON
        )
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.effects.chromaKey.choke, .zero)
        XCTAssertEqual(videoClip.effects.chromaKey.viewMatte, false)
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }

    func testFRCOMP003ClipMasksRoundTripThroughProjectCodec() throws {
        let project = try makeCodecProject(seed: 196)
        let effects = try makeCodecClipMaskEffects()
        let effectsProject = try replacingFirstCodecClipEffects(
            in: project,
            with: effects
        )

        let package = try AjarProjectCodec.encode(effectsProject)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: package.projectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))

        XCTAssertEqual(loadedProject, effectsProject)
        XCTAssertEqual(videoClip.effects.masks, effects.masks)
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }

    func testFRPROJ005FRCOMP003LegacyEffectsWithoutMasksDefaultToEmpty() throws {
        let project = try makeCodecProject(seed: 197)
        let effectsProject = try replacingFirstCodecClipEffects(
            in: project,
            with: try makeCodecClipEffects()
        )
        let package = try AjarProjectCodec.encode(effectsProject)
        let legacyProjectJSON = try projectJSONWithoutClipEffectMasks(package.projectJSON)
        let loadedProject = try editableProject(
            from: AjarProjectCodec.decode(
                projectJSON: legacyProjectJSON,
                mediaJSON: package.mediaJSON
            )
        )
        let sequence = try XCTUnwrap(loadedProject.sequences.first)
        let videoClip = try XCTUnwrap(clip(in: sequence.videoTracks.first))

        XCTAssertEqual(loadedProject.schemaVersion, AjarProjectCodec.currentSchemaVersion)
        XCTAssertEqual(videoClip.effects.masks, [])
        XCTAssertEqual(videoClip.effectsAnimation, .constant(videoClip.effects))
    }
}

final class AjarProjectCodecVersioningTests: XCTestCase {
    func testFRPROJ005OlderFixtureMigratesForwardToCurrentSchema() throws {
        let legacyProject = try makeCodecProject(seed: 200, schemaVersion: 0)
        let legacyProjectDocument = Project(
            schemaVersion: 0,
            settings: legacyProject.settings,
            mediaPool: [],
            sequences: legacyProject.sequences
        )
        let legacyManifest = AjarMediaManifest(schemaVersion: 0, media: legacyProject.mediaPool)
        let loaded = try AjarProjectCodec.decode(
            projectJSON: try testEncoder().encode(legacyProjectDocument),
            mediaJSON: try testEncoder().encode(legacyManifest)
        )
        let expected = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: legacyProject.settings,
            mediaPool: legacyProject.mediaPool,
            sequences: legacyProject.sequences
        )

        XCTAssertEqual(loaded, .editable(expected))
    }

    func testFRPROJ005NewerVersionLoadsReadOnlyWithClearMessage() throws {
        let newerVersion = AjarProjectCodec.currentSchemaVersion + 1
        let newerProject = try makeCodecProject(seed: 210, schemaVersion: newerVersion)
        let newerDocument = Project(
            schemaVersion: newerVersion,
            settings: newerProject.settings,
            mediaPool: [],
            sequences: newerProject.sequences
        )
        let manifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            media: newerProject.mediaPool
        )
        let loaded = try AjarProjectCodec.decode(
            projectJSON: try testEncoder().encode(newerDocument),
            mediaJSON: try testEncoder().encode(manifest)
        )
        let reason = AjarProjectReadOnlyReason.newerSchemaVersion(
            found: newerVersion,
            supported: AjarProjectCodec.currentSchemaVersion
        )

        XCTAssertEqual(loaded, .readOnly(newerProject, reason: reason))
        XCTAssertTrue(reason.message.contains("read-only"))
        XCTAssertTrue(reason.message.contains("\(newerVersion)"))
    }
}

final class AjarProjectCodecFuzzTests: XCTestCase {
    func testNFRSTAB006MalformedAndTruncatedCorpusReturnsTypedErrorsWithoutCrashing() throws {
        let package = try AjarProjectCodec.encode(makeCodecProject(seed: 300))
        let mutatedProject = mutatingOneByte(package.projectJSON)
        let mutatedMedia = mutatingOneByte(package.mediaJSON)
        var cases: [(Data, Data)] = []
        cases.append((Data(), package.mediaJSON))
        cases.append((Data("{".utf8), package.mediaJSON))
        cases.append((Data("null".utf8), package.mediaJSON))
        cases.append((Data(#"{"schemaVersion":1}"#.utf8), package.mediaJSON))
        cases.append((Data(package.projectJSON.dropLast()), package.mediaJSON))
        cases.append((mutatedProject, package.mediaJSON))
        cases.append((package.projectJSON, Data()))
        cases.append((package.projectJSON, Data("{".utf8)))
        cases.append((package.projectJSON, Data("[]".utf8)))
        cases.append((package.projectJSON, Data(#"{"schemaVersion":1}"#.utf8)))
        cases.append((package.projectJSON, Data(package.mediaJSON.dropLast())))
        cases.append((package.projectJSON, mutatedMedia))

        for (projectJSON, mediaJSON) in cases {
            XCTAssertThrowsError(
                try AjarProjectCodec.decode(projectJSON: projectJSON, mediaJSON: mediaJSON)
            ) { error in
                XCTAssertTrue(
                    error is AjarProjectCodecError,
                    "Expected typed codec error, got \(error)"
                )
            }
        }
    }

    func testNFRSTAB006InvalidDecodedProjectReturnsTypedValidationError() throws {
        let project = try makeCodecProject(seed: 310)
        let invalidDocument = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: project.settings,
            mediaPool: [],
            sequences: project.sequences
        )
        let emptyManifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            media: []
        )

        XCTAssertThrowsError(
            try AjarProjectCodec.decode(
                projectJSON: try testEncoder().encode(invalidDocument),
                mediaJSON: try testEncoder().encode(emptyManifest)
            )
        ) { error in
            guard case .validationFailed(let errors) = error as? AjarProjectCodecError else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertFalse(errors.isEmpty)
        }
    }
}

private func editableProject(from result: AjarProjectLoadResult) throws -> Project {
    switch result {
    case .editable(let project):
        return project
    case .readOnly:
        XCTFail("Expected editable project")
        throw AjarProjectCodecError.malformedProjectJSON("unexpected read-only result")
    }
}

private func testEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private func mutatingOneByte(_ data: Data) -> Data {
    guard !data.isEmpty else {
        return Data([0xff])
    }

    var copy = data
    copy[copy.startIndex] = 0xff
    return copy
}

private func projectJSONWithoutMarkerDetailFields(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var markers = try XCTUnwrap(sequence["markers"] as? [[String: Any]])
    var marker = try XCTUnwrap(markers.first)

    marker.removeValue(forKey: "color")
    marker.removeValue(forKey: "note")
    marker.removeValue(forKey: "anchor")
    markers[0] = marker
    sequence["markers"] = markers
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func projectJSONWithoutClipTransformFields(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var videoTracks = try XCTUnwrap(sequence["videoTracks"] as? [[String: Any]])
    var videoTrack = try XCTUnwrap(videoTracks.first)
    var items = try XCTUnwrap(videoTrack["items"] as? [[String: Any]])
    var clipItem = try XCTUnwrap(items.first)
    var clipPayload = try XCTUnwrap(clipItem["clip"] as? [String: Any])

    document["schemaVersion"] = 1
    clipPayload.removeValue(forKey: "transform")
    clipPayload.removeValue(forKey: "transformAnimation")
    clipItem["clip"] = clipPayload
    items[0] = clipItem
    videoTrack["items"] = items
    videoTracks[0] = videoTrack
    sequence["videoTracks"] = videoTracks
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func projectJSONWithoutClipEffectsField(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var videoTracks = try XCTUnwrap(sequence["videoTracks"] as? [[String: Any]])
    var videoTrack = try XCTUnwrap(videoTracks.first)
    var items = try XCTUnwrap(videoTrack["items"] as? [[String: Any]])
    var clipItem = try XCTUnwrap(items.first)
    var clipPayload = try XCTUnwrap(clipItem["clip"] as? [String: Any])

    document["schemaVersion"] = 1
    clipPayload.removeValue(forKey: "effects")
    clipItem["clip"] = clipPayload
    items[0] = clipItem
    videoTrack["items"] = items
    videoTracks[0] = videoTrack
    sequence["videoTracks"] = videoTracks
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func projectJSONWithoutChromaKeyChokeAndViewMatte(_ projectJSON: Data) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var videoTracks = try XCTUnwrap(sequence["videoTracks"] as? [[String: Any]])
    var videoTrack = try XCTUnwrap(videoTracks.first)
    var items = try XCTUnwrap(videoTrack["items"] as? [[String: Any]])
    var clipItem = try XCTUnwrap(items.first)
    var clipWrapper = try XCTUnwrap(clipItem["clip"] as? [String: Any])
    var clipPayload = try XCTUnwrap(clipWrapper["_0"] as? [String: Any])
    var effects = try XCTUnwrap(clipPayload["effects"] as? [String: Any])
    var chromaKey = try XCTUnwrap(effects["chromaKey"] as? [String: Any])

    document["schemaVersion"] = 1
    chromaKey.removeValue(forKey: "choke")
    chromaKey.removeValue(forKey: "viewMatte")
    effects["chromaKey"] = chromaKey
    clipPayload["effects"] = effects
    clipPayload.removeValue(forKey: "effectsAnimation")
    clipWrapper["_0"] = clipPayload
    clipItem["clip"] = clipWrapper
    items[0] = clipItem
    videoTrack["items"] = items
    videoTracks[0] = videoTrack
    sequence["videoTracks"] = videoTracks
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func projectJSONWithoutClipEffectMasks(_ projectJSON: Data) throws -> Data {
    try updatingFirstClipPayload(projectJSON) { clipPayload in
        var effects = try XCTUnwrap(clipPayload["effects"] as? [String: Any])
        effects.removeValue(forKey: "masks")
        clipPayload["effects"] = effects
        clipPayload.removeValue(forKey: "effectsAnimation")
    }
}

private func updatingFirstClipPayload(
    _ projectJSON: Data,
    update: (inout [String: Any]) throws -> Void
) throws -> Data {
    var document = try XCTUnwrap(
        JSONSerialization.jsonObject(with: projectJSON) as? [String: Any]
    )
    var sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
    var sequence = try XCTUnwrap(sequences.first)
    var videoTracks = try XCTUnwrap(sequence["videoTracks"] as? [[String: Any]])
    var videoTrack = try XCTUnwrap(videoTracks.first)
    var items = try XCTUnwrap(videoTrack["items"] as? [[String: Any]])
    var clipItem = try XCTUnwrap(items.first)
    var clipWrapper = try XCTUnwrap(clipItem["clip"] as? [String: Any])

    document["schemaVersion"] = 1
    if var clipPayload = clipWrapper["_0"] as? [String: Any] {
        try update(&clipPayload)
        clipWrapper["_0"] = clipPayload
        clipItem["clip"] = clipWrapper
    } else {
        try update(&clipWrapper)
        clipItem["clip"] = clipWrapper
    }

    items[0] = clipItem
    videoTrack["items"] = items
    videoTracks[0] = videoTrack
    sequence["videoTracks"] = videoTracks
    sequences[0] = sequence
    document["sequences"] = sequences

    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func replacingFirstCodecClipTransformAnimation(
    in project: Project,
    with animation: AnimatableClipTransform
) throws -> Project {
    let sequence = try XCTUnwrap(project.sequences.first)
    let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
    let originalClip = try XCTUnwrap(clip(in: videoTrack))
    let transformedClip = Clip(
        id: originalClip.id,
        source: originalClip.source,
        sourceRange: originalClip.sourceRange,
        timelineRange: originalClip.timelineRange,
        kind: originalClip.kind,
        name: originalClip.name,
        linkGroupID: originalClip.linkGroupID,
        transform: animation.baseTransform,
        transformAnimation: animation
    )
    let replacementTrack = Track(
        id: videoTrack.id,
        kind: videoTrack.kind,
        items: videoTrack.items.map { item in
            if case .clip(let currentClip) = item, currentClip.id == originalClip.id {
                return .clip(transformedClip)
            }
            return item
        },
        enabled: videoTrack.enabled,
        locked: videoTrack.locked,
        muted: videoTrack.muted,
        solo: videoTrack.solo,
        hidden: videoTrack.hidden
    )
    let replacementSequence = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: [replacementTrack] + sequence.videoTracks.dropFirst(),
        audioTracks: sequence.audioTracks,
        markers: sequence.markers,
        timebase: sequence.timebase
    )

    return Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: [replacementSequence] + project.sequences.dropFirst()
    )
}

private func makeKeyframedCodecTransform() throws -> AnimatableClipTransform {
    try AnimatableClipTransform(
        position: Animatable(
            base: .zero,
            keyframes: [
                Keyframe(time: codecTime(0), value: .zero, interpolation: .linear),
                Keyframe(
                    time: codecTime(8),
                    value: CanvasPoint(x: RationalValue(8), y: RationalValue(16)),
                    interpolation: .hold
                )
            ]
        ),
        opacity: Animatable(
            base: .one,
            keyframes: [
                Keyframe(time: codecTime(0), value: .one, interpolation: .easeInOut),
                Keyframe(
                    time: codecTime(8),
                    value: try RationalValue(numerator: 1, denominator: 2),
                    interpolation: .hold
                )
            ]
        ),
        blendMode: .screen,
        flip: ClipFlip(horizontal: true, vertical: false)
    )
}

private func replacingFirstCodecClipTransform(
    in project: Project,
    with transform: ClipTransform
) throws -> Project {
    let sequence = try XCTUnwrap(project.sequences.first)
    let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
    let originalClip = try XCTUnwrap(clip(in: videoTrack))
    let transformedClip = Clip(
        id: originalClip.id,
        source: originalClip.source,
        sourceRange: originalClip.sourceRange,
        timelineRange: originalClip.timelineRange,
        kind: originalClip.kind,
        name: originalClip.name,
        linkGroupID: originalClip.linkGroupID,
        transform: transform
    )
    let replacementTrack = Track(
        id: videoTrack.id,
        kind: videoTrack.kind,
        items: videoTrack.items.map { item in
            if case .clip(let currentClip) = item, currentClip.id == originalClip.id {
                return .clip(transformedClip)
            }
            return item
        },
        enabled: videoTrack.enabled,
        locked: videoTrack.locked,
        muted: videoTrack.muted,
        solo: videoTrack.solo,
        hidden: videoTrack.hidden
    )
    let replacementSequence = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: [replacementTrack] + sequence.videoTracks.dropFirst(),
        audioTracks: sequence.audioTracks,
        markers: sequence.markers,
        timebase: sequence.timebase
    )

    return Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: [replacementSequence] + project.sequences.dropFirst()
    )
}

private func replacingFirstCodecClipEffects(
    in project: Project,
    with effects: ClipEffects
) throws -> Project {
    let sequence = try XCTUnwrap(project.sequences.first)
    let videoTrack = try XCTUnwrap(sequence.videoTracks.first)
    let originalClip = try XCTUnwrap(clip(in: videoTrack))
    let effectsClip = Clip(
        id: originalClip.id,
        source: originalClip.source,
        sourceRange: originalClip.sourceRange,
        timelineRange: originalClip.timelineRange,
        kind: originalClip.kind,
        name: originalClip.name,
        linkGroupID: originalClip.linkGroupID,
        transform: originalClip.transform,
        transformAnimation: originalClip.transformAnimation,
        effects: effects
    )
    let replacementTrack = Track(
        id: videoTrack.id,
        kind: videoTrack.kind,
        items: videoTrack.items.map { item in
            if case .clip(let currentClip) = item, currentClip.id == originalClip.id {
                return .clip(effectsClip)
            }
            return item
        },
        enabled: videoTrack.enabled,
        locked: videoTrack.locked,
        muted: videoTrack.muted,
        solo: videoTrack.solo,
        hidden: videoTrack.hidden
    )
    let replacementSequence = Sequence(
        id: sequence.id,
        name: sequence.name,
        videoTracks: [replacementTrack] + sequence.videoTracks.dropFirst(),
        audioTracks: sequence.audioTracks,
        markers: sequence.markers,
        timebase: sequence.timebase
    )

    return Project(
        schemaVersion: project.schemaVersion,
        settings: project.settings,
        mediaPool: project.mediaPool,
        sequences: [replacementSequence] + project.sequences.dropFirst()
    )
}

private func makeCodecClipEffects() throws -> ClipEffects {
    ClipEffects(
        chromaKey: ClipChromaKeySettings(
            enabled: true,
            keyColor: ClipRGBColor(
                red: try RationalValue(numerator: 1, denominator: 10),
                green: try RationalValue(numerator: 9, denominator: 10),
                blue: try RationalValue(numerator: 1, denominator: 5)
            ),
            tolerance: try RationalValue(numerator: 1, denominator: 4),
            edgeSoftness: try RationalValue(numerator: 1, denominator: 8),
            spillSuppression: try RationalValue(numerator: 3, denominator: 5)
        )
    )
}

private func makeCodecClipMaskEffects() throws -> ClipEffects {
    ClipEffects(
        chromaKey: try makeCodecClipEffects().chromaKey,
        masks: [
            ClipMask(
                id: try codecUUID(196_100),
                shape: .rectangle(
                    ClipRectangleMask(
                        x: .zero,
                        y: .zero,
                        width: RationalValue(16),
                        height: RationalValue(9)
                    )
                ),
                featherRadius: try RationalValue(numerator: 1, denominator: 2)
            ),
            ClipMask(
                id: try codecUUID(196_101),
                shape: .ellipse(
                    ClipEllipseMask(
                        centerX: RationalValue(8),
                        centerY: RationalValue(4),
                        radiusX: RationalValue(4),
                        radiusY: RationalValue(2)
                    )
                ),
                invert: true,
                combine: .subtract
            ),
            ClipMask(
                id: try codecUUID(196_102),
                shape: .polygon(
                    ClipPolygonMask(
                        points: [
                            CanvasPoint(x: .zero, y: .zero),
                            CanvasPoint(x: RationalValue(16), y: .zero),
                            CanvasPoint(x: RationalValue(8), y: RationalValue(9))
                        ]
                    )
                ),
                combine: .intersect
            )
        ]
    )
}

private func makeCodecProject(
    seed: Int,
    schemaVersion: Int = AjarProjectCodec.currentSchemaVersion
) throws -> Project {
    let firstMediaID = try codecUUID(seed * 1_000 + 1)
    let secondMediaID = try codecUUID(seed * 1_000 + 2)
    let videoTrackID = try codecUUID(seed * 1_000 + 4)
    let audioTrackID = try codecUUID(seed * 1_000 + 5)
    let firstClipID = try codecUUID(seed * 1_000 + 6)
    let secondClipID = try codecUUID(seed * 1_000 + 7)
    let linkGroupID = try codecUUID(seed * 1_000 + 9)
    let mediaPool = try makeCodecMediaPool(
        seed: seed,
        firstMediaID: firstMediaID,
        secondMediaID: secondMediaID
    )
    let firstClip = TimelineItem.clip(
        try makeCodecClip(
            id: firstClipID,
            mediaID: firstMediaID,
            startFrame: 0,
            linkGroupID: linkGroupID
        )
    )
    let secondClip = TimelineItem.clip(
        try makeCodecClip(
            id: secondClipID,
            mediaID: secondMediaID,
            startFrame: 12
        )
    )
    let videoTrack = Track(
        id: videoTrackID,
        kind: .video,
        items: [firstClip, secondClip]
    )
    let audioTrack = try makeCodecLinkedAudioTrack(
        id: audioTrackID,
        clipID: try codecUUID(seed * 1_000 + 10),
        mediaID: firstMediaID,
        linkGroupID: linkGroupID
    )
    let marker = Marker(
        id: try codecUUID(seed * 1_000 + 8),
        time: try codecTime(4),
        name: "FR-PROJ marker",
        color: .orange,
        note: "FR-TL-008 marker note",
        anchor: .clip(trackID: videoTrackID, clipID: firstClipID)
    )
    let sequence = Sequence(
        id: try codecUUID(seed * 1_000 + 3),
        name: "Codec Sequence \(seed)",
        videoTracks: [videoTrack],
        audioTracks: [audioTrack],
        markers: [marker],
        timebase: try FrameRate(frames: 24)
    )

    return Project(
        schemaVersion: schemaVersion,
        settings: try makeCodecSettings(),
        mediaPool: mediaPool,
        sequences: [sequence]
    )
}

private func makeCodecMediaPool(
    seed: Int,
    firstMediaID: UUID,
    secondMediaID: UUID
) throws -> [MediaRef] {
    [
        try makeCodecMediaRef(id: firstMediaID, seed: seed),
        try makeCodecMediaRef(id: secondMediaID, seed: seed + 1)
    ]
}

private func makeCodecLinkedAudioTrack(
    id: UUID,
    clipID: UUID,
    mediaID: UUID,
    linkGroupID: UUID
) throws -> Track {
    Track(
        id: id,
        kind: .audio,
        items: [
            .clip(
                try makeCodecClip(
                    id: clipID,
                    mediaID: mediaID,
                    startFrame: 0,
                    kind: .audio,
                    linkGroupID: linkGroupID
                )
            )
        ]
    )
}

private func makeCodecSettings() throws -> ProjectSettings {
    ProjectSettings(
        frameRate: try FrameRate(frames: 24),
        resolution: PixelDimensions(width: 1_920, height: 1_080),
        colorSpace: .rec709,
        audioSampleRate: 48_000
    )
}

private func makeCodecMediaRef(id: UUID, seed: Int) throws -> MediaRef {
    MediaRef(
        id: id,
        sourceURL: URL(fileURLWithPath: "/media/codec-\(seed).mov"),
        bookmark: Data([UInt8(seed % 255)]),
        contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
        metadata: MediaMetadata(
            codecID: "h264",
            pixelDimensions: PixelDimensions(width: 1_920, height: 1_080),
            frameRate: try FrameRate(frames: 24),
            duration: try codecTime(240),
            colorSpace: .rec709,
            audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
            isVariableFrameRate: false,
            conformedFrameRate: nil
        )
    )
}

private func makeCodecClip(
    id: UUID,
    mediaID: UUID,
    startFrame: Int64,
    kind: TrackKind = .video,
    linkGroupID: UUID? = nil
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try codecRange(startFrame: 0, durationFrames: 10),
        timelineRange: try codecRange(startFrame: startFrame, durationFrames: 10),
        kind: kind,
        name: "Codec Clip \(id.uuidString)",
        linkGroupID: linkGroupID
    )
}

private func clip(in track: Track?) -> Clip? {
    guard let track else {
        return nil
    }
    for item in track.items {
        if case .clip(let clip) = item {
            return clip
        }
    }
    return nil
}

private func codecRange(startFrame: Int64, durationFrames: Int64) throws -> TimeRange {
    try TimeRange(start: codecTime(startFrame), duration: codecTime(durationFrames))
}

private func codecTime(_ frame: Int64) throws -> RationalTime {
    try RationalTime(value: frame, timescale: 24)
}

private func codecUUID(_ value: Int) throws -> UUID {
    let uuidString = String(format: "00000000-0000-0000-0000-%012d", value)
    return try XCTUnwrap(UUID(uuidString: uuidString))
}
