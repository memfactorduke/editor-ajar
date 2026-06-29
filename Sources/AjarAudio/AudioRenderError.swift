// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Typed failures from deterministic audio rendering.
public enum AudioRenderError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Output or source format values are not usable.
    case invalidFormat(sampleRate: Int, channelCount: Int, frameCount: Int)

    /// An interleaved buffer does not match its frame/channel metadata.
    case invalidBufferSampleCount(actual: Int, expected: Int)

    /// Frame and channel metadata would overflow an interleaved sample count.
    case sampleCountOverflow(frameCount: Int, channelCount: Int)

    /// A timeline clip references media that was not provided.
    case missingAudioSource(UUID)

    /// A media clip did not reference a media source.
    case unsupportedClipSource(clipID: UUID)

    /// A compound audio clip references a missing sequence.
    case missingSequenceReference(clipID: UUID, sequenceID: UUID)

    /// Compound audio nesting exceeded the defensive recursion limit.
    case maximumCompoundNestingDepthExceeded(clipID: UUID, depth: Int)

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
        case .sampleCountOverflow(let frameCount, let channelCount):
            "audio sample count overflows frameCount=\(frameCount) channelCount=\(channelCount)"
        case .missingAudioSource(let mediaID):
            "missing audio source \(mediaID)"
        case .unsupportedClipSource(let clipID):
            "audio clip \(clipID) does not reference media"
        case .missingSequenceReference(let clipID, let sequenceID):
            "audio compound clip \(clipID) references missing sequence \(sequenceID)"
        case .maximumCompoundNestingDepthExceeded(let clipID, let depth):
            "audio compound clip \(clipID) exceeded maximum nesting depth \(depth)"
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
