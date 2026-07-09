// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Canonical `.ajar` document bytes owned by `AjarCore`.
public struct AjarProjectPackageData: Equatable, Sendable {
    /// Bytes for `project.json`.
    public let projectJSON: Data

    /// Bytes for `media.json`.
    public let mediaJSON: Data

    /// Creates package document bytes.
    public init(projectJSON: Data, mediaJSON: Data) {
        self.projectJSON = projectJSON
        self.mediaJSON = mediaJSON
    }
}

/// Sidecar media manifest stored as `media.json`.
public struct AjarMediaManifest: Codable, Equatable, Sendable {
    /// Schema **major** version for the manifest (ADR-0018).
    public let schemaVersion: Int

    /// Schema **minor** version for the manifest (ADR-0018). Absent keys decode as `0`.
    public let schemaMinor: Int

    /// Media references used by clips in `project.json`.
    public let media: [MediaRef]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case schemaMinor
        case media
    }

    /// Creates a media manifest.
    public init(
        schemaVersion: Int,
        schemaMinor: Int = AjarProjectCodec.currentSchemaMinor,
        media: [MediaRef]
    ) {
        self.schemaVersion = schemaVersion
        self.schemaMinor = schemaMinor
        self.media = media
    }

    /// Decodes a media manifest, defaulting absent `schemaMinor` to `0`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        schemaMinor = try container.decodeIfPresent(Int.self, forKey: .schemaMinor) ?? 0
        media = try container.decode([MediaRef].self, forKey: .media)
    }

    /// Encodes the manifest, always including `schemaMinor`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(schemaMinor, forKey: .schemaMinor)
        try container.encode(media, forKey: .media)
    }
}

/// Result of loading `.ajar` document bytes (ADR-0018 / FR-PROJ-005).
public enum AjarProjectLoadResult: Equatable, Sendable {
    /// The project uses a supported major/minor and can be edited and resaved.
    case editable(Project)

    /// The project decoded but uses a newer schema **minor**, so older Ajar must open it
    /// read-only and must not resave (would strip additive data).
    case readOnly(Project, reason: AjarProjectReadOnlyReason)

    /// The loaded project document.
    public var project: Project {
        switch self {
        case .editable(let project), .readOnly(let project, _):
            return project
        }
    }

    /// Open mode for edit / save gates.
    public var openMode: AjarProjectOpenMode {
        switch self {
        case .editable:
            return .editable
        case .readOnly(_, let reason):
            return .readOnly(reason: reason)
        }
    }
}

/// Whether a loaded project may be edited and resaved (ADR-0018).
public enum AjarProjectOpenMode: Equatable, Sendable {
    /// Full edit and save are allowed.
    case editable

    /// Inspection / playback only; edits and resave are refused.
    case readOnly(reason: AjarProjectReadOnlyReason)

    /// Whether this mode allows mutating the project.
    public var allowsEditing: Bool {
        switch self {
        case .editable:
            return true
        case .readOnly:
            return false
        }
    }
}

/// Why a project should be opened read-only.
public enum AjarProjectReadOnlyReason: Equatable, Sendable {
    /// Same major schema, but the file’s minor is newer than this build supports (ADR-0018).
    case newerSchemaMinor(found: Int, supported: Int)

    /// Clear user-facing message for read-only loads.
    public var message: String {
        switch self {
        case .newerSchemaMinor(let found, let supported):
            "This project uses schema minor version \(found), but this build supports up to "
                + "\(supported) (major \(AjarProjectCodec.currentSchemaVersion)). It can be "
                + "opened read-only; saving is disabled so newer data is not stripped "
                + "(FR-PROJ-005)."
        }
    }
}

/// Typed codec failures. Loading malformed input should return one of these, never trap.
public enum AjarProjectCodecError: Error, Equatable, Sendable {
    /// `project.json` could not be decoded.
    case malformedProjectJSON(String)

    /// `media.json` could not be decoded.
    case malformedMediaJSON(String)

    /// `project.json` did not contain a `schemaVersion`.
    case missingProjectSchemaVersion

    /// `media.json` did not contain a `schemaVersion`.
    case missingMediaSchemaVersion

    /// The project schema major is older than the codec knows how to migrate.
    case unsupportedProjectSchemaVersion(found: Int, supported: Int)

    /// The media manifest schema major is older than the codec knows how to migrate.
    case unsupportedMediaSchemaVersion(found: Int, supported: Int)

    /// The file’s schema **major** is newer than this build; open is refused (ADR-0018).
    case unsupportedNewerMajorSchemaVersion(found: Int, supported: Int)

    /// An effect kind string is unknown to this build (likely a newer project; ADR-0018).
    case unknownClipEffectKind(String)

    /// A decoded project failed central model validation.
    case validationFailed([ProjectValidationError])

    /// Encoding failed.
    case encodingFailed(String)

    /// Resave refused because the project was opened read-only (FR-PROJ-005 / ADR-0018).
    case resaveBlockedReadOnly(reason: AjarProjectReadOnlyReason)
}

