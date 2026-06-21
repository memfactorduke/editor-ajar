// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Typed failures returned by the headless CLI implementation.
public enum AjarCLIError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The user supplied invalid arguments.
    case invalidUsage(String)

    /// A required file was not present.
    case missingFile(String)

    /// A `.ajar` package did not contain a valid editable/read-only project.
    case projectLoadFailed(String)

    /// The project contains no sequence to render.
    case missingSequence

    /// A render source node referenced media that is not in the project.
    case missingMediaReference(UUID)

    /// Core Video could not expose a Metal texture from a decoded frame.
    case decodedTextureUnavailable(UUID)

    /// A Metal command buffer finished unsuccessfully.
    case renderCommandFailed(String)

    /// Texture readback failed in the offline harness path.
    case textureReadbackFailed(String)

    /// PNG encoding or decoding failed.
    case pngFailed(String)

    /// A golden manifest is malformed.
    case invalidGoldenManifest(String)

    /// A benchmark could not run or report its result.
    case benchmarkFailed(String)

    /// A human-readable error description.
    public var description: String {
        switch self {
        case .invalidUsage(let message):
            message
        case .missingFile(let path):
            "missing file: \(path)"
        case .projectLoadFailed(let message):
            "project load failed: \(message)"
        case .missingSequence:
            "project contains no sequences"
        case .missingMediaReference(let mediaID):
            "render graph references missing media \(mediaID)"
        case .decodedTextureUnavailable(let mediaID):
            "decoded media \(mediaID) did not expose a Metal texture"
        case .renderCommandFailed(let message):
            "render command failed: \(message)"
        case .textureReadbackFailed(let message):
            "texture readback failed: \(message)"
        case .pngFailed(let message):
            "PNG failure: \(message)"
        case .invalidGoldenManifest(let message):
            "invalid golden manifest: \(message)"
        case .benchmarkFailed(let message):
            "benchmark failed: \(message)"
        }
    }

    /// Whether this error should map to command-line usage exit code 2.
    public var isUsageError: Bool {
        switch self {
        case .invalidUsage:
            true
        default:
            false
        }
    }
}
