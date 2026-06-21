// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Bytes and metadata for an auto-save recovery checkpoint.
public struct AjarAutosaveSnapshot: Equatable, Sendable {
    /// Canonical project package bytes for the checkpoint.
    public let package: AjarProjectPackageData

    /// Highest command sequence number already represented by the checkpoint.
    public let appliedCommandCount: Int

    /// Creates a recovery checkpoint.
    public init(package: AjarProjectPackageData, appliedCommandCount: Int) {
        self.package = package
        self.appliedCommandCount = max(0, appliedCommandCount)
    }
}

/// One append-only recovery journal record.
public struct AjarAutosaveJournalEntry: Codable, Equatable, Sendable {
    /// Monotonic command sequence number for ordering and duplicate suppression.
    public let sequenceNumber: Int

    /// Edit command to replay after the checkpoint snapshot.
    public let command: EditCommand

    /// Creates a journal record.
    public init(sequenceNumber: Int, command: EditCommand) {
        self.sequenceNumber = sequenceNumber
        self.command = command
    }
}

/// Typed best-effort recovery issues. These are reported instead of trapping on bad journals.
public enum AjarRecoveryIssue: Error, Equatable, Sendable {
    /// A journal line could not be decoded, often because it was truncated during a crash.
    case malformedJournalEntry(line: Int, reason: String)

    /// The journal skipped a command sequence number.
    case nonContiguousJournalEntry(expected: Int, found: Int)

    /// A decoded command could not be replayed against the current best-known project.
    case commandReplayFailed(sequenceNumber: Int, reason: String)
}

/// Result of pure snapshot + journal recovery.
public struct AjarRecoveryResult: Equatable, Sendable {
    /// Latest project reconstructed from the snapshot and all valid journal entries.
    public let project: Project

    /// Number of journal entries replayed after the snapshot.
    public let appliedJournalEntryCount: Int

    /// Highest command sequence number represented by `project`.
    public let latestCommandCount: Int

    /// Non-empty when recovery stopped at the last known-good state.
    public let issues: [AjarRecoveryIssue]

    /// Whether recovery consumed the complete journal without warnings.
    public var isComplete: Bool {
        issues.isEmpty
    }

    /// Creates a recovery result.
    public init(
        project: Project,
        appliedJournalEntryCount: Int,
        latestCommandCount: Int,
        issues: [AjarRecoveryIssue]
    ) {
        self.project = project
        self.appliedJournalEntryCount = appliedJournalEntryCount
        self.latestCommandCount = latestCommandCount
        self.issues = issues
    }
}

/// Pure recovery and durable package helpers for FR-TL-014 / NFR-STAB-002.
public enum AjarAutosaveStore {
    /// Current recovery manifest schema version.
    public static let manifestSchemaVersion = 1

    /// Returns the package URL for the recovery journal.
    public static func journalURL(in packageURL: URL) -> URL {
        recoveryDirectoryURL(in: packageURL).appendingPathComponent("edit-journal.jsonl")
    }

    /// Returns whether a package has the minimum files needed for recovery.
    public static func hasRecoverableSnapshot(
        at packageURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        if fileManager.isReadableFile(atPath: recoverySnapshotURL(in: packageURL).path) {
            return true
        }
        return fileManager.isReadableFile(atPath: projectURL(in: packageURL).path)
            && fileManager.isReadableFile(atPath: mediaURL(in: packageURL).path)
    }

    /// Writes the canonical project snapshot and recovery manifest with atomic file replacement.
    public static func writeSnapshot(
        _ project: Project,
        appliedCommandCount: Int,
        to packageURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let package = try AjarProjectCodec.encode(project)
        try createPackageDirectories(at: packageURL, fileManager: fileManager)
        try AjarAtomicFileWriter.write(
            package.projectJSON,
            to: projectURL(in: packageURL),
            fileManager: fileManager
        )
        try AjarAtomicFileWriter.write(
            package.mediaJSON,
            to: mediaURL(in: packageURL),
            fileManager: fileManager
        )
        try AjarAtomicFileWriter.write(
            try encodeManifest(
                AjarAutosaveManifest(
                    schemaVersion: manifestSchemaVersion,
                    snapshotCommandCount: max(0, appliedCommandCount)
                )
            ),
            to: manifestURL(in: packageURL),
            fileManager: fileManager
        )
        try AjarAtomicFileWriter.write(
            try encodeSnapshotEnvelope(
                projectPackage: package,
                appliedCommandCount: appliedCommandCount
            ),
            to: recoverySnapshotURL(in: packageURL),
            fileManager: fileManager
        )
    }