/// Canonical JSON codec for the headless `.ajar` document model.
public enum AjarProjectCodec {
    /// Current `AjarCore` project schema **major** version (breaking shape).
    public static let currentSchemaVersion = 2

    /// Current `AjarCore` project schema **minor** version (additive fields / kinds).
    ///
    /// Bump whenever a persisted field or enum kind is added (ADR-0018).
    /// - `1`: introduces `schemaMinor` itself (ADR-0018 / #193).
    /// - `2`: FR-FX-002 library kinds (gaussian/box/zoom blur, sharpen, glow) (#181).
    /// - `3`: `ClipEffectKind.lut` (FR-COL-004 / #188).
    public static let currentSchemaMinor = 3

    /// Encodes a runtime project into canonical `project.json` and `media.json` bytes.
    ///
    /// `openMode` has **no default** — every persist path must state whether the session is
    /// editable. Passing a bare `loadResult.project` with an implicit editable mode would rewrite
    /// a higher-minor file at the current minor and strip newer data (FR-PROJ-005 / ADR-0018).
    /// For projects created in-memory and never loaded, use ``encodeNewDocument(_:)``.
    ///
    /// - Parameters:
    ///   - project: Project to serialize at the build’s current major/minor.
    ///   - openMode: Must be `.editable`. Read-only opens throw `resaveBlockedReadOnly`.
    /// - Returns: Canonical package document bytes.
    /// - Throws: `AjarProjectCodecError` when the open mode is read-only, validation fails, or
    ///   encoding fails.
    public static func encode(
        _ project: Project,
        openMode: AjarProjectOpenMode
    ) throws -> AjarProjectPackageData {
        if case .readOnly(let reason) = openMode {
            throw AjarProjectCodecError.resaveBlockedReadOnly(reason: reason)
        }

        try validate(project)

        let projectDocument = Project(
            schemaVersion: currentSchemaVersion,
            schemaMinor: currentSchemaMinor,
            settings: project.settings,
            mediaPool: [],
            sequences: project.sequences
        )
        let mediaManifest = AjarMediaManifest(
            schemaVersion: currentSchemaVersion,
            schemaMinor: currentSchemaMinor,
            media: project.mediaPool
        )

        do {
            return AjarProjectPackageData(
                projectJSON: try canonicalEncoder().encode(projectDocument),
                mediaJSON: try canonicalEncoder().encode(mediaManifest)
            )
        } catch {
            throw AjarProjectCodecError.encodingFailed(String(describing: error))
        }
    }

    /// Encodes a project that was created in this process and never opened from disk.
    ///
    /// Self-documenting alternative to `encode(_:openMode: .editable)` for sample projects,
    /// fixtures, and first-time saves of brand-new documents.
    public static func encodeNewDocument(_ project: Project) throws -> AjarProjectPackageData {
        try encode(project, openMode: .editable)
    }

    /// Decodes canonical `project.json` and `media.json` bytes into a runtime project.
    ///
    /// Higher **major** refuses open before full document decode. Same major with higher
    /// **minor** opens read-only after a successful decode (ADR-0018 / FR-PROJ-005).
    public static func decode(
        projectJSON: Data,
        mediaJSON: Data
    ) throws -> AjarProjectLoadResult {
        let projectProbe = try schemaProbe(in: projectJSON, document: .project)
        let mediaProbe = try schemaProbe(in: mediaJSON, document: .media)

        let foundMajor = max(projectProbe.schemaVersion, mediaProbe.schemaVersion)
        let projectMajorTooNew = projectProbe.schemaVersion > currentSchemaVersion
        let mediaMajorTooNew = mediaProbe.schemaVersion > currentSchemaVersion
        if projectMajorTooNew || mediaMajorTooNew {
            throw AjarProjectCodecError.unsupportedNewerMajorSchemaVersion(
                found: foundMajor,
                supported: currentSchemaVersion
            )
        }

        let projectDocument = try decodeProject(projectJSON)
        let mediaManifest = try decodeMediaManifest(mediaJSON)
        let migratedProject = try migrateProject(projectDocument, from: projectProbe.schemaVersion)
        let migratedManifest = try migrateMediaManifest(
            mediaManifest,
            from: mediaProbe.schemaVersion
        )
        let mediaPool = resolvedMediaPool(project: migratedProject, manifest: migratedManifest)
        let project = Project(
            schemaVersion: migratedProject.schemaVersion,
            schemaMinor: migratedProject.schemaMinor,
            settings: migratedProject.settings,
            mediaPool: mediaPool,
            sequences: migratedProject.sequences
        )

        try validate(project)

        // Same major + higher minor on either document → read-only (FR-PROJ-005 / ADR-0018).
        // Lower major was migrated above and remains editable. Only current-major documents
        // contribute to the reported found minor (a lower-major file's minor is unrelated).
        let projectHigherMinor =
            projectProbe.schemaVersion == currentSchemaVersion
            && projectProbe.schemaMinor > currentSchemaMinor
        let mediaHigherMinor =
            mediaProbe.schemaVersion == currentSchemaVersion
            && mediaProbe.schemaMinor > currentSchemaMinor
        if projectHigherMinor || mediaHigherMinor {
            var foundMinor = 0
            if projectHigherMinor {
                foundMinor = max(foundMinor, projectProbe.schemaMinor)
            }
            if mediaHigherMinor {
                foundMinor = max(foundMinor, mediaProbe.schemaMinor)
            }
            return .readOnly(
                project,
                reason: .newerSchemaMinor(
                    found: foundMinor,
                    supported: currentSchemaMinor
                )
            )
        }

        return .editable(project)
    }
}

