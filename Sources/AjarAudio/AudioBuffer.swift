// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Interleaved PCM format used by the headless audio renderer.
public struct AudioRenderFormat: Equatable, Sendable {
    /// Sample rate in hertz.
    public let sampleRate: Int

    /// Interleaved channel count.
    public let channelCount: Int

    /// Creates a render format. Validation happens at render boundaries.
    public init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Interleaved floating-point audio source supplied by platform or CLI decoding code.
public struct AudioSourceBuffer: Equatable, Sendable {
    /// Source PCM format.
    public let format: AudioRenderFormat

    /// Number of complete frames in `samples`.
    public let frameCount: Int

    /// Interleaved floating-point samples.
    public let samples: [Float]

    /// Creates and validates an audio source buffer.
    public init(format: AudioRenderFormat, frameCount: Int, samples: [Float]) throws {
        try AudioBufferValidator.validate(format: format, frameCount: frameCount, samples: samples)
        self.format = format
        self.frameCount = frameCount
        self.samples = samples
    }
}

/// Rendered interleaved floating-point PCM.
public struct RenderedAudioBuffer: Equatable, Sendable {
    /// Output PCM format.
    public let format: AudioRenderFormat

    /// Number of complete frames in `samples`.
    public let frameCount: Int

    /// Interleaved floating-point samples.
    public let samples: [Float]

    /// Creates and validates a rendered audio buffer.
    public init(format: AudioRenderFormat, frameCount: Int, samples: [Float]) throws {
        try AudioBufferValidator.validate(format: format, frameCount: frameCount, samples: samples)
        self.format = format
        self.frameCount = frameCount
        self.samples = samples
    }
}

/// Provides decoded audio buffers for media IDs referenced by the timeline.
public protocol AudioSourceProvider: Sendable {
    /// Returns decoded interleaved PCM for a media reference.
    func audioSource(for mediaID: UUID) throws -> AudioSourceBuffer
}

/// In-memory source provider used by deterministic tests and harnesses.
public struct InMemoryAudioSourceProvider: AudioSourceProvider {
    private let sources: [UUID: AudioSourceBuffer]

    /// Creates a provider from source buffers keyed by media ID.
    public init(sources: [UUID: AudioSourceBuffer]) {
        self.sources = sources
    }

    /// Returns decoded interleaved PCM for a media reference.
    public func audioSource(for mediaID: UUID) throws -> AudioSourceBuffer {
        guard let source = sources[mediaID] else {
            throw AudioRenderError.missingAudioSource(mediaID)
        }
        return source
    }
}

enum AudioBufferValidator {
    static func validate(
        format: AudioRenderFormat,
        frameCount: Int,
        samples: [Float]
    ) throws {
        guard format.sampleRate > 0, format.channelCount > 0, frameCount >= 0 else {
            throw AudioRenderError.invalidFormat(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount,
                frameCount: frameCount
            )
        }

        guard frameCount <= Int.max / format.channelCount else {
            throw AudioRenderError.sampleCountOverflow(
                frameCount: frameCount,
                channelCount: format.channelCount
            )
        }

        let expectedSampleCount = frameCount * format.channelCount
        guard samples.count == expectedSampleCount else {
            throw AudioRenderError.invalidBufferSampleCount(
                actual: samples.count,
                expected: expectedSampleCount
            )
        }
    }
}
