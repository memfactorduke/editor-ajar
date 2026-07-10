// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarCLI

final class ProjectPackageOpenModeTests: XCTestCase {
    /// CLI write paths refuse higher-minor (read-only) projects with a typed message (#196).
    func testFRPROJ005Issue196WritePathAgainstHigherMinorRefusesWithTypedMessage() throws {
        let directory = try temporaryDirectory()
        let editableURL = directory.appendingPathComponent("editable.ajar", isDirectory: true)
        let higherMinorURL = directory.appendingPathComponent(
            "higher-minor.ajar",
            isDirectory: true
        )
        let higherMinor = AjarProjectCodec.currentSchemaMinor + 7
        let reason = AjarProjectReadOnlyReason.newerSchemaMinor(
            found: higherMinor,
            supported: AjarProjectCodec.currentSchemaMinor
        )
        let project = try makeMinimalCLIProject(seedName: "ReadOnlyWrite")

        // New-document write still works (editable).
        try ProjectPackageIO.writeProject(project, to: editableURL)
        let editableLoad = try ProjectPackageIO.loadProject(from: editableURL)
        XCTAssertEqual(editableLoad.openMode, .editable)

        // Explicit open-mode write path blocks read-only.
        XCTAssertThrowsError(
            try ProjectPackageIO.writeProject(
                project,
                openMode: .readOnly(reason: reason),
                to: higherMinorURL
            )
        ) { error in
            guard case AjarCLIError.projectWriteBlockedReadOnly(let blocked) = error else {
                return XCTFail("Expected projectWriteBlockedReadOnly, got \(error)")
            }
            XCTAssertEqual(blocked, reason)
            let description = (error as? AjarCLIError)?.description ?? ""
            XCTAssertTrue(description.contains("read-only"))
            XCTAssertTrue(description.contains("\(higherMinor)"))
            XCTAssertTrue(description.contains(reason.message))
        }

        // Higher-minor package via bare project/media JSON (no recovery envelope that would
        // still carry the current minor from an earlier writeSnapshot).
        try writeHigherMinorCLIPackage(
            project: project,
            schemaMinor: higherMinor,
            to: higherMinorURL
        )

        let loaded = try ProjectPackageIO.loadProject(from: higherMinorURL)
        XCTAssertEqual(loaded.openMode, .readOnly(reason: reason))
        XCTAssertThrowsError(
            try ProjectPackageIO.writeProject(loaded, to: higherMinorURL)
        ) { error in
            guard case AjarCLIError.projectWriteBlockedReadOnly(let blocked) = error else {
                return XCTFail("Expected projectWriteBlockedReadOnly, got \(error)")
            }
            XCTAssertEqual(blocked, reason)
        }
    }

    /// CLI read paths accept same-major / higher-minor packages (non-destructive; FR-PROJ-005 / #196).
    func testFRPROJ005Issue196ReadPathsAcceptNewerMinor() throws {
        let directory = try temporaryDirectory()
        let packageURL = directory.appendingPathComponent(
            "higher-minor-read.ajar",
            isDirectory: true
        )
        let higherMinor = AjarProjectCodec.currentSchemaMinor + 1
        let reason = AjarProjectReadOnlyReason.newerSchemaMinor(
            found: higherMinor,
            supported: AjarProjectCodec.currentSchemaMinor
        )
        let project = try makeMinimalCLIProject(seedName: "ReadOnlyRead")
        try writeHigherMinorCLIPackage(
            project: project,
            schemaMinor: higherMinor,
            to: packageURL
        )

        // Load is the CLI read entry point used by render / bench / golden.
        let loaded = try ProjectPackageIO.loadProject(from: packageURL)
        XCTAssertEqual(loaded.openMode, .readOnly(reason: reason))
        XCTAssertEqual(loaded.project.schemaMinor, higherMinor)

        let sequence = try XCTUnwrap(loaded.project.sequences.first)
        let renderTime = try RationalTime.atFrame(0, frameRate: loaded.project.settings.frameRate)
        // Decode + graph-build is the Metal-free half of `ajar render` (before GPU).
        let graph = try buildRenderGraph(
            for: sequence,
            at: renderTime,
            in: loaded.project
        )
        XCTAssertNotNil(graph.outputNode)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-cli-open-mode-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func writeHigherMinorCLIPackage(
        project: Project,
        schemaMinor: Int,
        to packageURL: URL
    ) throws {
        let document = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: schemaMinor,
            settings: project.settings,
            mediaPool: [],
            sequences: project.sequences,
            looks: project.looks
        )
        let manifest = AjarMediaManifest(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: schemaMinor,
            media: project.mediaPool
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try encoder.encode(document).write(to: packageURL.appendingPathComponent("project.json"))
        try encoder.encode(manifest).write(to: packageURL.appendingPathComponent("media.json"))
    }

    private func makeMinimalCLIProject(seedName: String) throws -> Project {
        let frameRate = try FrameRate(frames: 24)
        let duration = try frameRate.duration(ofFrames: 24)
        let mediaID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000c001"))
        let media = MediaRef(
            id: mediaID,
            sourceURL: URL(fileURLWithPath: "/tmp/editor-ajar-cli-readonly-\(seedName).mov"),
            contentHash: ContentHash.sha256(data: Data(seedName.utf8)),
            metadata: MediaMetadata(
                codecID: "prores422",
                pixelDimensions: PixelDimensions(width: 16, height: 16),
                frameRate: frameRate,
                duration: duration,
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let clip = Clip(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000c002")),
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .video,
            name: seedName
        )
        let sequence = Sequence(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000c003")),
            name: seedName,
            videoTracks: [
                Track(
                    id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000c004")),
                    kind: .video,
                    items: [.clip(clip)]
                )
            ],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            schemaMinor: AjarProjectCodec.currentSchemaMinor,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 16, height: 16),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
    }
}
