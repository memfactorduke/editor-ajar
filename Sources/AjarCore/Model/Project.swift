// SPDX-License-Identifier: GPL-3.0-or-later

/// Top-level project document model for `.ajar` packages.
public struct Project: Codable, Equatable, Sendable {
    /// Project schema **major** version (breaking shape changes; ADR-0018).
    public let schemaVersion: Int

    /// Project schema **minor** version (additive fields / kinds; ADR-0018).
    ///
    /// Absent in legacy files; decodes as `0`. Builds write `AjarProjectCodec.currentSchemaMinor`
    /// on save.
    public let schemaMinor: Int

    /// Project-wide timeline and output settings.
    public let settings: ProjectSettings

    /// Stable media references used by clips.
    public let mediaPool: [MediaRef]

    /// Editable sequences contained in the project.
    public let sequences: [Sequence]

    /// Named color-grade presets persisted in this project (FR-COL-007).
    public let looks: [ProjectLook]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case schemaMinor
        case settings
        case mediaPool
        case sequences
        case looks
    }

    /// Creates a project document.
    ///
    /// - Parameters:
    ///   - schemaVersion: Major schema version.
    ///   - schemaMinor: Minor schema version. Defaults to this build’s current minor so in-memory
    ///     projects match what `AjarProjectCodec.encode` writes (ADR-0018).
    ///   - settings: Project-wide settings.
    ///   - mediaPool: Media references.
    ///   - sequences: Sequences.
    ///   - looks: Named project color-grade presets.
    public init(
        schemaVersion: Int,
        schemaMinor: Int = AjarProjectCodec.currentSchemaMinor,
        settings: ProjectSettings,
        mediaPool: [MediaRef],
        sequences: [Sequence],
        looks: [ProjectLook] = []
    ) {
        self.schemaVersion = schemaVersion
        self.schemaMinor = schemaMinor
        self.settings = settings
        self.mediaPool = mediaPool
        self.sequences = sequences
        self.looks = looks
    }

    /// Decodes a project, defaulting absent `schemaMinor` to `0` (legacy v2 files; ADR-0018).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        schemaMinor = try container.decodeIfPresent(Int.self, forKey: .schemaMinor) ?? 0
        settings = try container.decode(ProjectSettings.self, forKey: .settings)
        mediaPool = try container.decode([MediaRef].self, forKey: .mediaPool)
        sequences = try container.decode([Sequence].self, forKey: .sequences)
        looks = try container.decodeIfPresent([ProjectLook].self, forKey: .looks) ?? []
    }

    /// Encodes the project document, always including `schemaMinor`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(schemaMinor, forKey: .schemaMinor)
        try container.encode(settings, forKey: .settings)
        try container.encode(mediaPool, forKey: .mediaPool)
        try container.encode(sequences, forKey: .sequences)
        try container.encode(looks, forKey: .looks)
    }

    /// Validates timeline invariants without trapping on malformed input.
    public func validate() -> ProjectValidationResult {
        ProjectValidator.validate(project: self)
    }
}

/// Project-wide settings used by sequences unless overridden later.
public struct ProjectSettings: Codable, Equatable, Sendable {
    /// Default project frame rate.
    public let frameRate: FrameRate

    /// Default raster resolution.
    public let resolution: PixelDimensions

    /// Timeline working/output color space.
    public let colorSpace: MediaColorSpace

    /// Audio sample rate in hertz.
    public let audioSampleRate: Int

    /// Creates project-wide settings.
    public init(
        frameRate: FrameRate,
        resolution: PixelDimensions,
        colorSpace: MediaColorSpace,
        audioSampleRate: Int
    ) {
        self.frameRate = frameRate
        self.resolution = resolution
        self.colorSpace = colorSpace
        self.audioSampleRate = audioSampleRate
    }
}
