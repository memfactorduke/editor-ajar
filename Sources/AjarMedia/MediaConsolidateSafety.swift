// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum ConsolidateStalePartialRemovalError: Error {
    case unsafeEntryChanged(URL)
    case ownershipUnavailable(URL)
    case invalidRecoveryEvidence(URL)
    case recoveryCollision(original: URL, quarantine: URL)
    case operationFailed(operation: String, url: URL, code: Int32)
    case restoreFailed(url: URL, code: Int32)

    var affectedURL: URL? {
        switch self {
        case .unsafeEntryChanged(let url), .ownershipUnavailable(let url),
            .invalidRecoveryEvidence(let url), .restoreFailed(let url, _),
            .operationFailed(_, let url, _):
            return url
        case .recoveryCollision(let original, _):
            return original
        }
    }
}

func isOwnedConsolidatePartialFileName(_ name: String) -> Bool {
    let prefix = ".ajar-partial-"
    guard name.hasPrefix(prefix) else { return false }
    let identifier = String(name.dropFirst(prefix.count))
    return identifier.count == 36 && UUID(uuidString: identifier) != nil
}

struct ConsolidateStalePartialRemover {
    typealias InspectionHook = (URL) throws -> Void
    typealias QuarantineHook = (_ originalURL: URL, _ quarantineURL: URL) throws -> Void
    typealias DirectorySync = (_ descriptor: Int32, _ directoryURL: URL) throws -> Void
    typealias FinalRemovalGuard = (ConsolidateFileIdentity) throws -> Void

    private let inspectionHook: InspectionHook?
    private let quarantineHook: QuarantineHook?
    private let directorySync: DirectorySync
    private let finalRemovalGuard: FinalRemovalGuard?

    init(
        inspectionHook: InspectionHook? = nil,
        quarantineHook: QuarantineHook? = nil,
        directorySync: DirectorySync? = nil,
        finalRemovalGuard: FinalRemovalGuard? = nil
    ) {
        self.inspectionHook = inspectionHook
        self.quarantineHook = quarantineHook
        self.finalRemovalGuard = finalRemovalGuard
        self.directorySync =
            directorySync ?? { descriptor, directoryURL in
                guard fsync(descriptor) == 0 else {
                    throw ConsolidateStalePartialRemovalError.operationFailed(
                        operation: "synchronize directory",
                        url: directoryURL,
                        code: errno
                    )
                }
            }
    }

    func recoverInterruptedRemovals(in directoryURL: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for recordURL in entries {
            guard recoveryIdentifier(from: recordURL.lastPathComponent) != nil else { continue }
            try recover(recordURL: recordURL, directoryURL: directoryURL)
        }
    }

    func removeRegularFile(
        at candidateURL: URL,
        expectedIdentity: ConsolidateFileIdentity? = nil
    ) throws -> Bool {
        guard isOwnedConsolidatePartialFileName(candidateURL.lastPathComponent) else {
            throw ConsolidateStalePartialRemovalError.unsafeEntryChanged(candidateURL)
        }
        let directoryURL = candidateURL.deletingLastPathComponent()
        let directoryDescriptor = directoryURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw operationError("open directory", url: directoryURL)
        }
        defer { Darwin.close(directoryDescriptor) }

        let candidateName = candidateURL.lastPathComponent
        guard
            let originalIdentity = try identityIfPresent(
                named: candidateName,
                in: directoryDescriptor,
                url: candidateURL
            ),
            originalIdentity.isRegularFile
        else {
            return false
        }
        if let expectedIdentity {
            guard sameRegularFile(originalIdentity, expectedIdentity) else {
                throw ConsolidateStalePartialRemovalError.unsafeEntryChanged(candidateURL)
            }
        }
        try inspectionHook?(candidateURL)
        return try quarantineAndRemove(
            candidateURL: candidateURL,
            directoryURL: directoryURL,
            directoryDescriptor: directoryDescriptor,
            originalIdentity: originalIdentity
        )
    }

    private func quarantineAndRemove(
        candidateURL: URL,
        directoryURL: URL,
        directoryDescriptor: Int32,
        originalIdentity: ConsolidateFileIdentity
    ) throws -> Bool {
        let candidateName = candidateURL.lastPathComponent
        let recoveryID = UUID().uuidString.lowercased()
        let quarantineName = ".ajar-quarantine-\(recoveryID).data"
        let recordName = ".ajar-quarantine-\(recoveryID).json"
        let record = ConsolidateQuarantineRecord(
            originalName: candidateName,
            quarantineName: quarantineName,
            expectedIdentity: originalIdentity
        )
        try publishRecord(
            record,
            named: recordName,
            directoryDescriptor: directoryDescriptor,
            directoryURL: directoryURL
        )
        do {
            try renameExclusive(
                from: candidateName,
                to: quarantineName,
                in: directoryDescriptor,
                url: candidateURL
            )
        } catch {
            let quarantineError = error
            try unlink(named: recordName, in: directoryDescriptor)
            throw quarantineError
        }
        try synchronizeDirectory(directoryDescriptor, at: directoryURL)
        let quarantineURL = directoryURL.appendingPathComponent(quarantineName)
        try quarantineHook?(candidateURL, quarantineURL)
        do {
            let quarantinedIdentity = try verifiedIdentity(
                originalIdentity,
                named: quarantineName,
                directoryDescriptor: directoryDescriptor,
                url: quarantineURL
            )
            try finalRemovalGuard?(quarantinedIdentity)
            _ = try verifiedIdentity(
                originalIdentity,
                named: quarantineName,
                directoryDescriptor: directoryDescriptor,
                url: quarantineURL
            )
            try unlink(named: quarantineName, in: directoryDescriptor)
            try unlink(named: recordName, in: directoryDescriptor)
        } catch {
            let underlyingError = error
            try restoreOrPreserve(
                quarantineName: quarantineName,
                candidateName: candidateName,
                recordName: recordName,
                directoryDescriptor: directoryDescriptor,
                candidateURL: candidateURL
            )
            throw underlyingError
        }
        return true
    }
}

