// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarMedia
import Darwin
import Foundation

/// A project loaded from a user-visible `.ajar` package.
struct EditorAjarOpenedDocument {
    /// Recovered live state, including the FR-PROJ-005 editable/read-only mode.
    let loadResult: AjarProjectLoadResult

    /// Last explicitly saved state used for exact dirty-state comparisons.
    ///
    /// `nil` means canonical publication was interrupted and the recovered project must be saved
    /// again before it can be treated as a complete explicit Save.
    let savedBaseline: Project?

    /// Best-effort recovery warnings, if a journal stopped at its last good command.
    let recoveryIssues: [AjarRecoveryIssue]

    /// The canonical pair could not be decoded, but a matching recovery checkpoint preserved the
    /// interrupted Save. The app surfaces recovery status and keeps the document dirty.
    let recoveredFromInterruptedSave: Bool
}

/// Typed app-layer failures for `.ajar` document operations.
enum EditorAjarDocumentStoreError: Error, Equatable {
    /// A document URL did not use the required package extension.
    case invalidPackageExtension(String)

    /// The selected package does not exist.
    case packageNotFound(String)

    /// The selected URL is not a directory package.
    case packageIsNotDirectory(String)

    /// The core codec rejected document bytes.
    case codec(AjarProjectCodecError)

    /// The atomic package persistence layer failed.
    case persistence(AjarAutosaveStoreError)

    /// A filesystem operation outside the core atomic writer failed.
    case fileOperation(path: String, reason: String)

    /// The destination or its parent changed after Save As validation.
    case saveAsDestinationChanged(path: String, reason: String)

    /// A Save As durability boundary could not be synchronized.
    case saveAsSynchronization(path: String, operation: String, code: Int32)
}

struct EditorAjarSaveAsResult {
    let project: Project
    let editHistory: EditHistory?
    let cleanupWarning: EditorAjarSaveAsCleanupWarning?
}

enum EditorAjarSaveAsCleanupWarning: Equatable {
    /// The guard revalidated the displaced package's identity at this exact quarantine URL.
    case retainedPackage(url: URL, error: EditorAjarDocumentStoreError)

    /// Cleanup failed closed before any package location could be identified safely.
    case skippedSafely(error: EditorAjarDocumentStoreError)
}

/// Hashes that identify one complete canonical `project.json` + `media.json` generation.
private struct EditorAjarCanonicalGeneration: Codable, Equatable, Sendable {
    let project: ContentHash
    let media: ContentHash
}

/// Hashes of every authoritative recovery file consumed when reconstructing a project.
private struct EditorAjarRecoveryGeneration: Codable, Equatable, Sendable {
    let snapshot: ContentHash
    let manifest: ContentHash
    let journal: ContentHash
}

/// Recovery-side proof for the exact before/after generations of one in-place Save.
///
/// The random identifier makes each marker unique even when a no-op Save produces identical
/// canonical bytes. The hashes are the authority when recognizing an interrupted publication.
private struct EditorAjarSaveTransactionMarker: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generationID: UUID
    let previous: EditorAjarCanonicalGeneration
    let saved: EditorAjarCanonicalGeneration
    let recovery: EditorAjarRecoveryGeneration

    init(
        previous: EditorAjarCanonicalGeneration,
        saved: EditorAjarCanonicalGeneration,
        recovery: EditorAjarRecoveryGeneration
    ) {
        schemaVersion = Self.currentSchemaVersion
        generationID = UUID()
        self.previous = previous
        self.saved = saved
        self.recovery = recovery
    }
}

protocol EditorAjarSaveAsSynchronizing {
    func synchronizeFile(at url: URL) throws
    func synchronizeDirectory(at url: URL, descriptor: Int32?) throws
}

struct EditorAjarDefaultSaveAsSynchronizer: EditorAjarSaveAsSynchronizing {
    func synchronizeFile(at url: URL) throws {
        try synchronize(
            url: url,
            descriptor: nil,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW,
            expectedType: S_IFREG,
            operation: "synchronize Save As manifest"
        )
    }

    func synchronizeDirectory(at url: URL, descriptor: Int32?) throws {
        try synchronize(
            url: url,
            descriptor: descriptor,
            flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            expectedType: S_IFDIR,
            operation: "synchronize Save As directory"
        )
    }

    private func synchronize(
        url: URL,
        descriptor suppliedDescriptor: Int32?,
        flags: Int32,
        expectedType: mode_t,
        operation: String
    ) throws {
        let descriptor: Int32
        let shouldClose: Bool
        if let suppliedDescriptor {
            descriptor = suppliedDescriptor
            shouldClose = false
        } else {
            descriptor = url.path.withCString { Darwin.open($0, flags) }
            shouldClose = true
        }
        guard descriptor >= 0 else {
            throw EditorAjarDocumentStoreError.saveAsSynchronization(
                path: url.path,
                operation: operation,
                code: errno
            )
        }
        defer {
            if shouldClose {
                Darwin.close(descriptor)
            }
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
            information.st_mode & S_IFMT == expectedType
        else {
            throw EditorAjarDocumentStoreError.saveAsSynchronization(
                path: url.path,
                operation: operation,
                code: errno == 0 ? EINVAL : errno
            )
        }
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            throw EditorAjarDocumentStoreError.saveAsSynchronization(
                path: url.path,
                operation: operation,
                code: code
            )
        }
    }
}

private final class EditorAjarSaveAsPublicationGuard {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let type: mode_t

