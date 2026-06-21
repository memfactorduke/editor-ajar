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
    /// Schema version for the manifest.
    public let schemaVersion: Int

    /// Media references used by clips in `project.json`.
    public let media: [MediaRef]

    /// Creates a media manifest.
    public init(schemaVersion: Int, media: [MediaRef]) {
        self.schemaVersion = schemaVersion
        self.media = media
    }
}

/// Result of loading `.ajar` document bytes.
public enum AjarProjectLoadResult: Equatable, Sendable {
    /// The project uses a supported schema and can be edited.
    case editable(Project)

    /// The project decoded but uses a newer schema, so older Ajar should open it read-only.
    case readOnly(Project, reason: AjarProjectReadOnlyReason)
}

/// Why a project should be opened read-only.
public enum AjarProjectReadOnlyReason: Equatable, Sendable {
    /// The project or media manifest was saved by a newer schema.
    case newerSchemaVersion(found: Int, supported: Int)

    /// Clear user-facing message for read-only loads.
    public var message: String {
        switch self {
        case .newerSchemaVersion(let found, let supported):
            "This project uses schema version \(found), but this build supports up to "
                + "\(supported). It can be opened read-only."
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

    /// The project schema is older than the codec knows how to migrate.
    case unsupportedProjectSchemaVersion(found: Int, supported: Int)

    /// The media manifest schema is older than the codec knows how to migrate.
    case unsupportedMediaSchemaVersion(found: Int, supported: Int)

    /// A decoded project failed central model validation.
    case validationFailed([ProjectValidationError])

    /// Encoding failed.
    case encodingFailed(String)
}

/// Canonical JSON codec for the headless `.ajar` document model.
public enum AjarProjectCodec {
    /// Current `AjarCore` project schema version.
    public static let currentSchemaVersion = 1

    /// Encodes a runtime project into canonical `project.json` and `media.json` bytes.
    public static func encode(_ project: Project) throws -> AjarProjectPackageData {
        try validate(project)

        let projectDocument = Project(
            schemaVersion: currentSchemaVersion,
            settings: project.settings,
            mediaPool: [],
            sequences: project.sequences
        )
        let mediaManifest = AjarMediaManifest(
            schemaVersion: currentSchemaVersion,
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

    /// Decodes canonical `project.json` and `media.json` bytes into a runtime project.
    public static func decode(
        projectJSON: Data,
        mediaJSON: Data
    ) throws -> AjarProjectLoadResult {
        let projectVersion = try schemaVersion(in: projectJSON, document: .project)
        let mediaVersion = try schemaVersion(in: mediaJSON, document: .media)
        let projectDocument = try decodeProject(projectJSON)
        let mediaManifest = try decodeMediaManifest(mediaJSON)
        let migratedProject = try migrateProject(projectDocument, from: projectVersion)
        let migratedManifest = try migrateMediaManifest(mediaManifest, from: mediaVersion)
        let mediaPool = resolvedMediaPool(project: migratedProject, manifest: migratedManifest)
        let project = Project(
            schemaVersion: migratedProject.schemaVersion,
            settings: migratedProject.settings,
            mediaPool: mediaPool,
            sequences: migratedProject.sequences
        )

        try validate(project)

        if projectVersion > currentSchemaVersion || mediaVersion > currentSchemaVersion {
            let foundVersion = max(projectVersion, mediaVersion)
            return .readOnly(
                project,
                reason: .newerSchemaVersion(
                    found: foundVersion,
                    supported: currentSchemaVersion
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
    }

    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func schemaVersion(in data: Data, document: DocumentKind) throws -> Int {
        do {
            return try decoder().decode(SchemaProbe.self, from: data).schemaVersion
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
        } catch {
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
