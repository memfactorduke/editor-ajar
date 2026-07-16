// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import CoreVideo
import Foundation
import Metal

/// Playback behavior written into an animated GIF (FR-EXP-006).
public enum AnimatedGIFLoopPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    /// Play the animation once; omit GIF loop metadata.
    case playOnce

    /// Repeat forever; write the GIF loop-count value `0`.
    case forever
}

/// Explicit delivery conversion applied before ImageIO builds the indexed GIF palette.
public enum AnimatedGIFColorConversionPolicy:
    String, Codable, CaseIterable, Equatable, Sendable {
    /// Convert tagged SDR delivery pixels to sRGB; partially transparent pixels matte over black.
    case convertToSRGB
}

/// Validation failures specific to GIF's raster and centisecond timing limits.
public enum AnimatedGIFExportSettingsValidationError:
    Error, Equatable, Sendable, CustomStringConvertible {
    /// Width and height must be positive and within ImageIO's supported export bound.
    case resolutionOutOfRange(PixelDimensions)

    /// GIF frame delays are stored in hundredths of a second, so output is capped at 100 fps.
    case frameRateOutOfRange(FrameRate)

    /// Human-readable validation failure.
    public var description: String {
        switch self {
        case .resolutionOutOfRange(let resolution):
            "animated GIF resolution \(resolution.width)x\(resolution.height) "
                + "is outside 1...16384"
        case .frameRateOutOfRange(let frameRate):
            "animated GIF frame rate \(frameRate) is outside 1...100 fps"
        }
    }
}

/// Immutable animated-GIF encoder settings (FR-EXP-006).
public struct AnimatedGIFExportSettings: Codable, Equatable, Sendable {
    /// Output raster. Odd dimensions are valid because GIF has no chroma subsampling.
    public let resolution: PixelDimensions

    /// Exact timeline sampling rate, limited to GIF's one-centisecond delay resolution.
    public let frameRate: FrameRate

    /// Source delivery space. The writer color-converts these pixels to indexed sRGB.
    public let sourceColorSpace: ExportColorSpace

    /// Explicit indexed-image delivery conversion.
    public let colorConversionPolicy: AnimatedGIFColorConversionPolicy

    /// Whether the resulting animation plays once or repeats forever.
    public let loopPolicy: AnimatedGIFLoopPolicy

    /// Creates validated settings.
    public init(
        resolution: PixelDimensions,
        frameRate: FrameRate,
        sourceColorSpace: ExportColorSpace = .rec709,
        colorConversionPolicy: AnimatedGIFColorConversionPolicy = .convertToSRGB,
        loopPolicy: AnimatedGIFLoopPolicy = .forever
    ) throws {
        self.resolution = resolution
        self.frameRate = frameRate
        self.sourceColorSpace = sourceColorSpace
        self.colorConversionPolicy = colorConversionPolicy
        self.loopPolicy = loopPolicy
        try validate()
    }

    /// Decodes and validates untrusted persisted settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            resolution: container.decode(PixelDimensions.self, forKey: .resolution),
            frameRate: container.decode(FrameRate.self, forKey: .frameRate),
            sourceColorSpace: container.decode(ExportColorSpace.self, forKey: .sourceColorSpace),
            colorConversionPolicy: container.decodeIfPresent(
                AnimatedGIFColorConversionPolicy.self,
                forKey: .colorConversionPolicy
            ) ?? .convertToSRGB,
            loopPolicy: container.decode(AnimatedGIFLoopPolicy.self, forKey: .loopPolicy)
        )
    }

    /// Validates all fields without consulting ImageIO runtime availability.
    public func validate() throws {
        let validDimensionRange = 1...16_384
        guard validDimensionRange.contains(resolution.width),
              validDimensionRange.contains(resolution.height)
        else {
            throw AnimatedGIFExportSettingsValidationError.resolutionOutOfRange(resolution)
        }
        let wholeFramesPerSecond = frameRate.frames / frameRate.seconds
        let fractionalRemainder = frameRate.frames % frameRate.seconds
        let atLeastOneFramePerSecond = frameRate.frames >= frameRate.seconds
        let atMostOneHundredFramesPerSecond = wholeFramesPerSecond < 100
            || (wholeFramesPerSecond == 100 && fractionalRemainder == 0)
        guard atLeastOneFramePerSecond, atMostOneHundredFramesPerSecond else {
            throw AnimatedGIFExportSettingsValidationError.frameRateOutOfRange(frameRate)
        }
    }
}

/// Captured project/range inputs for one deterministic animated-GIF export.
public struct AnimatedGIFExportRequest: Sendable {
    /// Immutable project snapshot used for every rendered frame.
    public let project: Project

    /// Sequence identity in the captured project.
    public let sequenceID: UUID