    /// Reads the canonical project snapshot and recovery manifest.
    public static func readSnapshot(
        from packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> AjarAutosaveSnapshot {
        if fileManager.isReadableFile(atPath: recoverySnapshotURL(in: packageURL).path) {
            return try readSnapshotEnvelope(from: packageURL)
        }

        let projectData = try readRequiredFile(
            at: projectURL(in: packageURL),
            relativePath: "project.json",
            fileManager: fileManager
        )
        let mediaData = try readRequiredFile(
            at: mediaURL(in: packageURL),
            relativePath: "media.json",
            fileManager: fileManager
        )
        let manifest = try readManifest(from: packageURL, fileManager: fileManager)
        return AjarAutosaveSnapshot(
            package: AjarProjectPackageData(projectJSON: projectData, mediaJSON: mediaData),
            appliedCommandCount: manifest.snapshotCommandCount
        )
    }

    /// Appends a command to the recovery journal as a numbered record.
    public static func appendJournalEntry(
        command: EditCommand,
        sequenceNumber: Int,
        to packageURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try createPackageDirectories(at: packageURL, fileManager: fileManager)
        let url = journalURL(in: packageURL)
        var data: Data
        if fileManager.fileExists(atPath: url.path) {
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw AjarAutosaveStoreError.fileReadFailed(
                    path: url.path,
                    reason: String(describing: error)
                )
            }
        } else {
            data = Data()
        }
        data.append(
            try AjarAutosaveJournalCodec.encodeLine(
                AjarAutosaveJournalEntry(
                    sequenceNumber: max(1, sequenceNumber),
                    command: command
                )
            )
        )
        try AjarAtomicFileWriter.write(data, to: url, fileManager: fileManager)
    }

    /// Replaces the recovery journal, useful for compaction and deterministic tests.
    public static func replaceJournal(
        with entries: [AjarAutosaveJournalEntry],
        in packageURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try createPackageDirectories(at: packageURL, fileManager: fileManager)
        try AjarAtomicFileWriter.write(
            try AjarAutosaveJournalCodec.encode(entries),
            to: journalURL(in: packageURL),
            fileManager: fileManager
        )
    }

    /// Recovers the latest project from a package snapshot and its journal.
    public static func recoverProject(
        from packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> AjarRecoveryResult {
        let snapshot = try readSnapshot(from: packageURL, fileManager: fileManager)
        let journalData: Data
        let url = journalURL(in: packageURL)
        if fileManager.fileExists(atPath: url.path) {
            do {
                journalData = try Data(contentsOf: url)
            } catch {
                throw AjarAutosaveStoreError.fileReadFailed(
                    path: url.path,
                    reason: String(describing: error)
                )
            }
        } else {
            journalData = Data()
        }
        return try recover(snapshot: snapshot, journalData: journalData)
    }

    /// Pure recovery: snapshot + journal bytes to latest project, with typed best-effort issues.
    public static func recover(
        snapshot: AjarAutosaveSnapshot,
        journalData: Data
    ) throws -> AjarRecoveryResult {
        var currentProject = try decodeProject(from: snapshot)
        var latestCommandCount = snapshot.appliedCommandCount
        var appliedJournalEntryCount = 0

        let lines = journalData.split(separator: 0x0A, omittingEmptySubsequences: false)
        for indexedLine in lines.enumerated() {
            guard !indexedLine.element.isEmpty else {
                continue
            }

            let entry: AjarAutosaveJournalEntry
            switch decodeJournalEntry(
                lineData: Data(indexedLine.element),
                lineNumber: indexedLine.offset + 1
            ) {
            case .success(let journalEntry):
                entry = journalEntry
            case .failure(let issue):
                return recoveryResult(
                    project: currentProject,
                    appliedJournalEntryCount: appliedJournalEntryCount,
                    latestCommandCount: latestCommandCount,
                    issues: [issue]
                )
            }

            if entry.sequenceNumber <= snapshot.appliedCommandCount {
                continue
            }

            let expectedSequenceNumber = latestCommandCount + 1
            guard entry.sequenceNumber == expectedSequenceNumber else {
                return recoveryResult(
                    project: currentProject,
                    appliedJournalEntryCount: appliedJournalEntryCount,
                    latestCommandCount: latestCommandCount,
                    issues: [
                        .nonContiguousJournalEntry(
                            expected: expectedSequenceNumber,
                            found: entry.sequenceNumber
                        )
                    ]
                )
            }

            switch replay(entry, to: currentProject) {
            case .success(let replayedProject):
                currentProject = replayedProject
                latestCommandCount = entry.sequenceNumber
                appliedJournalEntryCount += 1
            case .failure(let issue):
                return recoveryResult(
                    project: currentProject,
                    appliedJournalEntryCount: appliedJournalEntryCount,
                    latestCommandCount: latestCommandCount,
                    issues: [issue]
                )
            }
        }

        return recoveryResult(
            project: currentProject,
            appliedJournalEntryCount: appliedJournalEntryCount,
            latestCommandCount: latestCommandCount,
            issues: []
        )
    }

    static func projectURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent("project.json")
    }

