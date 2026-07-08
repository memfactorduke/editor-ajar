// SPDX-License-Identifier: GPL-3.0-or-later

extension ProjectValidator {
    static func validateTrackAudioMix(
        _ track: Track,
        context: TrackContext,
        state: inout ValidationState
    ) {
        for error in AudioMixValidator.errors(gain: track.audioGain, pan: track.audioPan) {
            state.errors.append(
                .invalidTrackAudioMix(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    error: error
                )
            )
        }
    }

    /// Validates the ADR-0015 crossfade pair taxonomy and source-handle rule per track
    /// (FR-AUD-002). Self-partner records are skipped here because the per-clip
    /// `AudioMixValidator` already reports `crossfadePartnerMatchesClip`.
    static func validateTrackCrossfades(
        _ track: Track,
        context: TrackContext,
        state: inout ValidationState
    ) {
        guard context.trackKind == .audio else {
            return
        }

        let crossfadeErrors = ClipAudioCrossfadeValidator.errors(
            in: track.items,
            mediaDurationsByID: state.mediaDurationsByID
        )
        for error in crossfadeErrors {
            if case .crossfadePartnerMatchesClip = error {
                continue
            }
            state.errors.append(
                .invalidClipAudioCrossfade(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: error.clipID,
                    error: error
                )
            )
        }
    }

    static func validateClipAudioMix(
        _ item: TimelineItem,
        context: TrackContext,
        state: inout ValidationState
    ) {
        guard case .clip(let clip) = item else {
            return
        }

        for error in AudioMixValidator.errors(
            for: clip.audioMix,
            clipID: clip.id,
            clipDuration: clip.timelineRange.duration
        ) {
            state.errors.append(
                .invalidClipAudioMix(
                    sequenceID: context.sequenceID,
                    trackID: context.trackID,
                    clipID: clip.id,
                    error: error
                )
            )
        }
    }
}
