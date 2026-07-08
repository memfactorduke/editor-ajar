// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

extension OfflineAudioMixer {
    /// Rejects sequences whose crossfade metadata violates the ADR-0015 pair taxonomy
    /// (FR-AUD-002) before any rendering happens.
    ///
    /// Delegates to the pure `ClipAudioCrossfadeValidator` in `AjarCore` so the model
    /// and render paths agree on one taxonomy. Media durations are not available here,
    /// so the ADR-0015 §3 source-handle check runs in project validation only; render
    /// time drift handling is specified separately by ADR-0015 §7.
    static func validateCrossfades(in sequence: Sequence) throws {
        for track in selectedAudioTracks(sequence.audioTracks) {
            let errors = ClipAudioCrossfadeValidator.errors(in: track.items)
            if let firstError = errors.first {
                throw AudioRenderError(crossfadeValidationError: firstError)
            }
        }
    }
}

extension AudioRenderError {
    /// Maps a core crossfade validation finding onto the render error surface.
    init(crossfadeValidationError error: AudioCrossfadeValidationError) {
        switch error {
        case .crossfadePartnerMatchesClip(let edge, let clipID):
            self = .crossfadePartnerMatchesClip(edge: edge, clipID: clipID)
        case .crossfadePartnerMissing(let edge, let clipID, let partnerClipID):
            self = .crossfadePartnerMissing(
                edge: edge,
                clipID: clipID,
                partnerClipID: partnerClipID
            )
        case .crossfadePartnerNotAdjacent(let edge, let clipID, let partnerClipID):
            self = .crossfadePartnerNotAdjacent(
                edge: edge,
                clipID: clipID,
                partnerClipID: partnerClipID
            )
        case .crossfadeSeparatedByGap(let edge, let clipID, let partnerClipID):
            self = .crossfadeSeparatedByGap(
                edge: edge,
                clipID: clipID,
                partnerClipID: partnerClipID
            )
        case .crossfadeDirectionInvalid(let edge, let clipID, let partnerClipID):
            self = .crossfadeDirectionInvalid(
                edge: edge,
                clipID: clipID,
                partnerClipID: partnerClipID
            )
        case .crossfadeMirrorMissing(let edge, let clipID, let partnerClipID):
            self = .crossfadeMirrorMissing(
                edge: edge,
                clipID: clipID,
                partnerClipID: partnerClipID
            )
        case .crossfadePairMismatched(let edge, let clipID, let partnerClipID):
            self = .crossfadePairMismatched(
                edge: edge,
                clipID: clipID,
                partnerClipID: partnerClipID
            )
        case .crossfadeConflictsWithFade(let edge, let clipID):
            self = .crossfadeConflictsWithFade(edge: edge, clipID: clipID)
        case .crossfadeCurveUnsupported(let edge, let clipID, let curve):
            self = .crossfadeCurveUnsupported(edge: edge, clipID: clipID, curve: curve)
        case .crossfadeUnsupportedWithTimeRemap(let edge, let clipID):
            self = .crossfadeUnsupportedWithTimeRemap(edge: edge, clipID: clipID)
        case .crossfadeExceedsSourceHandle(let edge, let clipID, let mediaID):
            self = .crossfadeExceedsSourceHandle(edge: edge, clipID: clipID, mediaID: mediaID)
        case .timeArithmetic(_, let detail):
            self = .timeArithmetic(detail)
        }
    }
}