        init(_ information: stat) {
            device = UInt64(information.st_dev)
            inode = UInt64(information.st_ino)
            type = information.st_mode & S_IFMT
        }
    }

    private struct VerifiedRetainedCleanup {
        let name: String
        let url: URL
        let identity: Identity
    }

    enum ExpectedDestination: Equatable {
        case absent
        case present(Identity)
    }

    let parentURL: URL
    let destinationURL: URL
    let destinationName: String
    let expectedDestination: ExpectedDestination

    private let parentDescriptor: Int32
    private let parentIdentity: Identity
    private let didRevalidatePublication: () throws -> Void
    private let willQuarantineCleanup: (URL) throws -> Void
    private let didRevalidateCleanup: (URL) throws -> Void
    private let willRestoreUnexpectedQuarantine: (URL, URL) throws -> Void
    private let willValidatePreviousDestinationCleanup: () throws -> Void
    private let cleanupDirectoryDevice: (URL, UInt64) -> UInt64
    private var stagingName: String?
    private var stagingIdentity: Identity?
    private var displacedIdentity: Identity?
    private var verifiedRetainedCleanup: VerifiedRetainedCleanup?

    init(
        parentURL: URL,
        destinationURL: URL,
        didRevalidatePublication: @escaping () throws -> Void,
        willQuarantineCleanup: @escaping (URL) throws -> Void,
        didRevalidateCleanup: @escaping (URL) throws -> Void,
        willRestoreUnexpectedQuarantine: @escaping (URL, URL) throws -> Void,
        willValidatePreviousDestinationCleanup: @escaping () throws -> Void,
        cleanupDirectoryDevice: @escaping (URL, UInt64) -> UInt64
    ) throws {
        self.parentURL = parentURL
        self.destinationURL = destinationURL
        self.didRevalidatePublication = didRevalidatePublication
        self.willQuarantineCleanup = willQuarantineCleanup
        self.didRevalidateCleanup = didRevalidateCleanup
        self.willRestoreUnexpectedQuarantine = willRestoreUnexpectedQuarantine
        self.willValidatePreviousDestinationCleanup = willValidatePreviousDestinationCleanup
        self.cleanupDirectoryDevice = cleanupDirectoryDevice
        destinationName = destinationURL.lastPathComponent
        parentDescriptor = parentURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: parentURL.path,
                reason: "Could not open the Save As parent directory safely (error \(errno))."
            )
        }

        var parentInformation = stat()
        guard fstat(parentDescriptor, &parentInformation) == 0,
            parentInformation.st_mode & S_IFMT == S_IFDIR
        else {
            let code = errno
            Darwin.close(parentDescriptor)
            throw EditorAjarDocumentStoreError.fileOperation(
                path: parentURL.path,
                reason: "Could not inspect the Save As parent directory (error \(code))."
            )
        }
        parentIdentity = Identity(parentInformation)

        do {
            if let identity = try Self.identity(
                named: destinationName,
                in: parentDescriptor,
                path: destinationURL.path
            ) {
                guard identity.type == S_IFDIR else {
                    throw EditorAjarDocumentStoreError.saveAsDestinationChanged(
                        path: destinationURL.path,
                        reason: "The destination is a symlink or is not a directory package."
                    )
                }
                expectedDestination = .present(identity)
            } else {
                expectedDestination = .absent
            }
        } catch {
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(parentDescriptor)
    }

    func createStaging(at stagingURL: URL) throws {
        try validateParentPath()
        let name = stagingURL.lastPathComponent
        let result = name.withCString {
            mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        guard result == 0 else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: stagingURL.path,
                reason: "Could not exclusively create the Save As staging package (error \(errno))."
            )
        }
        try captureStaging(at: stagingURL)
    }

    func captureStaging(at stagingURL: URL) throws {
        try validateParentPath()
        let name = stagingURL.lastPathComponent
        guard let identity = try Self.identity(
            named: name,
            in: parentDescriptor,
            path: stagingURL.path
        ), identity.type == S_IFDIR else {
            throw changed("The owned staging package is missing or unsafe.")
        }
        stagingName = name
        stagingIdentity = identity
    }

    func revalidateForPublication() throws {
        try validateParentPath()
        guard let stagingName, let stagingIdentity else {
            throw changed("The owned staging package was not captured.")
        }
        let currentDestination = try Self.identity(
            named: destinationName,
            in: parentDescriptor,
            path: destinationURL.path
        )
        switch (expectedDestination, currentDestination) {
        case (.absent, nil):
            break
        case (.present(let expected), .some(let current)) where expected == current:
            break
        case (.absent, .some):
            throw changed("A destination appeared after Save As validation.")
        case (.present, nil):
            throw changed("The validated destination disappeared before publication.")
        case (.present, .some):
            throw changed("The validated destination was substituted before publication.")
        }
        guard try Self.identity(
            named: stagingName,
            in: parentDescriptor,
            path: parentURL.appendingPathComponent(stagingName).path
        ) == stagingIdentity else {
            throw changed("The owned staging package changed before publication.")
        }
    }

    func exchangeForPublication() throws {
        try revalidateForPublication()
        guard case .present = expectedDestination, let stagingName else {
            throw changed("The destination state no longer permits replacement.")
        }
        try didRevalidatePublication()
        let result = stagingName.withCString { staging in
            destinationName.withCString { destination in
                renameatx_np(
                    parentDescriptor,
                    staging,
                    parentDescriptor,
                    destination,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw changed("Could not atomically exchange the validated destination (error \(errno)).")
        }
        guard let displacedIdentity = try Self.identity(
            named: stagingName,
            in: parentDescriptor,
            path: parentURL.appendingPathComponent(stagingName).path
        ) else {
            throw changed("The exchanged destination could not be captured for rollback.")
        }
        self.displacedIdentity = displacedIdentity
    }

    func publishExclusively() throws {
        try revalidateForPublication()
        guard expectedDestination == .absent, let stagingName else {
            throw changed("The destination state no longer permits exclusive creation.")
        }
        try didRevalidatePublication()
        let result = stagingName.withCString { staging in
            destinationName.withCString { destination in
                renameatx_np(
                    parentDescriptor,
                    staging,
                    parentDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw changed("Could not atomically publish the new package (error \(errno)).")
        }
    }

    func rollbackPublication() throws {
        guard let stagingName, let stagingIdentity else {
            throw changed("The rollback staging identity is unavailable.")
        }
        let publishedIdentity = try Self.identity(
            named: destinationName,
            in: parentDescriptor,
            path: destinationURL.path
        )
        guard publishedIdentity == stagingIdentity else {
            throw changed("The published package changed before rollback.")
        }
        switch expectedDestination {
        case .present:
            guard let displacedIdentity else {
                throw changed("The displaced destination identity is unavailable for rollback.")
            }
            guard try Self.identity(
                named: stagingName,
                in: parentDescriptor,
                path: parentURL.appendingPathComponent(stagingName).path
            ) == displacedIdentity else {
                throw changed("The displaced destination changed before rollback.")
            }
            let result = stagingName.withCString { staging in
                destinationName.withCString { destination in
                    renameatx_np(
                        parentDescriptor,
                        staging,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard result == 0 else {
                throw changed("Could not restore the previous destination (error \(errno)).")
            }
        case .absent:
            let result = destinationName.withCString { destination in
                stagingName.withCString { staging in
                    renameatx_np(
                        parentDescriptor,
                        destination,
                        parentDescriptor,
                        staging,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else {
                throw changed("Could not withdraw the new destination (error \(errno)).")
            }
        }
    }

    func synchronizeParent(
        using synchronizer: any EditorAjarSaveAsSynchronizing,
        requiringCurrentPath: Bool = true
    ) throws {
        if requiringCurrentPath {
            try validateParentPath()
        }
        try synchronizer.synchronizeDirectory(at: parentURL, descriptor: parentDescriptor)
    }

    func removePreviousDestinationIfOwned() throws {
        guard case .present = expectedDestination,
            let stagingName,
            let displacedIdentity
        else {
            return
        }
        try willValidatePreviousDestinationCleanup()
        try validateParentPath()
        try quarantineAndRemove(
            named: stagingName,
            expectedIdentity: displacedIdentity,
            changedReason: "The displaced destination changed before cleanup; it was preserved."
        )
    }

    func removeStagingIfOwned() throws {
        guard let stagingName, let stagingIdentity else {
            return
        }
        try quarantineAndRemove(
            named: stagingName,
            expectedIdentity: stagingIdentity,
            changedReason: "The owned staging package changed before cleanup; it was preserved."
        )
    }

    func validatePublishedState() throws {
        try validateParentPath()
        guard let stagingName, let stagingIdentity else {
            throw changed("The staging identity was lost during publication.")
        }
        guard try Self.identity(
            named: destinationName,
            in: parentDescriptor,
            path: destinationURL.path
        ) == stagingIdentity else {
            throw changed("The published destination is not the prepared package.")
        }
        switch expectedDestination {
        case .present(let previousIdentity):
            guard try Self.identity(
                named: stagingName,
                in: parentDescriptor,
                path: parentURL.appendingPathComponent(stagingName).path
            ) == previousIdentity else {
                throw changed("The previous destination was not preserved for rollback.")
            }
        case .absent:
            guard try Self.identity(
                named: stagingName,
                in: parentDescriptor,
                path: parentURL.appendingPathComponent(stagingName).path
            ) == nil else {
                throw changed("Exclusive publication left an unexpected staging entry.")
            }
        }
    }

    /// Returns a cleanup URL only while the original parent path and exact retained identity still
    /// match the guard-owned record. A stale pathname is never exposed as recovery guidance.
    func revalidatedRetainedCleanupURL() throws -> URL? {
        guard let verifiedRetainedCleanup else {
            return nil
        }
        try validateParentPath()
        guard try Self.identity(
            named: verifiedRetainedCleanup.name,
            in: parentDescriptor,
            path: verifiedRetainedCleanup.url.path
        ) == verifiedRetainedCleanup.identity else {
            return nil
        }
        return verifiedRetainedCleanup.url
    }

    private func validateParentPath() throws {
        var information = stat()
        let result = parentURL.path.withCString { lstat($0, &information) }
        guard result == 0, Identity(information) == parentIdentity else {
            throw changed("The Save As parent directory was substituted.")
        }
    }

    private func changed(_ reason: String) -> EditorAjarDocumentStoreError {
        .saveAsDestinationChanged(path: destinationURL.path, reason: reason)
    }

    private func quarantineAndRemove(
        named sourceName: String,
        expectedIdentity: Identity,
        changedReason: String
    ) throws {
        verifiedRetainedCleanup = nil
        let quarantineName = ".editor-ajar-save-as-\(UUID().uuidString).cleanup"
        let quarantineURL = parentURL.appendingPathComponent(
            quarantineName,
            isDirectory: true
        )
        let sourceURL = parentURL.appendingPathComponent(sourceName, isDirectory: true)
        let placeholderResult = quarantineName.withCString {
            mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        guard placeholderResult == 0 else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: quarantineURL.path,
                reason: "Could not create the Save As cleanup exchange guard (error \(errno))."
            )
        }
        guard let placeholderIdentity = try Self.identity(
            named: quarantineName,
            in: parentDescriptor,
            path: quarantineURL.path
        ) else {
            throw changed("The Save As cleanup exchange guard could not be captured.")
        }
        do {
            try willQuarantineCleanup(sourceURL)
        } catch {
            try removePlaceholder(
                named: quarantineName,
                identity: placeholderIdentity,
                path: quarantineURL.path
            )
            throw error
        }
        let result = sourceName.withCString { source in
            quarantineName.withCString { quarantine in
                renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    quarantine,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        if result != 0 {
            let code = errno
            try removePlaceholder(
                named: quarantineName,
                identity: placeholderIdentity,
                path: quarantineURL.path
            )
            if code == ENOENT {
                return
            }
            throw EditorAjarDocumentStoreError.fileOperation(
                path: quarantineURL.path,
                reason: "Could not quarantine the Save As cleanup target (error \(code))."
            )
        }

        let quarantinedIdentity = try Self.identity(
            named: quarantineName,
            in: parentDescriptor,
            path: quarantineURL.path
        )
        guard quarantinedIdentity == expectedIdentity else {
            try restoreUnexpectedQuarantine(
                sourceName: sourceName,
                quarantineName: quarantineName,
                placeholderIdentity: placeholderIdentity,
                quarantinedIdentity: quarantinedIdentity,
                sourcePath: sourceURL.path,
                quarantinePath: quarantineURL.path
            )
            throw changed(changedReason)
        }
        verifiedRetainedCleanup = VerifiedRetainedCleanup(
            name: quarantineName,
            url: quarantineURL,
            identity: expectedIdentity
        )
        try removePlaceholder(
            named: sourceName,
            identity: placeholderIdentity,
            path: sourceURL.path
        )
        let quarantineDescriptor = quarantineName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard quarantineDescriptor >= 0 else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: quarantineURL.path,
                reason: "Could not open the quarantined Save As cleanup target (error \(errno))."
            )
        }
        defer { Darwin.close(quarantineDescriptor) }

        var quarantineInformation = stat()
        guard fstat(quarantineDescriptor, &quarantineInformation) == 0 else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: quarantineURL.path,
                reason: "Could not inspect the quarantined Save As cleanup target (error \(errno))."
            )
        }
        let cleanupRootIdentity = Identity(quarantineInformation)
        guard cleanupRootIdentity == expectedIdentity
        else {
            throw changed(changedReason)
        }
        try didRevalidateCleanup(quarantineURL)
        try Self.removeContents(
            of: quarantineDescriptor,
            path: quarantineURL.path,
            rootDevice: cleanupRootIdentity.device,
            cleanupDirectoryDevice: cleanupDirectoryDevice
        )
        guard try Self.identity(
            named: quarantineName,
            in: parentDescriptor,
            path: quarantineURL.path
        ) == expectedIdentity else {
            throw changed("The quarantined cleanup target was substituted; it was preserved.")
        }
        let removeResult = quarantineName.withCString {
            unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
        }
        guard removeResult == 0 else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: quarantineURL.path,
                reason: "Could not remove the empty Save As cleanup quarantine (error \(errno))."
            )
        }
        verifiedRetainedCleanup = nil
    }

    private static func removeContents(
        of directoryDescriptor: Int32,
        path: String,
        rootDevice: UInt64,
        cleanupDirectoryDevice: (URL, UInt64) -> UInt64
    ) throws {
        let enumerationDescriptor = dup(directoryDescriptor)
        guard enumerationDescriptor >= 0 else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: path,
                reason: "Could not duplicate the Save As cleanup descriptor (error \(errno))."
            )
        }
        guard let directory = fdopendir(enumerationDescriptor) else {
            let code = errno
            Darwin.close(enumerationDescriptor)
            throw EditorAjarDocumentStoreError.fileOperation(
                path: path,
                reason: "Could not enumerate the Save As cleanup target (error \(code))."
            )
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            var record = entry.pointee
            let name = withUnsafePointer(to: &record.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else {
                continue
            }
            let childPath = "\(path)/\(name)"
            let childDescriptor = name.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            if childDescriptor >= 0 {
                do {
                    defer { Darwin.close(childDescriptor) }
                    var childInformation = stat()
                    guard fstat(childDescriptor, &childInformation) == 0 else {
                        throw EditorAjarDocumentStoreError.fileOperation(
                            path: childPath,
                            reason: "Could not inspect a quarantined Save As directory (error \(errno))."
                        )
                    }
                    let childIdentity = Identity(childInformation)
                    let policyDevice = cleanupDirectoryDevice(
                        URL(fileURLWithPath: childPath, isDirectory: true),
                        childIdentity.device
                    )
                    guard policyDevice == rootDevice else {
                        throw EditorAjarDocumentStoreError.saveAsDestinationChanged(
                            path: childPath,
                            reason: "Cleanup refused to traverse a mounted filesystem boundary."
                        )
                    }
                    try removeContents(
                        of: childDescriptor,
                        path: childPath,
                        rootDevice: rootDevice,
                        cleanupDirectoryDevice: cleanupDirectoryDevice
                    )
                    guard try identity(
                        named: name,
                        in: directoryDescriptor,
                        path: childPath
                    ) == childIdentity else {
                        throw EditorAjarDocumentStoreError.saveAsDestinationChanged(
                            path: childPath,
                            reason: "A quarantined Save As subdirectory was substituted; it was preserved."
                        )
                    }
                }
                let result = name.withCString {
                    unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                }
                guard result == 0 else {
                    throw EditorAjarDocumentStoreError.fileOperation(
                        path: childPath,
                        reason: "Could not remove a quarantined Save As directory (error \(errno))."
                    )
                }
                continue
            }

            let openCode = errno
            guard openCode == ENOTDIR || openCode == ELOOP else {
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: childPath,
                    reason: "Could not open a quarantined Save As entry safely (error \(openCode))."
                )
            }
            let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
            guard result == 0 else {
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: childPath,
                    reason: "Could not remove a quarantined Save As entry (error \(errno))."
                )
            }
        }
    }

    private func restoreUnexpectedQuarantine(
        sourceName: String,
        quarantineName: String,
        placeholderIdentity: Identity,
        quarantinedIdentity: Identity?,
        sourcePath: String,
        quarantinePath: String
    ) throws {
        guard let quarantinedIdentity,
            try Self.identity(
                named: sourceName,
                in: parentDescriptor,
                path: sourcePath
            ) == placeholderIdentity,
            try Self.identity(
                named: quarantineName,
                in: parentDescriptor,
                path: quarantinePath
            ) == quarantinedIdentity
        else {
            throw changed("The unexpected cleanup entry could not be restored safely.")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let quarantineURL = URL(fileURLWithPath: quarantinePath, isDirectory: true)
        try willRestoreUnexpectedQuarantine(sourceURL, quarantineURL)
        let result = sourceName.withCString { source in
            quarantineName.withCString { quarantine in
                renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    quarantine,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw changed("Could not exchange the cleanup restoration entries (error \(errno)).")
        }
        let restoredSourceIdentity = try Self.identity(
            named: sourceName,
            in: parentDescriptor,
            path: sourcePath
        )
        let restoredQuarantineIdentity = try Self.identity(
            named: quarantineName,
            in: parentDescriptor,
            path: quarantinePath
        )
        guard let exchangedFromQuarantineIdentity = restoredSourceIdentity,
            let exchangedFromSourceIdentity = restoredQuarantineIdentity
        else {
            throw changed("The exchanged cleanup restoration entries could not be captured.")
        }
        let intendedRestoration = restoredSourceIdentity == quarantinedIdentity
            && restoredQuarantineIdentity == placeholderIdentity
        guard intendedRestoration else {
            guard try Self.identity(
                named: sourceName,
                in: parentDescriptor,
                path: sourcePath
            ) == exchangedFromQuarantineIdentity,
                try Self.identity(
                    named: quarantineName,
                    in: parentDescriptor,
                    path: quarantinePath
                ) == exchangedFromSourceIdentity
            else {
                throw changed("The cleanup restoration exchange changed unexpectedly.")
            }
            let reverseResult = sourceName.withCString { source in
                quarantineName.withCString { quarantine in
                    renameatx_np(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        quarantine,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard reverseResult == 0,
                try Self.identity(
                    named: sourceName,
                    in: parentDescriptor,
                    path: sourcePath
                ) == exchangedFromSourceIdentity,
                try Self.identity(
                    named: quarantineName,
                    in: parentDescriptor,
                    path: quarantinePath
                ) == exchangedFromQuarantineIdentity
            else {
                throw changed("Could not reverse the unintended cleanup restoration exchange.")
            }
            throw changed("The cleanup restoration entries were substituted and restored.")
        }
        guard try Self.identity(
                named: sourceName,
                in: parentDescriptor,
                path: sourcePath
            ) == quarantinedIdentity,
            try Self.identity(
                named: quarantineName,
                in: parentDescriptor,
                path: quarantinePath
            ) == placeholderIdentity
        else {
            throw changed("Could not restore the unexpected cleanup entry to its original name.")
        }
        try removePlaceholder(
            named: quarantineName,
            identity: placeholderIdentity,
            path: quarantinePath
        )
        verifiedRetainedCleanup = nil
    }

    private func removePlaceholder(
        named name: String,
        identity placeholderIdentity: Identity,
        path: String
    ) throws {
        guard try Self.identity(named: name, in: parentDescriptor, path: path)
            == placeholderIdentity
        else {
            throw changed("The Save As cleanup exchange guard was substituted; it was preserved.")
        }
        let result = name.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
        guard result == 0 else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: path,
                reason: "Could not remove the Save As cleanup exchange guard (error \(errno))."
            )
        }
    }

    private static func identity(
        named name: String,
        in parentDescriptor: Int32,
        path: String
    ) throws -> Identity? {
        var information = stat()
        let result = name.withCString {
            fstatat(parentDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            return Identity(information)
        }
        let code = errno
        if code == ENOENT {
            return nil
        }
        throw EditorAjarDocumentStoreError.fileOperation(
            path: path,
            reason: "Could not inspect the Save As entry safely (error \(code))."
        )
    }
}

/// App-side `.ajar` package lifecycle (FR-PROJ-001/002).
///
/// `AjarCore` continues to own canonical JSON and open-mode safety. This type owns only macOS
/// document concerns: package URLs, Save As cloning, and rolling versions. ADR-0007 explicitly
/// excludes `versions/` from project identity/schema versioning, so these sidecars travel with a
/// package without adding manifest fields or bumping `schemaMinor`.
struct EditorAjarDocumentStore {
    static let snapshotRetentionLimit = 10

    private let fileManager: FileManager
    private let packageMediaSaveAs: EditorAjarPackageMediaSaveAs
    private let saveDidPublishRecovery: () throws -> Void
    private let saveDidPublishProject: () throws -> Void
    private let saveDidPublishContents: () throws -> Void
    private let saveAsSynchronizer: any EditorAjarSaveAsSynchronizing
    private let saveAsWillPublish: () throws -> Void
    private let saveAsDidRevalidatePublication: () throws -> Void
    private let saveAsWillQuarantineCleanup: (URL) throws -> Void
    private let saveAsDidRevalidateCleanup: (URL) throws -> Void
    private let saveAsWillRestoreUnexpectedQuarantine: (URL, URL) throws -> Void
    private let saveAsWillValidatePreviousDestinationCleanup: () throws -> Void
    private let saveAsCleanupDirectoryDevice: (URL, UInt64) -> UInt64

    init(
        fileManager: FileManager = .default,
        bookmarkStore: any MediaBookmarkStore = SecurityScopedMediaBookmarkStore(),
        mediaHasher: any MediaFileHashing = SHA256MediaFileHasher(),
        mediaFileCopier: any EditorAjarPackageMediaFileCopying =
            EditorAjarDefaultPackageMediaFileCopier(),
        saveDidPublishRecovery: @escaping () throws -> Void = {},
        saveDidPublishProject: @escaping () throws -> Void = {},
        saveDidPublishContents: @escaping () throws -> Void = {},
        saveAsSynchronizer: any EditorAjarSaveAsSynchronizing =
            EditorAjarDefaultSaveAsSynchronizer(),
        saveAsWillPublish: @escaping () throws -> Void = {},
        saveAsDidRevalidatePublication: @escaping () throws -> Void = {},
        saveAsWillQuarantineCleanup: @escaping (URL) throws -> Void = { _ in },
        saveAsDidRevalidateCleanup: @escaping (URL) throws -> Void = { _ in },
        saveAsWillRestoreUnexpectedQuarantine: @escaping (URL, URL) throws -> Void = { _, _ in },
        saveAsWillValidatePreviousDestinationCleanup: @escaping () throws -> Void = {},
        saveAsCleanupDirectoryDevice: @escaping (URL, UInt64) -> UInt64 = { _, device in
            device
        }
    ) {
        self.fileManager = fileManager
        self.saveDidPublishRecovery = saveDidPublishRecovery
        self.saveDidPublishProject = saveDidPublishProject
        self.saveDidPublishContents = saveDidPublishContents
        self.saveAsSynchronizer = saveAsSynchronizer
        self.saveAsWillPublish = saveAsWillPublish
        self.saveAsDidRevalidatePublication = saveAsDidRevalidatePublication
        self.saveAsWillQuarantineCleanup = saveAsWillQuarantineCleanup
        self.saveAsDidRevalidateCleanup = saveAsDidRevalidateCleanup
        self.saveAsWillRestoreUnexpectedQuarantine = saveAsWillRestoreUnexpectedQuarantine
        self.saveAsWillValidatePreviousDestinationCleanup =
            saveAsWillValidatePreviousDestinationCleanup
        self.saveAsCleanupDirectoryDevice = saveAsCleanupDirectoryDevice
        packageMediaSaveAs = EditorAjarPackageMediaSaveAs(
            fileManager: fileManager,
            bookmarkStore: bookmarkStore,
            hasher: mediaHasher,
            fileCopier: mediaFileCopier
        )
    }

    /// Opens canonical saved bytes and then applies any recoverable journal entries.
    ///
    /// The returned `AjarProjectLoadResult` is never flattened, preserving newer-minor read-only
    /// opens and the existing recovery behavior (FR-PROJ-005 / ADR-0018).
    func open(at packageURL: URL) throws -> EditorAjarOpenedDocument {
        try validateExistingPackage(packageURL)
        let baseline: AjarProjectLoadResult
        do {
            baseline = try loadCanonicalPackage(at: packageURL)
        } catch {
            if let recovered = try? recoverInterruptedSave(at: packageURL) {
                return recovered
            }
            throw error
        }

        // Canonical package bytes are the authority for open mode. A stale recovery envelope
        // written by an older build must never turn a newer-minor canonical document back into an
        // editable one. It is also unsafe to replay older commands against schema this build only
        // understands well enough to inspect, so read-only opens intentionally skip recovery.
        guard baseline.openMode.allowsEditing else {
            return EditorAjarOpenedDocument(
                loadResult: baseline,
                savedBaseline: baseline.project,
                recoveryIssues: [],
                recoveredFromInterruptedSave: false
            )
        }

        do {
            let recovery = try AjarAutosaveStore.recoverProject(
                from: packageURL,
                fileManager: fileManager
            )
            return EditorAjarOpenedDocument(
                loadResult: recovery.loadResult,
                savedBaseline: baseline.project,
                recoveryIssues: recovery.issues,
                recoveredFromInterruptedSave: false
            )
        } catch let error as AjarProjectCodecError {
            throw EditorAjarDocumentStoreError.codec(error)
        } catch let error as AjarAutosaveStoreError {
            throw EditorAjarDocumentStoreError.persistence(error)
        } catch {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: packageURL.path,
                reason: String(describing: error)
            )
        }
    }

    /// Saves over the current package, snapshotting the previous saved bytes first.
    ///
    /// Package-local recovery is rebased to the same project before publication so an older
    /// checkpoint cannot override the explicit Save on the next open.
    func save(
        project: Project,
        openMode: AjarProjectOpenMode,
        appliedCommandCount: Int,
        to packageURL: URL
    ) throws {
        try validatePackageExtension(packageURL)
        try validateExistingPackage(packageURL)
        let stagingURL = makeStagingURL(for: packageURL)
        do {
            _ = try stagePackageContents(
                project: project,
                openMode: openMode,
                sourceURL: packageURL,
                to: stagingURL
            )
            try stageSavedRecovery(
                project: project,
                openMode: openMode,
                appliedCommandCount: appliedCommandCount,
                sourceURL: packageURL,
                stagingURL: stagingURL
            )
            try publishCanonicalContents(
                stagingURL: stagingURL,
                destinationURL: packageURL
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw mappedError(error, path: packageURL.path)
        }
    }

    /// Saves to another package with canonical files and version history.
    ///
    /// Work happens in a sibling staging directory. Durable package-owned media is hash-verified
    /// into that staging package before publication. A failed Save As does not retarget the live
    /// document or publish half a package. Regeneratable `caches/` are intentionally not copied:
    /// this avoids a potentially multi-gigabyte copy and the new document recreates cache entries
    /// on demand. Recovery data is session-specific and likewise does not belong in the new package.
    func saveAs(
        project: Project,
        editHistory: EditHistory? = nil,
        openMode: AjarProjectOpenMode,
        appliedCommandCount: Int,
        sourceURL: URL?,
        destinationURL: URL
    ) throws -> EditorAjarSaveAsResult {
        try validatePackageExtension(destinationURL)
        if let sourceURL,
           sourceURL.standardizedFileURL == destinationURL.standardizedFileURL
        {
            try save(
                project: project,
                openMode: openMode,
                appliedCommandCount: appliedCommandCount,
                to: destinationURL
            )
            return EditorAjarSaveAsResult(
                project: project,
                editHistory: editHistory,
                cleanupWarning: nil
            )
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        let stagingURL = makeStagingURL(for: destinationURL)
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let publicationGuard = try EditorAjarSaveAsPublicationGuard(
            parentURL: parentURL,
            destinationURL: destinationURL,
            didRevalidatePublication: saveAsDidRevalidatePublication,
            willQuarantineCleanup: saveAsWillQuarantineCleanup,
            didRevalidateCleanup: saveAsDidRevalidateCleanup,
            willRestoreUnexpectedQuarantine: saveAsWillRestoreUnexpectedQuarantine,
            willValidatePreviousDestinationCleanup:
                saveAsWillValidatePreviousDestinationCleanup,
            cleanupDirectoryDevice: saveAsCleanupDirectoryDevice
        )
        do {
            let persistenceMediaReferences =
                editHistory?.persistenceMediaReferences ?? project.mediaPool
            try packageMediaSaveAs.validateDestinationReplacement(
                project: project,
                persistenceMediaReferences: persistenceMediaReferences,
                sourcePackageURL: sourceURL,
                destinationPackageURL: destinationURL
            )
            try publicationGuard.createStaging(at: stagingURL)
            let prepared = try stagePackageContents(
                project: project,
                persistenceMediaReferences: persistenceMediaReferences,
                openMode: openMode,
                sourceURL: sourceURL,
                to: stagingURL,
                saveAsDestinationURL: destinationURL
            )
            try synchronizeSaveAsPackage(at: stagingURL)
            try saveAsWillPublish()
            let rollback = try publishSaveAs(using: publicationGuard)
            let committedProject: Project
            let committedHistory: EditHistory?
            do {
                let finalized = try packageMediaSaveAs.finalizePublishedPackage(
                    prepared: prepared,
                    openMode: openMode,
                    packageURL: destinationURL
                )
                try synchronizeSaveAsPackage(at: destinationURL)
                try publicationGuard.validatePublishedState()
                var rebasedHistory = editHistory
                if var history = rebasedHistory {
                    let rebasedProject = try history.rebaseMediaReferences(
                        expected: finalized.expectedReferences,
                        rebased: finalized.rebasedReferences
                    )
                    guard rebasedProject == finalized.project else {
                        throw EditorAjarDocumentStoreError.fileOperation(
                            path: destinationURL.path,
                            reason: "Save As history rebasing did not reproduce the finalized project."
                        )
                    }
                    rebasedHistory = history
                }
                committedProject = finalized.project
                committedHistory = rebasedHistory
            } catch {
                do {
                    try rollbackSaveAs(rollback, using: publicationGuard)
                } catch let rollbackError {
                    throw EditorAjarDocumentStoreError.fileOperation(
                        path: destinationURL.path,
                        reason: "Save As finalization failed (\(error)); restoring the previous destination also failed (\(rollbackError))."
                    )
                }
                throw error
            }

            // Publication is committed once the finalized package is durable, validated, and its
            // complete edit history has been rebased. Cleanup below is nonfatal and must never
            // re-enter the rollback region or prevent the caller from adopting this destination.
            let cleanupWarning = finishSaveAs(
                rollback: rollback,
                using: publicationGuard
            )
            return EditorAjarSaveAsResult(
                project: committedProject,
                editHistory: committedHistory,
                cleanupWarning: cleanupWarning
            )
        } catch {
            do {
                try publicationGuard.removeStagingIfOwned()
            } catch let cleanupError {
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: destinationURL.path,
                    reason: "Save As failed (\(error)); quarantined staging cleanup also failed (\(cleanupError))."
                )
            }
            throw mappedError(error, path: destinationURL.path)
        }
    }

    /// Reloads only explicitly saved canonical files and durably discards package recovery data.
    ///
    /// The recovery directory is removed in a staged package replacement. A later reopen therefore
    /// cannot replay the edits the user just chose to discard, while a failed replacement leaves
    /// the original package untouched.
    func revert(at packageURL: URL) throws -> AjarProjectLoadResult {
        try validateExistingPackage(packageURL)
        let baseline = try loadCanonicalPackage(at: packageURL)
        let recoveryURL = packageURL.appendingPathComponent("recovery", isDirectory: true)
        guard fileManager.fileExists(atPath: recoveryURL.path) else {
            return baseline
        }

        let stagingURL = makeStagingURL(for: packageURL)
        do {
            try fileManager.copyItem(at: packageURL, to: stagingURL)
            let stagedRecoveryURL = stagingURL.appendingPathComponent(
                "recovery",
                isDirectory: true
            )
            try fileManager.removeItem(at: stagedRecoveryURL)
            try publish(stagingURL: stagingURL, destinationURL: packageURL)
            return baseline
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw mappedError(error, path: packageURL.path)
        }
    }

    /// Save snapshots currently retained in the package, oldest first.
    func versionSnapshotURLs(in packageURL: URL) throws -> [URL] {
        let versionsURL = packageURL.appendingPathComponent("versions", isDirectory: true)
        guard fileManager.fileExists(atPath: versionsURL.path) else {
            return []
        }
        do {
            return try fileManager.contentsOfDirectory(
                at: versionsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard url.lastPathComponent.hasPrefix("save-") else {
                    return false
                }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: versionsURL.path,
                reason: String(describing: error)
            )
        }
    }
}

private extension EditorAjarDocumentStore {
    enum SaveAsRollback {
        case replaced
        case created
    }

    func validatePackageExtension(_ packageURL: URL) throws {
        guard packageURL.pathExtension.lowercased() == "ajar" else {
            throw EditorAjarDocumentStoreError.invalidPackageExtension(packageURL.path)
        }
    }

    func validateExistingPackage(_ packageURL: URL) throws {
        try validatePackageExtension(packageURL)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) else {
            throw EditorAjarDocumentStoreError.packageNotFound(packageURL.path)
        }
        guard isDirectory.boolValue else {
            throw EditorAjarDocumentStoreError.packageIsNotDirectory(packageURL.path)
        }
    }

    func loadCanonicalPackage(at packageURL: URL) throws -> AjarProjectLoadResult {
        let projectURL = packageURL.appendingPathComponent("project.json")
        let mediaURL = packageURL.appendingPathComponent("media.json")
        do {
            guard fileManager.isReadableFile(atPath: projectURL.path) else {
                throw AjarAutosaveStoreError.missingPackageFile("project.json")
            }
            guard fileManager.isReadableFile(atPath: mediaURL.path) else {
                throw AjarAutosaveStoreError.missingPackageFile("media.json")
            }
            return try AjarProjectCodec.decode(
                projectJSON: Data(contentsOf: projectURL),
                mediaJSON: Data(contentsOf: mediaURL)
            )
        } catch let error as AjarProjectCodecError {
            throw EditorAjarDocumentStoreError.codec(error)
        } catch let error as AjarAutosaveStoreError {
            throw EditorAjarDocumentStoreError.persistence(error)
        } catch {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: packageURL.path,
                reason: String(describing: error)
            )
        }
    }

    /// Recovers the complete staged checkpoint when a crash leaves the top-level canonical pair
    /// split across two Save generations. Recovery must carry a marker for this exact Save, its
    /// snapshot must match the marker's complete saved generation, and the canonical pair must be
    /// one exact old/new split. Both splits are accepted because power loss can persist otherwise
    /// unsynchronized file replacements in a different order than the process issued them.
    func recoverInterruptedSave(at packageURL: URL) throws -> EditorAjarOpenedDocument? {
        let recoverySnapshotURL = packageURL.appendingPathComponent(
            "recovery/snapshot.json"
        )
        let transactionMarkerURL = packageURL.appendingPathComponent(
            "recovery/save-transaction.json"
        )
        guard fileManager.isReadableFile(atPath: recoverySnapshotURL.path),
              fileManager.isReadableFile(atPath: transactionMarkerURL.path)
        else {
            return nil
        }

        let marker = try JSONDecoder().decode(
            EditorAjarSaveTransactionMarker.self,
            from: Data(contentsOf: transactionMarkerURL)
        )
        guard marker.schemaVersion == EditorAjarSaveTransactionMarker.currentSchemaVersion else {
            return nil
        }
        guard try recoveryGeneration(in: packageURL) == marker.recovery else {
            return nil
        }
        let snapshot = try AjarAutosaveStore.readSnapshot(
            from: packageURL,
            fileManager: fileManager
        )
        let snapshotGeneration = canonicalGeneration(
            projectJSON: snapshot.package.projectJSON,
            mediaJSON: snapshot.package.mediaJSON
        )
        guard snapshotGeneration == marker.saved else {
            return nil
        }

        let canonical = try canonicalGeneration(in: packageURL)
        let projectPersistedFirst = marker.previous.media != marker.saved.media
            && canonical.project == marker.saved.project
            && canonical.media == marker.previous.media
        let mediaPersistedFirst = marker.previous.project != marker.saved.project
            && canonical.project == marker.previous.project
            && canonical.media == marker.saved.media
        guard canonical != marker.previous,
              canonical != marker.saved,
              projectPersistedFirst || mediaPersistedFirst
        else {
            return nil
        }

        let recovery = try AjarAutosaveStore.recoverProject(
            from: packageURL,
            fileManager: fileManager
        )
        return EditorAjarOpenedDocument(
            loadResult: recovery.loadResult,
            savedBaseline: nil,
            recoveryIssues: recovery.issues,
            recoveredFromInterruptedSave: true
        )
    }

    func stagePackageContents(
        project: Project,
        persistenceMediaReferences: [MediaRef]? = nil,
        openMode: AjarProjectOpenMode,
        sourceURL: URL?,
        to packageURL: URL,
        saveAsDestinationURL: URL? = nil
    ) throws -> EditorAjarPreparedPackageMediaSaveAs {
        do {
            // Validate and enforce read-only mode before creating any staged snapshot side effect.
            _ = try AjarProjectCodec.encode(project, openMode: openMode)
            try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
            if let sourceURL, fileManager.fileExists(atPath: sourceURL.path) {
                try copyCanonicalFileIfPresent(named: "project.json", from: sourceURL, to: packageURL)
                try copyCanonicalFileIfPresent(named: "media.json", from: sourceURL, to: packageURL)
                let sourceVersionsURL = sourceURL.appendingPathComponent(
                    "versions",
                    isDirectory: true
                )
                if fileManager.fileExists(atPath: sourceVersionsURL.path) {
                    try fileManager.copyItem(
                        at: sourceVersionsURL,
                        to: packageURL.appendingPathComponent("versions", isDirectory: true)
                    )
                }
            }
            try createVersionSnapshotIfPossible(in: packageURL)
            try pruneVersionSnapshots(in: packageURL)
            let prepared: EditorAjarPreparedPackageMediaSaveAs
            if let saveAsDestinationURL {
                prepared = try packageMediaSaveAs.prepareStagedPackage(
                    project: project,
                    persistenceMediaReferences: persistenceMediaReferences ?? project.mediaPool,
                    sourcePackageURL: sourceURL,
                    stagingPackageURL: packageURL,
                    destinationPackageURL: saveAsDestinationURL
                )
            } else {
                let references = persistenceMediaReferences ?? project.mediaPool
                prepared = EditorAjarPreparedPackageMediaSaveAs(
                    project: project,
                    expectedReferences: references,
                    rebasedReferences: references
                )
            }
            let encoded = try AjarProjectCodec.encode(prepared.project, openMode: openMode)
            try AjarAtomicFileWriter.write(
                encoded.projectJSON,
                to: packageURL.appendingPathComponent("project.json"),
                fileManager: fileManager
            )
            try AjarAtomicFileWriter.write(
                encoded.mediaJSON,
                to: packageURL.appendingPathComponent("media.json"),
                fileManager: fileManager
            )
            return prepared
        } catch let error as EditorAjarDocumentStoreError {
            throw error
        } catch let error as AjarProjectCodecError {
            throw EditorAjarDocumentStoreError.codec(error)
        } catch let error as AjarAutosaveStoreError {
            throw EditorAjarDocumentStoreError.persistence(error)
        } catch {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: packageURL.path,
                reason: String(describing: error)
            )
        }
    }

    func copyCanonicalFileIfPresent(named name: String, from sourceURL: URL, to targetURL: URL) throws {
        let sourceFileURL = sourceURL.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: sourceFileURL.path) else {
            return
        }
        try fileManager.copyItem(at: sourceFileURL, to: targetURL.appendingPathComponent(name))
    }

    /// Stages a recovery checkpoint aligned with the canonical bytes and clears its edit journal.
    func stageSavedRecovery(
        project: Project,
        openMode: AjarProjectOpenMode,
        appliedCommandCount: Int,
        sourceURL: URL,
        stagingURL: URL
    ) throws {
        let sourceRecoveryURL = sourceURL.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let stagedRecoveryURL = stagingURL.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: sourceRecoveryURL.path) {
            try validateRecoveryDirectoryIsNotSymbolicLink(sourceRecoveryURL)
            try fileManager.createDirectory(
                at: stagedRecoveryURL,
                withIntermediateDirectories: false
            )
            let authoritativeNames = Set([
                "manifest.json",
                "snapshot.json",
                "edit-journal.jsonl",
                "save-transaction.json",
            ])
            for sidecarURL in try fileManager.contentsOfDirectory(
                at: sourceRecoveryURL,
                includingPropertiesForKeys: nil
            ) where !authoritativeNames.contains(sidecarURL.lastPathComponent) {
                try fileManager.copyItem(
                    at: sidecarURL,
                    to: stagedRecoveryURL.appendingPathComponent(sidecarURL.lastPathComponent)
                )
            }
        }
        try AjarAutosaveStore.writeSnapshot(
            project,
            appliedCommandCount: appliedCommandCount,
            openMode: openMode,
            to: stagingURL,
            fileManager: fileManager
        )
        try AjarAutosaveStore.replaceJournal(
            with: [],
            in: stagingURL,
            fileManager: fileManager
        )
        try stageSaveTransactionMarker(sourceURL: sourceURL, stagingURL: stagingURL)
    }

    /// Records the exact canonical pair before and after this Save. A single unchanged file is not
    /// enough evidence because `media.json` commonly remains identical across timeline-only saves.
    func stageSaveTransactionMarker(sourceURL: URL, stagingURL: URL) throws {
        let marker = EditorAjarSaveTransactionMarker(
            previous: try canonicalGeneration(in: sourceURL),
            saved: try canonicalGeneration(in: stagingURL),
            recovery: try recoveryGeneration(in: stagingURL)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AjarAtomicFileWriter.write(
            encoder.encode(marker),
            to: stagingURL.appendingPathComponent("recovery/save-transaction.json"),
            fileManager: fileManager
        )
    }

    func canonicalGeneration(in packageURL: URL) throws -> EditorAjarCanonicalGeneration {
        try canonicalGeneration(
            projectJSON: Data(contentsOf: packageURL.appendingPathComponent("project.json")),
            mediaJSON: Data(contentsOf: packageURL.appendingPathComponent("media.json"))
        )
    }

    func canonicalGeneration(
        projectJSON: Data,
        mediaJSON: Data
    ) -> EditorAjarCanonicalGeneration {
        EditorAjarCanonicalGeneration(
            project: ContentHash.sha256(data: projectJSON),
            media: ContentHash.sha256(data: mediaJSON)
        )
    }

    func recoveryGeneration(in packageURL: URL) throws -> EditorAjarRecoveryGeneration {
        let recoveryURL = packageURL.appendingPathComponent("recovery", isDirectory: true)
        return try EditorAjarRecoveryGeneration(
            snapshot: ContentHash.sha256(
                data: Data(contentsOf: recoveryURL.appendingPathComponent("snapshot.json"))
            ),
            manifest: ContentHash.sha256(
                data: Data(contentsOf: recoveryURL.appendingPathComponent("manifest.json"))
            ),
            journal: ContentHash.sha256(
                data: Data(contentsOf: recoveryURL.appendingPathComponent("edit-journal.jsonl"))
            )
        )
    }

    /// Rejects a recovery symlink before staging so autosave writers never follow it outside the
    /// project package. The staging recovery directory is always created independently.
    func validateRecoveryDirectoryIsNotSymbolicLink(_ recoveryURL: URL) throws {
        var information = stat()
        let result = recoveryURL.path.withCString { lstat($0, &information) }
        guard result == 0, information.st_mode & S_IFMT == S_IFDIR else {
            throw EditorAjarDocumentStoreError.fileOperation(
                path: recoveryURL.path,
                reason: "The recovery entry is a symlink or is not a directory."
            )
        }
    }

    func publishCanonicalContents(stagingURL: URL, destinationURL: URL) throws {
        let rollbackURL = makeStagingURL(for: destinationURL)
        try fileManager.createDirectory(at: rollbackURL, withIntermediateDirectories: true)
        var didBeginRecoveryPublication = false
        var didBeginCanonicalPublication = false
        do {
            try copyCanonicalFileIfPresent(
                named: "project.json",
                from: destinationURL,
                to: rollbackURL
            )
            try copyCanonicalFileIfPresent(named: "media.json", from: destinationURL, to: rollbackURL)
            let destinationVersionsURL = destinationURL.appendingPathComponent(
                "versions",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: destinationVersionsURL.path) {
                try fileManager.copyItem(
                    at: destinationVersionsURL,
                    to: rollbackURL.appendingPathComponent("versions", isDirectory: true)
                )
            }
            let destinationRecoveryURL = destinationURL.appendingPathComponent(
                "recovery",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: destinationRecoveryURL.path) {
                try fileManager.copyItem(
                    at: destinationRecoveryURL,
                    to: rollbackURL.appendingPathComponent("recovery", isDirectory: true)
                )
            }

            // Recovery and its generation marker move first. If a power loss durably retains only
            // one later canonical replacement, open can prove either old/new split and recover.
            didBeginRecoveryPublication = true
            try publishStagedDirectory(
                named: "recovery",
                from: stagingURL,
                to: destinationURL
            )
            try synchronizePublishedRecovery(in: destinationURL)
            try saveDidPublishRecovery()
            didBeginCanonicalPublication = true
            try publishStagedFile(named: "project.json", from: stagingURL, to: destinationURL)
            try saveDidPublishProject()
            try publishStagedFile(named: "media.json", from: stagingURL, to: destinationURL)
            try publishStagedVersions(from: stagingURL, to: destinationURL)
            try saveDidPublishContents()
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: rollbackURL)
        } catch {
            defer {
                try? fileManager.removeItem(at: rollbackURL)
            }
            if didBeginCanonicalPublication {
                try restoreCanonicalContents(from: rollbackURL, to: destinationURL)
            } else if didBeginRecoveryPublication {
                try restoreRecoveryContents(from: rollbackURL, to: destinationURL)
            }
            throw error
        }
    }

    func publishStagedFile(named name: String, from stagingURL: URL, to destinationURL: URL) throws {
        try AjarAtomicFileWriter.write(
            Data(contentsOf: stagingURL.appendingPathComponent(name)),
            to: destinationURL.appendingPathComponent(name),
            fileManager: fileManager
        )
    }

    func publishStagedVersions(from stagingURL: URL, to destinationURL: URL) throws {
        try publishStagedDirectory(named: "versions", from: stagingURL, to: destinationURL)
    }

    /// Makes the complete recovery generation durable before either canonical file can change.
    ///
    /// Synchronizing only the renamed directory entry is insufficient after power loss: each file
    /// must reach stable storage, then `recovery/` must retain its children, and finally the package
    /// root must retain the replacement `recovery/` entry. The marker can then safely prove either
    /// mixed canonical generation if a later project/media replacement is only partly durable.
    func synchronizePublishedRecovery(in packageURL: URL) throws {
        let recoveryURL = packageURL.appendingPathComponent("recovery", isDirectory: true)
        for name in [
            "snapshot.json",
            "manifest.json",
            "edit-journal.jsonl",
            "save-transaction.json",
        ] {
            try saveAsSynchronizer.synchronizeFile(
                at: recoveryURL.appendingPathComponent(name)
            )
        }
        try saveAsSynchronizer.synchronizeDirectory(at: recoveryURL, descriptor: nil)
        try saveAsSynchronizer.synchronizeDirectory(at: packageURL, descriptor: nil)
    }

    func publishStagedDirectory(
        named name: String,
        from stagingURL: URL,
        to destinationURL: URL
    ) throws {
        let stagedDirectoryURL = stagingURL.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: stagedDirectoryURL.path) else {
            return
        }
        let destinationDirectoryURL = destinationURL.appendingPathComponent(
            name,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: destinationDirectoryURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationDirectoryURL,
                withItemAt: stagedDirectoryURL
            )
        } else {
            try fileManager.moveItem(at: stagedDirectoryURL, to: destinationDirectoryURL)
        }
    }

    func restoreCanonicalContents(from rollbackURL: URL, to destinationURL: URL) throws {
        for name in ["project.json", "media.json"] {
            let backup = rollbackURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: backup.path) {
                try publishStagedFile(named: name, from: rollbackURL, to: destinationURL)
            } else {
                let destination = destinationURL.appendingPathComponent(name)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
            }
        }

        try restoreStagedDirectory(
            named: "versions",
            from: rollbackURL,
            to: destinationURL
        )

        // Keep the new, already durable recovery generation in place while canonical rollback can
        // still be split by power loss. Its transaction marker recognizes both mixed generations.
        for name in ["project.json", "media.json"] {
            let restoredURL = destinationURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: restoredURL.path) {
                try saveAsSynchronizer.synchronizeFile(at: restoredURL)
            }
        }
        try saveAsSynchronizer.synchronizeDirectory(at: destinationURL, descriptor: nil)
        try restoreRecoveryContents(from: rollbackURL, to: destinationURL)
    }

    /// Restores only recovery when canonical publication never began, leaving valid saved files
    /// and their metadata untouched. The copied backup is fully durable before its atomic rename.
    func restoreRecoveryContents(from rollbackURL: URL, to destinationURL: URL) throws {
        let backupRecoveryURL = rollbackURL.appendingPathComponent("recovery", isDirectory: true)
        if fileManager.fileExists(atPath: backupRecoveryURL.path) {
            try synchronizeRecoveryDirectory(
                backupRecoveryURL,
                requiringTransactionMarker: false
            )
            try publishStagedDirectory(
                named: "recovery",
                from: rollbackURL,
                to: destinationURL
            )
        } else {
            let destinationRecoveryURL = destinationURL.appendingPathComponent(
                "recovery",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: destinationRecoveryURL.path) {
                try fileManager.removeItem(at: destinationRecoveryURL)
            }
        }
        try saveAsSynchronizer.synchronizeDirectory(at: destinationURL, descriptor: nil)
    }

    func restoreStagedDirectory(
        named name: String,
        from rollbackURL: URL,
        to destinationURL: URL
    ) throws {
        let backupURL = rollbackURL.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: backupURL.path) {
            try publishStagedDirectory(named: name, from: rollbackURL, to: destinationURL)
        } else {
            let destination = destinationURL.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
        }
    }

    func createVersionSnapshotIfPossible(in packageURL: URL) throws {
        let projectURL = packageURL.appendingPathComponent("project.json")
        let mediaURL = packageURL.appendingPathComponent("media.json")
        guard fileManager.isReadableFile(atPath: projectURL.path),
              fileManager.isReadableFile(atPath: mediaURL.path)
        else {
            return
        }
        let projectData = try Data(contentsOf: projectURL)
        let mediaData = try Data(contentsOf: mediaURL)
        guard (try? AjarProjectCodec.decode(
            projectJSON: projectData,
            mediaJSON: mediaData
        )) != nil else {
            // A crash can leave the two canonical files from different Save generations. Recovery
            // repairs that state; version history must never archive or retain the invalid pair.
            return
        }

        let versionsURL = packageURL.appendingPathComponent("versions", isDirectory: true)
        try fileManager.createDirectory(at: versionsURL, withIntermediateDirectories: true)
        let sequence = try nextVersionSequence(in: packageURL)
        let snapshotURL = versionsURL.appendingPathComponent(
            String(format: "save-%020llu.ajar", sequence),
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
            try AjarAtomicFileWriter.write(
                projectData,
                to: snapshotURL.appendingPathComponent("project.json"),
                fileManager: fileManager
            )
            try AjarAtomicFileWriter.write(
                mediaData,
                to: snapshotURL.appendingPathComponent("media.json"),
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw error
        }
    }

    func nextVersionSequence(in packageURL: URL) throws -> UInt64 {
        let snapshots = try versionSnapshotURLs(in: packageURL)
        let largest = snapshots.compactMap { url -> UInt64? in
            let name = url.deletingPathExtension().lastPathComponent
            return UInt64(name.dropFirst("save-".count))
        }.max() ?? 0
        return largest == UInt64.max ? largest : largest + 1
    }

    func pruneVersionSnapshots(in packageURL: URL) throws {
        let snapshots = try versionSnapshotURLs(in: packageURL)
        let excessCount = max(0, snapshots.count - Self.snapshotRetentionLimit)
        for snapshotURL in snapshots.prefix(excessCount) {
            do {
                try fileManager.removeItem(at: snapshotURL)
            } catch {
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: snapshotURL.path,
                    reason: String(describing: error)
                )
            }
        }
    }

    func publish(stagingURL: URL, destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    /// Makes every Save As manifest and the directory entries that contain it crash-durable.
    ///
    /// Files are synchronized before directories; nested snapshot directories are synchronized
    /// before `versions/`, and all package children are synchronized before the package root.
    func synchronizeSaveAsPackage(at packageURL: URL) throws {
        let manifestNames = ["project.json", "media.json"]
        for name in manifestNames {
            try saveAsSynchronizer.synchronizeFile(
                at: packageURL.appendingPathComponent(name)
            )
        }

        let snapshots = try saveAsSnapshotURLs(in: packageURL)
        for snapshotURL in snapshots {
            for name in manifestNames {
                try saveAsSynchronizer.synchronizeFile(
                    at: snapshotURL.appendingPathComponent(name)
                )
            }
        }
        for snapshotURL in snapshots {
            try saveAsSynchronizer.synchronizeDirectory(at: snapshotURL, descriptor: nil)
        }

        let versionsURL = packageURL.appendingPathComponent("versions", isDirectory: true)
        if fileManager.fileExists(atPath: versionsURL.path) {
            try saveAsSynchronizer.synchronizeDirectory(at: versionsURL, descriptor: nil)
        }
        let mediaURL = packageURL.appendingPathComponent("media", isDirectory: true)
        if fileManager.fileExists(atPath: mediaURL.path) {
            try saveAsSynchronizer.synchronizeDirectory(at: mediaURL, descriptor: nil)
        }
        try saveAsSynchronizer.synchronizeDirectory(at: packageURL, descriptor: nil)
    }

    func saveAsSnapshotURLs(in packageURL: URL) throws -> [URL] {
        let versionsURL = packageURL.appendingPathComponent("versions", isDirectory: true)
        guard fileManager.fileExists(atPath: versionsURL.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { snapshotURL in
            guard (try? snapshotURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
                == true
            else {
                return false
            }
            return fileManager.fileExists(
                atPath: snapshotURL.appendingPathComponent("project.json").path
            ) && fileManager.fileExists(
                atPath: snapshotURL.appendingPathComponent("media.json").path
            )
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func publishSaveAs(
        using publicationGuard: EditorAjarSaveAsPublicationGuard
    ) throws -> SaveAsRollback {
        let rollback: SaveAsRollback
        switch publicationGuard.expectedDestination {
        case .present:
            try publicationGuard.exchangeForPublication()
            rollback = .replaced
        case .absent:
            try publicationGuard.publishExclusively()
            rollback = .created
        }
        do {
            try publicationGuard.validatePublishedState()
            try publicationGuard.synchronizeParent(using: saveAsSynchronizer)
        } catch {
            do {
                try publicationGuard.rollbackPublication()
                try publicationGuard.synchronizeParent(
                    using: saveAsSynchronizer,
                    requiringCurrentPath: false
                )
            } catch let rollbackError {
                throw EditorAjarDocumentStoreError.fileOperation(
                    path: publicationGuard.destinationURL.path,
                    reason: "Package publication synchronization failed (\(error)); restoring the prior destination state also failed (\(rollbackError))."
                )
            }
            throw error
        }
        return rollback
    }

    func rollbackSaveAs(
        _ rollback: SaveAsRollback,
        using publicationGuard: EditorAjarSaveAsPublicationGuard
    ) throws {
        _ = rollback
        try publicationGuard.rollbackPublication()
        try publicationGuard.synchronizeParent(
            using: saveAsSynchronizer,
            requiringCurrentPath: false
        )
    }

    func finishSaveAs(
        rollback: SaveAsRollback,
        using publicationGuard: EditorAjarSaveAsPublicationGuard
    ) -> EditorAjarSaveAsCleanupWarning? {
        guard case .replaced = rollback else {
            return nil
        }
        do {
            try publicationGuard.removePreviousDestinationIfOwned()
            return nil
        } catch {
            let cleanupError = mappedError(error, path: publicationGuard.destinationURL.path)
            guard let retainedURL = try? publicationGuard.revalidatedRetainedCleanupURL() else {
                return .skippedSafely(error: cleanupError)
            }
            return .retainedPackage(url: retainedURL, error: cleanupError)
        }
    }

    func makeStagingURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).staging",
            isDirectory: true
        )
    }

    func mappedError(_ error: Error, path: String) -> EditorAjarDocumentStoreError {
        if let error = error as? EditorAjarDocumentStoreError {
            return error
        }
        if let error = error as? AjarProjectCodecError {
            return .codec(error)
        }
        if let error = error as? AjarAutosaveStoreError {
            return .persistence(error)
        }
        return .fileOperation(path: path, reason: String(describing: error))
    }
}

/// Holds a document security scope for the complete open session.
///
/// Unsandboxed/test URLs commonly return `false`; that means no matching scope was needed, not
/// that the URL is invalid.
final class EditorAjarSecurityScopedAccess {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// App-side recent-document persistence. URLs/bookmarks never enter project manifests.
struct EditorAjarRecentProjectsStore {
    static let maximumCount = 10

    private struct Record: Codable {
        let urlString: String
        let bookmark: Data?
    }

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "document.recentProjects"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func load() -> [URL] {
        guard let data = userDefaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else {
            return []
        }
        return records.compactMap(resolve)
    }

    func record(_ url: URL) -> [URL] {
        let standardizedURL = url.standardizedFileURL
        var urls = load().filter { $0.standardizedFileURL != standardizedURL }
        urls.insert(standardizedURL, at: 0)
        urls = Array(urls.prefix(Self.maximumCount))
        persist(urls)
        return urls
    }

    func remove(_ url: URL) -> [URL] {
        let standardizedURL = url.standardizedFileURL
        let urls = load().filter { $0.standardizedFileURL != standardizedURL }
        persist(urls)
        return urls
    }

    private func persist(_ urls: [URL]) {
        let records = urls.map { url in
            Record(
                urlString: url.absoluteString,
                bookmark: try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            )
        }
        if let data = try? JSONEncoder().encode(records) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private func resolve(_ record: Record) -> URL? {
        if let bookmark = record.bookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    refreshBookmark(for: resolved, replacing: record)
                }
                // Preserve the bookmark-resolved URL itself: standardizing it can discard the
                // security-scope association that a future sandboxed build must retain.
                return resolved
            }
        }
        return URL(string: record.urlString)?.standardizedFileURL
    }

    private func refreshBookmark(for url: URL, replacing record: Record) {
        guard let data = userDefaults.data(forKey: storageKey),
              var records = try? JSONDecoder().decode([Record].self, from: data),
              let index = records.firstIndex(where: { $0.urlString == record.urlString }),
              let bookmark = try? url.bookmarkData(
                  options: [.withSecurityScope],
                  includingResourceValuesForKeys: nil,
                  relativeTo: nil
              )
        else {
            return
        }
        records[index] = Record(urlString: url.absoluteString, bookmark: bookmark)
        if let refreshedData = try? JSONEncoder().encode(records) {
            userDefaults.set(refreshedData, forKey: storageKey)
        }
    }
}