    /// Captured sequence value resolved during validation.
    public let sequence: Sequence

    /// Half-open timeline range to export.
    public let range: TimeRange

    /// Final file URL, published only after ImageIO successfully finalizes the GIF.
    public let destinationURL: URL

    /// Validated raster, timing, color, and loop settings.
    public let settings: AnimatedGIFExportSettings

    /// Creates and validates an animated-GIF request.
    public init(
        project: Project,
        sequenceID: UUID,
        range: TimeRange,
        destinationURL: URL,
        settings: AnimatedGIFExportSettings
    ) throws {
        do {
            try settings.validate()
        } catch let error as AnimatedGIFExportSettingsValidationError {
            throw ExportError.invalidAnimatedGIFSettings(error)
        }
        guard let sequence = project.sequences.first(where: { $0.id == sequenceID }) else {
            throw ExportError.sequenceNotFound(sequenceID)
        }
        guard range.start >= .zero, range.duration > .zero else {
            throw ExportError.invalidRange(range)
        }
        do {
            guard try range.end() <= sequence.timelineDuration() else {
                throw ExportError.invalidRange(range)
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
        guard project.settings.colorSpace == settings.sourceColorSpace.mediaColorSpace else {
            throw ExportError.colorSpaceMismatch(
                project: project.settings.colorSpace,
                export: settings.sourceColorSpace
            )
        }
        guard destinationURL.isFileURL else {
            throw ExportError.destinationMustBeFileURL(destinationURL)
        }

        self.project = project
        self.sequenceID = sequenceID
        self.sequence = sequence
        self.range = range
        self.destinationURL = destinationURL
        self.settings = settings
    }

    /// Number of sequential image frames required for the half-open range.
    public func frameCount() throws -> Int64 {
        do {
            return try range.duration.frameIndex(at: settings.frameRate, rounding: .up)
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
    }

    /// Exact timeline pull time for a zero-based GIF frame.
    public func timelineTime(forFrame index: Int64) throws -> RationalTime {
        do {
            return try range.start.adding(settings.frameRate.duration(ofFrames: index))
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
    }

    /// Integer GIF delay for `index`, distributed by cumulative centisecond rounding.
    ///
    /// Rounding cumulative boundaries avoids independent-delay drift: three 30 fps frames use
    /// `3, 4, 3` centiseconds, for example, instead of truncating every frame to `3`.
    public func delayCentiseconds(forFrame index: Int64) throws -> Int {
        let count = try frameCount()
        guard index >= 0, index < count else {
            throw ExportError.timeArithmeticFailed("GIF frame index \(index) is out of range")
        }
        let previous = try cumulativeCentiseconds(afterFrame: index - 1)
        let current = try cumulativeCentiseconds(afterFrame: index)
        // The final nominal boundary can be clipped to the requested range and round to the
        // same centisecond as the preceding boundary. Keep every encoded GIF frame visible for
        // at least one timing tick while retaining cumulative rounding for all other frames.
        return Int(max(1, current - previous))
    }

    private func cumulativeCentiseconds(afterFrame index: Int64) throws -> Int64 {
        guard index >= 0 else {
            return 0
        }
        do {
            let nominalBoundary = try settings.frameRate.duration(ofFrames: index + 1)
            let boundary = min(nominalBoundary, range.duration)
            let centisecondRate = try FrameRate(frames: 100)
            let rounded = try boundary.frameIndex(
                at: centisecondRate,
                rounding: .nearestOrAwayFromZero
            )
            // A valid <=100 fps stream advances by at least one GIF timing tick per frame.
            return max(index + 1, rounded)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.timeArithmeticFailed(String(describing: error))
        }
    }
}

/// Production entry point for animated-GIF export through the original-only render graph.
public enum AnimatedGIFExporter {
    /// Renders, encodes, and atomically publishes one animated GIF.
    @discardableResult
    public static func export(
        request: AnimatedGIFExportRequest,
        sourceProvider: any ExportRenderSourceProvider,
        device: MTLDevice? = nil,
        onFrameProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws -> ExportResult {
        let frameProvider: RenderGraphExportFrameProvider
        if let device {
            frameProvider = try RenderGraphExportFrameProvider(
                project: request.project,
                sequence: request.sequence,
                resolution: request.settings.resolution,
                colorSpace: request.settings.sourceColorSpace,
                sourceProvider: sourceProvider,
                device: device
            )
        } else {
            frameProvider = try RenderGraphExportFrameProvider(
                project: request.project,
                sequence: request.sequence,
                resolution: request.settings.resolution,
                colorSpace: request.settings.sourceColorSpace,
                sourceProvider: sourceProvider
            )
        }
        return try await AnimatedGIFExportSession(
            request: request,
            frameProvider: frameProvider,
            onFrameProgress: onFrameProgress
        ).run()
    }
}