private extension AjarProjectCodec {
    enum DocumentKind {
        case project
        case media
    }

    struct SchemaProbe: Decodable {
        let schemaVersion: Int
        let schemaMinor: Int?

        var resolvedMinor: Int {
            schemaMinor ?? 0
        }
    }

    struct ProbedSchema {
        let schemaVersion: Int
        let schemaMinor: Int
    }

    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func schemaProbe(in data: Data, document: DocumentKind) throws -> ProbedSchema {
        do {
            let probe = try decoder().decode(SchemaProbe.self, from: data)
            return ProbedSchema(
                schemaVersion: probe.schemaVersion,
                schemaMinor: probe.resolvedMinor
            )
        } catch DecodingError.keyNotFound(let key, _) where key.stringValue == "schemaVersion" {
            switch document {
            case .project:
                throw AjarProjectCodecError.missingProjectSchemaVersion
            case .media:
                throw AjarProjectCodecError.missingMediaSchemaVersion
            }
        } catch {
            switch document {
            case .project:
                throw AjarProjectCodecError.malformedProjectJSON(String(describing: error))
            case .media:
                throw AjarProjectCodecError.malformedMediaJSON(String(describing: error))
            }
        }
    }

    static func decodeProject(_ data: Data) throws -> Project {
        do {
            return try decoder().decode(Project.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) where key.stringValue == "schemaVersion" {
            throw AjarProjectCodecError.missingProjectSchemaVersion
        } catch let error as ClipEffectDecodingError {
            throw mapClipEffectDecodingError(error)
        } catch let error as AjarProjectCodecError {
            throw error
        } catch {
            if let effectError = nestedClipEffectDecodingError(from: error) {
                throw mapClipEffectDecodingError(effectError)
            }
            throw AjarProjectCodecError.malformedProjectJSON(String(describing: error))
        }
    }

    static func decodeMediaManifest(_ data: Data) throws -> AjarMediaManifest {
        do {
            return try decoder().decode(AjarMediaManifest.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) where key.stringValue == "schemaVersion" {
            throw AjarProjectCodecError.missingMediaSchemaVersion
        } catch {
            throw AjarProjectCodecError.malformedMediaJSON(String(describing: error))
        }
    }

    static func mapClipEffectDecodingError(
        _ error: ClipEffectDecodingError
    ) -> AjarProjectCodecError {
        switch error {
        case .unknownKind(let raw):
            return .unknownClipEffectKind(raw)
        }
    }

    /// JSONDecoder may wrap custom `Decodable` errors; walk `NSError` userInfo when needed.
    static func nestedClipEffectDecodingError(from error: Error) -> ClipEffectDecodingError? {
        if let effectError = error as? ClipEffectDecodingError {
            return effectError
        }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return nestedClipEffectDecodingError(from: underlying)
        }
        // Swift DecodingError sometimes stringifies; scan description as last resort is avoided —
        // prefer direct type matches only.
        return nil
    }

    static func migrateProject(_ project: Project, from version: Int) throws -> Project {
        guard version >= 0 else {
            throw AjarProjectCodecError.unsupportedProjectSchemaVersion(
                found: version,
                supported: currentSchemaVersion
            )
        }

        if version < currentSchemaVersion {
            return Project(
                schemaVersion: currentSchemaVersion,
                schemaMinor: project.schemaMinor,
                settings: project.settings,
                mediaPool: project.mediaPool,
                sequences: project.sequences
            )
        }

        return project
    }

    static func migrateMediaManifest(
        _ manifest: AjarMediaManifest,
        from version: Int
    ) throws -> AjarMediaManifest {
        guard version >= 0 else {
            throw AjarProjectCodecError.unsupportedMediaSchemaVersion(
                found: version,
                supported: currentSchemaVersion
            )
        }

        if version < currentSchemaVersion {
            return AjarMediaManifest(
                schemaVersion: currentSchemaVersion,
                schemaMinor: manifest.schemaMinor,
                media: manifest.media
            )
        }

        return manifest
    }

    static func resolvedMediaPool(
        project: Project,
        manifest: AjarMediaManifest
    ) -> [MediaRef] {
        if manifest.media.isEmpty && !project.mediaPool.isEmpty {
            return project.mediaPool
        }
        return manifest.media
    }

    static func validate(_ project: Project) throws {
        switch project.validate() {
        case .valid:
            return
        case .invalid(let errors):
            throw AjarProjectCodecError.validationFailed(errors)
        }
    }
}
