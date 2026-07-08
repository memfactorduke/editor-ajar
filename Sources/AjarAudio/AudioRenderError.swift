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

    /// Crossfade partners are separated by a gap item (ADR-0015 §5).
    case crossfadeSeparatedByGap(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        partnerClipID: UUID
    )

    /// A crossfade record sits on the wrong edge for its partner's position (ADR-0015 §5).
    case crossfadeDirectionInvalid(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        partnerClipID: UUID
    )

    /// The partner clip is missing the mirroring crossfade record (ADR-0015 §5).
    case crossfadeMirrorMissing(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        partnerClipID: UUID
    )

    /// The two crossfade records disagree on duration or curve (ADR-0015 §5).
    case crossfadePairMismatched(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        partnerClipID: UUID
    )

    /// A same-edge fade and crossfade were both stored (ADR-0015 §6).
    case crossfadeConflictsWithFade(edge: ClipAudioFadeEdge, clipID: UUID)

    /// A crossfade edge uses a fade-to-silence-only curve (ADR-0015 §4).
    case crossfadeCurveUnsupported(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        curve: ClipAudioFadeCurve
    )

    /// A clip with a time-remap curve carries a crossfade edge (ADR-0015 §2).
    case crossfadeUnsupportedWithTimeRemap(edge: ClipAudioFadeEdge, clipID: UUID)

    /// The outgoing tail's effective read window leaves the declared media bounds.
    case crossfadeExceedsSourceHandle(
        edge: ClipAudioFadeEdge,
        clipID: UUID,
        mediaID: UUID
    )

    /// The provider delivered fewer source frames than the declared media bounds require
    /// (ADR-0015 §7) — a decoder fault must never render as silent zeros.
    case sourceUnderDelivered(clipID: UUID, missingRange: TimeRange)

    /// A pitch-corrected clip violates the FR-SPD-001 composition policy (freeze frame or
    /// time-remap curve). Defense in depth for sequences mixed without central validation.
    case pitchCorrectedRetimeUnsupported(clipID: UUID)

    /// The FR-SPD-001 WSOLA stage rejected a pitch-corrected clip's stretch input.
    case pitchCorrectedStretchFailed(clipID: UUID, error: WSOLATimeStretchError)

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
        case .crossfadeSeparatedByGap(let edge, let clipID, let partnerClipID):
            "\(edge.rawValue) crossfade on \(clipID) is separated from \(partnerClipID) by a gap"
        case .crossfadeDirectionInvalid(let edge, let clipID, let partnerClipID):
            "\(edge.rawValue) crossfade on \(clipID) points the wrong way at \(partnerClipID)"
        case .crossfadeMirrorMissing(let edge, let clipID, let partnerClipID):
            "\(edge.rawValue) crossfade on \(clipID) has no mirror record on \(partnerClipID)"
        case .crossfadePairMismatched(let edge, let clipID, let partnerClipID):
            "\(edge.rawValue) crossfade on \(clipID) disagrees with \(partnerClipID) "
                + "on duration or curve"
        case .crossfadeConflictsWithFade(let edge, let clipID):
            "\(edge.rawValue) crossfade on \(clipID) conflicts with a same-edge fade"
        case .crossfadeCurveUnsupported(let edge, let clipID, let curve):
            "\(edge.rawValue) crossfade on \(clipID) uses unsupported curve \(curve.rawValue)"
        case .crossfadeUnsupportedWithTimeRemap(let edge, let clipID):
            "\(edge.rawValue) crossfade on \(clipID) cannot combine with a time-remap curve"
        case .crossfadeExceedsSourceHandle(let edge, let clipID, let mediaID):
            "\(edge.rawValue) crossfade on \(clipID) reads past the bounds of media \(mediaID)"
        case .sourceUnderDelivered(let clipID, let missingRange):
            "audio source for clip \(clipID) under-delivered source time "
                + "[\(missingRange.start), +\(missingRange.duration)) inside declared bounds"
        case .pitchCorrectedRetimeUnsupported(let clipID):
            "pitch-corrected clip \(clipID) cannot combine with freezeFrame or a time-remap "
                + "curve (FR-SPD-001)"
        case .pitchCorrectedStretchFailed(let clipID, let error):
            "pitch-corrected stretch failed for clip \(clipID): \(error)"
        }
    }
}