    static func mediaURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent("media.json")
    }

    static func recoveryDirectoryURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent("recovery", isDirectory: true)
    }

    static func manifestURL(in packageURL: URL) -> URL {
        recoveryDirectoryURL(in: packageURL).appendingPathComponent("manifest.json")
    }

    static func recoverySnapshotURL(in packageURL: URL) -> URL {
        recoveryDirectoryURL(in: packageURL).appendingPathComponent("snapshot.json")
    }

    static func versionsDirectoryURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent("versions", isDirectory: true)
    }
}

private struct AjarAutosaveManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let snapshotCommandCount: Int
}

private struct AjarAutosaveSnapshotEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let snapshotCommandCount: Int
    let projectJSON: Data
    let mediaJSON: Data
}

private extension AjarAutosaveStore {
    static func createPackageDirectories(at packageURL: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: recoveryDirectoryURL(in: packageURL),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: versionsDirectoryURL(in: packageURL),
            withIntermediateDirectories: true
        )
    }

    static func readRequiredFile(
        at url: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> Data {
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw AjarAutosaveStoreError.missingPackageFile(relativePath)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AjarAutosaveStoreError.fileReadFailed(
                path: url.path,
                reason: String(describing: error)
            )
        }
    }

    static func readManifest(
        from packageURL: URL,
        fileManager: FileManager
    ) throws -> AjarAutosaveManifest {
        let url = manifestURL(in: packageURL)
        guard fileManager.fileExists(atPath: url.path) else {
            return AjarAutosaveManifest(
                schemaVersion: manifestSchemaVersion,
                snapshotCommandCount: 0
            )
        }

        do {
            return try AjarAutosaveJournalCodec.decoder().decode(
                AjarAutosaveManifest.self,
                from: try Data(contentsOf: url)
            )
        } catch {
            throw AjarAutosaveStoreError.malformedManifest(String(describing: error))
        }
    }

    static func encodeManifest(_ manifest: AjarAutosaveManifest) throws -> Data {
        do {
            return try AjarAutosaveJournalCodec.encoder().encode(manifest)
        } catch {
            throw AjarAutosaveStoreError.encodingFailed(String(describing: error))
        }
    }

    static func readSnapshotEnvelope(from packageURL: URL) throws -> AjarAutosaveSnapshot {
        do {
            let envelope = try AjarAutosaveJournalCodec.decoder().decode(
                AjarAutosaveSnapshotEnvelope.self,
                from: try Data(contentsOf: recoverySnapshotURL(in: packageURL))
            )
            return AjarAutosaveSnapshot(
                package: AjarProjectPackageData(
                    projectJSON: envelope.projectJSON,
                    mediaJSON: envelope.mediaJSON
                ),
                appliedCommandCount: envelope.snapshotCommandCount
            )
        } catch {
            throw AjarAutosaveStoreError.malformedSnapshot(String(describing: error))
        }
    }

    static func encodeSnapshotEnvelope(
        projectPackage: AjarProjectPackageData,
        appliedCommandCount: Int
    ) throws -> Data {
        do {
            return try AjarAutosaveJournalCodec.encoder().encode(
                AjarAutosaveSnapshotEnvelope(
                    schemaVersion: manifestSchemaVersion,
                    snapshotCommandCount: max(0, appliedCommandCount),
                    projectJSON: projectPackage.projectJSON,
                    mediaJSON: projectPackage.mediaJSON
                )
            )
        } catch {
            throw AjarAutosaveStoreError.encodingFailed(String(describing: error))
        }
    }

    static func decodeProject(from snapshot: AjarAutosaveSnapshot) throws -> Project {
        switch try AjarProjectCodec.decode(
            projectJSON: snapshot.package.projectJSON,
            mediaJSON: snapshot.package.mediaJSON
        ) {
        case .editable(let editableProject), .readOnly(let editableProject, _):
            return editableProject
        }
    }

    static func decodeJournalEntry(
        lineData: Data,
        lineNumber: Int
    ) -> Result<AjarAutosaveJournalEntry, AjarRecoveryIssue> {
        do {
            return .success(try AjarAutosaveJournalCodec.decodeLine(lineData))
        } catch {
            return .failure(
                .malformedJournalEntry(line: lineNumber, reason: String(describing: error))
            )
        }
    }

    static func replay(
        _ entry: AjarAutosaveJournalEntry,
        to project: Project
    ) -> Result<Project, AjarRecoveryIssue> {
        do {
            return .success(try apply(entry.command, to: project))
        } catch {
            return .failure(
                .commandReplayFailed(
                    sequenceNumber: entry.sequenceNumber,
                    reason: String(describing: error)
                )
            )
        }
    }

    static func recoveryResult(
        project: Project,
        appliedJournalEntryCount: Int,
        latestCommandCount: Int,
        issues: [AjarRecoveryIssue]
    ) -> AjarRecoveryResult {
        AjarRecoveryResult(
            project: project,
            appliedJournalEntryCount: appliedJournalEntryCount,
            latestCommandCount: latestCommandCount,
            issues: issues
        )
    }
}