private extension ConsolidateStalePartialRemover {
    private func recover(recordURL: URL, directoryURL: URL) throws {
        let descriptor = directoryURL.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw operationError("open directory", url: directoryURL) }
        defer { Darwin.close(descriptor) }

        let record = try readRecord(
            named: recordURL.lastPathComponent,
            in: descriptor,
            url: recordURL
        )
        guard
            record.version == 1,
            isOwnedConsolidatePartialFileName(record.originalName),
            let recordID = recoveryIdentifier(from: recordURL.lastPathComponent),
            record.quarantineName == ".ajar-quarantine-\(recordID).data"
        else {
            throw ConsolidateStalePartialRemovalError.invalidRecoveryEvidence(recordURL)
        }

        let originalURL = directoryURL.appendingPathComponent(record.originalName)
        let quarantineURL = directoryURL.appendingPathComponent(record.quarantineName)
        let quarantined = try identityIfPresent(
            named: record.quarantineName,
            in: descriptor,
            url: quarantineURL
        )
        let original = try identityIfPresent(
            named: record.originalName,
            in: descriptor,
            url: originalURL
        )
        let originalMatchesExpected =
            original.map {
                sameRegularFile($0, record.expectedIdentity)
            } == true
        if let quarantined {
            guard sameRegularFile(quarantined, record.expectedIdentity) else {
                throw ConsolidateStalePartialRemovalError.invalidRecoveryEvidence(recordURL)
            }
            guard original == nil else {
                throw ConsolidateStalePartialRemovalError.recoveryCollision(
                    original: originalURL,
                    quarantine: quarantineURL
                )
            }
            try renameExclusive(
                from: record.quarantineName,
                to: record.originalName,
                in: descriptor,
                url: originalURL
            )
            try synchronizeDirectory(descriptor, at: directoryURL)
            try unlink(named: recordURL.lastPathComponent, in: descriptor)
        } else if original == nil || originalMatchesExpected {
            try unlink(named: recordURL.lastPathComponent, in: descriptor)
        } else {
            throw ConsolidateStalePartialRemovalError.invalidRecoveryEvidence(recordURL)
        }
    }

    private func verifiedIdentity(
        _ expectedIdentity: ConsolidateFileIdentity,
        named name: String,
        directoryDescriptor: Int32,
        url: URL
    ) throws -> ConsolidateFileIdentity {
        guard
            let current = try identityIfPresent(
                named: name,
                in: directoryDescriptor,
                url: url
            ), sameRegularFile(current, expectedIdentity)
        else {
            throw ConsolidateStalePartialRemovalError.unsafeEntryChanged(url)
        }
        return current
    }

    private func sameRegularFile(
        _ first: ConsolidateFileIdentity,
        _ second: ConsolidateFileIdentity
    ) -> Bool {
        first.isRegularFile
            && second.isRegularFile
            && first.objectIdentity == second.objectIdentity
    }

    private func restoreOrPreserve(
        quarantineName: String,
        candidateName: String,
        recordName: String,
        directoryDescriptor: Int32,
        candidateURL: URL
    ) throws {
        let quarantineURL = candidateURL.deletingLastPathComponent()
            .appendingPathComponent(quarantineName)
        do {
            try renameExclusive(
                from: quarantineName,
                to: candidateName,
                in: directoryDescriptor,
                url: candidateURL
            )
            try synchronizeDirectory(
                directoryDescriptor,
                at: candidateURL.deletingLastPathComponent()
            )
            try unlink(named: recordName, in: directoryDescriptor)
        } catch {
            throw ConsolidateStalePartialRemovalError.recoveryCollision(
                original: candidateURL,
                quarantine: quarantineURL
            )
        }
    }

    private func identityIfPresent(
        named name: String,
        in directoryDescriptor: Int32,
        url: URL
    ) throws -> ConsolidateFileIdentity? {
        var information = stat()
        let result = name.withCString { entryName in
            fstatat(directoryDescriptor, entryName, &information, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0, errno == ENOENT { return nil }
        guard result == 0 else {
            throw operationError("inspect", url: url)
        }
        return ConsolidateFileIdentity(information)
    }

    private func readRecord(
        named name: String,
        in directoryDescriptor: Int32,
        url: URL
    ) throws -> ConsolidateQuarantineRecord {
        let descriptor = name.withCString { entryName in
            openat(directoryDescriptor, entryName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ConsolidateStalePartialRemovalError.invalidRecoveryEvidence(url)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
            ConsolidateFileIdentity(information).isRegularFile
        else {
            throw ConsolidateStalePartialRemovalError.invalidRecoveryEvidence(url)
        }
        do {
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else {
                throw ConsolidateStalePartialRemovalError.invalidRecoveryEvidence(url)
            }
            return try JSONDecoder().decode(ConsolidateQuarantineRecord.self, from: data)
        } catch let error as ConsolidateStalePartialRemovalError {
            throw error
        } catch {
            throw ConsolidateStalePartialRemovalError.invalidRecoveryEvidence(url)
        }
    }

    private func publishRecord(
        _ record: ConsolidateQuarantineRecord,
        named name: String,
        directoryDescriptor: Int32,
        directoryURL: URL
    ) throws {
        let data = try JSONEncoder().encode(record)
        let temporaryName = ".ajar-quarantine-record-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString { entryName in
            openat(
                directoryDescriptor,
                entryName,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw operationError(
                "create temporary recovery record",
                url: directoryURL.appendingPathComponent(temporaryName)
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            let writeError = error
            try? handle.close()
            try unlink(named: temporaryName, in: directoryDescriptor)
            throw writeError
        }
        do {
            try renameExclusive(
                from: temporaryName,
                to: name,
                in: directoryDescriptor,
                url: directoryURL.appendingPathComponent(name)
            )
        } catch {
            let publicationError = error
            try unlink(named: temporaryName, in: directoryDescriptor)
            throw publicationError
        }
        try synchronizeDirectory(directoryDescriptor, at: directoryURL)
    }

    private func renameExclusive(
        from sourceName: String,
        to destinationName: String,
        in directoryDescriptor: Int32,
        url: URL
    ) throws {
        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(
                    directoryDescriptor,
                    source,
                    directoryDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else { throw operationError("rename", url: url) }
    }

    private func unlink(named name: String, in directoryDescriptor: Int32) throws {
        let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
        guard result == 0 else {
            throw ConsolidateStalePartialRemovalError.operationFailed(
                operation: "unlink",
                url: URL(fileURLWithPath: name),
                code: errno
            )
        }
        try synchronizeDirectory(
            directoryDescriptor,
            at: urlForDirectoryDescriptor(directoryDescriptor, fallbackName: name)
        )
    }

    private func synchronizeDirectory(_ descriptor: Int32, at directoryURL: URL) throws {
        try directorySync(descriptor, directoryURL)
    }

    private func urlForDirectoryDescriptor(_ descriptor: Int32, fallbackName: String) -> URL {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else {
            return URL(fileURLWithPath: fallbackName).deletingLastPathComponent()
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func recoveryIdentifier(from name: String) -> String? {
        let prefix = ".ajar-quarantine-"
        let suffix = ".json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let identifier = String(name[start..<end])
        guard identifier.count == 36, UUID(uuidString: identifier) != nil else { return nil }
        return identifier.lowercased()
    }

    private func operationError(_ operation: String, url: URL) -> Error {
        ConsolidateStalePartialRemovalError.operationFailed(
            operation: operation,
            url: url,
            code: errno
        )
    }
}

private struct ConsolidateQuarantineRecord: Codable {
    let version: Int
    let originalName: String
    let quarantineName: String
    let expectedIdentity: ConsolidateFileIdentity

    init(
        originalName: String,
        quarantineName: String,
        expectedIdentity: ConsolidateFileIdentity
    ) {
        version = 1
        self.originalName = originalName
        self.quarantineName = quarantineName
        self.expectedIdentity = expectedIdentity
    }
}
