// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore

extension RealtimeAudioRenderPlan {
    /// Prepares a realtime callback plan for a timeline window that may contain compound clips
    /// (FR-AUD-007, FR-CMP-001).
    ///
    /// All nested and compound resolution happens here, off the audio render thread: contributor
    /// selection matches the offline mix and meters exactly — enabled, unmuted audio tracks plus
    /// video tracks whose sequence-backed compound clips resolve to audible content, with solo
    /// applying across both sets — because this delegates to the same `OfflineAudioMixer` entry
    /// point (`audioContributorTracks`/`clipCarriesAudio`) used by export renders. Nested
    /// sequences at any depth (guarded by the compound nesting limit, with typed
    /// `AudioRenderError` failures for cycles and missing references) are flattened into a single
    /// absolute-timeline PCM buffer, so the returned plan keeps the fixed-size owned-pointer
    /// storage contract and the render callback stays non-recursive, lock-free, and
    /// allocation-free regardless of compound nesting.
    public static func preparingCompoundMix(
        project: Project,
        sequence: Sequence,
        range: TimeRange,
        sourceProvider: any AudioSourceProvider,
        channelCount: Int = 2
    ) throws -> RealtimeAudioRenderPlan {
        RealtimeAudioRenderPlan(
            buffer: try OfflineAudioMixer.render(
                project: project,
                sequence: sequence,
                range: range,
                sourceProvider: sourceProvider,
                channelCount: channelCount
            )
        )
    }
}
