// SPDX-License-Identifier: GPL-3.0-or-later

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

private func makeCodecProject(seed: Int, schemaVersion: Int = 1) throws -> Project {
    let firstMediaID = try codecUUID(seed * 1_000 + 1)
    let secondMediaID = try codecUUID(seed * 1_000 + 2)
    let sequenceID = try codecUUID(seed * 1_000 + 3)
    let videoTrackID = try codecUUID(seed * 1_000 + 4)
    let audioTrackID = try codecUUID(seed * 1_000 + 5)
    var mediaPool: [MediaRef] = []
    mediaPool.append(try makeCodecMediaRef(id: firstMediaID, seed: seed))
    mediaPool.append(try makeCodecMediaRef(id: secondMediaID, seed: seed + 1))
    let firstClip = TimelineItem.clip(
        try makeCodecClip(
            id: try codecUUID(seed * 1_000 + 6),
            mediaID: firstMediaID,
            startFrame: 0
        )
    )
    let secondClip = TimelineItem.clip(
        try makeCodecClip(
            id: try codecUUID(seed * 1_000 + 7),
            mediaID: secondMediaID,
            startFrame: 12
        )
    )
    let videoTrack = Track(
        id: videoTrackID,
        kind: .video,
        items: [firstClip, secondClip]
    )
    let audioTrack = Track(id: audioTrackID, kind: .audio, items: [])
    let marker = Marker(
        id: try codecUUID(seed * 1_000 + 8),
        time: try codecTime(4),
        name: "FR-PROJ marker"
    )
    let sequence = Sequence(
        id: sequenceID,
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
    startFrame: Int64
) throws -> Clip {
    Clip(
        id: id,
        source: .media(id: mediaID),
        sourceRange: try codecRange(startFrame: 0, durationFrames: 10),
        timelineRange: try codecRange(startFrame: startFrame, durationFrames: 10),
        kind: .video,
        name: "Codec Clip \(id.uuidString)"
    )
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
