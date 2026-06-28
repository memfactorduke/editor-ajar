// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Typed failures from deterministic audio rendering.
public enum AudioRenderError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Output or source format values are not usable.
    case invalidFormat(sampleRate: Int, channelCount: Int, frameCount: Int)

    /// An interleaved buffer does not match its frame/channel metadata.
    case invalidBufferSampleCount(actual: Int, expected: Int)

    /// A timeline clip references media that was not provided.
    case missingAudioSource(UUID)

    /// A media clip did not reference a media source.
    case unsupportedClipSource(clipID: UUID)

    /// Exact timeline arithmetic failed.
    case timeArithmetic(String)

    /// Crossfade metadata points at the same clip.
    case crossfadePartnerMatchesClip(edge: ClipAudioFadeEdge, clipID: UUID)

    /// Crossfade metadata points at no clip on the owning track.
    case crossfadePartnerMissing(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        partnerClipID: UUID
    )

    /// Crossfade metadata points at a clip that is not the adjacent clip on that edge.
    case crossfadePartnerNotAdjacent(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        partnerClipID: UUID
    )

    /// A human-readable description.
    public var description: String {
        switch self {
        case .invalidFormat(let sampleRate, let channelCount, let frameCount):
            "invalid audio format sampleRate=\(sampleRate) "
                + "channelCount=\(channelCount) frameCount=\(frameCount)"
        case .invalidBufferSampleCount(let actual, let expected):
            "invalid audio buffer sample count \(actual), expected \(expected)"
        case .missingAudioSource(let mediaID):
            "missing audio source \(mediaID)"
        case .unsupportedClipSource(let clipID):
            "audio clip \(clipID) does not reference media"
        case .timeArithmetic(let message):
            "audio time arithmetic failed: \(message)"
        case .crossfadePartnerMatchesClip(let edge, let clipID):
            "\(edge.rawValue) crossfade on \(clipID) points at itself"
        case .crossfadePartnerMissing(let edge, let clipID, let partnerClipID):
            "\(edge.rawValue) crossfade on \(clipID) points at missing clip \(partnerClipID)"
        case .crossfadePartnerNotAdjacent(let edge, let clipID, let partnerClipID):
            "\(edge.rawValue) crossfade on \(clipID) points at non-adjacent clip \(partnerClipID)"
        }
    }
}
