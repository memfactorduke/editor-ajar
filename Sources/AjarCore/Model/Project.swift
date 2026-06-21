// SPDX-License-Identifier: GPL-3.0-or-later

/// Top-level project document model for `.ajar` packages.
public struct Project: Codable, Equatable, Sendable {
    /// Project schema version used by future migrations.
    public let schemaVersion: Int

    /// Project-wide timeline and output settings.
    public let settings: ProjectSettings

    /// Stable media references used by clips.
    public let mediaPool: [MediaRef]

    /// Editable sequences contained in the project.
    public let sequences: [Sequence]

    /// Creates a project document.
    public init(
        schemaVersion: Int,
        settings: ProjectSettings,
        mediaPool: [MediaRef],
        sequences: [Sequence]
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.mediaPool = mediaPool
        self.sequences = sequences
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
