// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore

extension OfflineAudioMixer {
    static func crossfadeEnvelope(
        mix: ClipAudioMix,
        localTime: RationalTime,
        clipDuration: RationalTime
    ) -> Double {
        leadingCrossfadeMultiplier(mix.leadingCrossfade, localTime: localTime)
            * trailingCrossfadeMultiplier(
                mix.trailingCrossfade,
                localTime: localTime,
                clipDuration: clipDuration
            )
    }
}

private extension OfflineAudioMixer {
    static func leadingCrossfadeMultiplier(
        _ crossfade: ClipAudioCrossfade?,
        localTime: RationalTime
    ) -> Double {
        guard let crossfade, crossfade.duration > .zero else {
            return 1
        }
        if localTime <= .zero {
            return 0
        }
        if localTime >= crossfade.duration {
            return 1
        }
        return curveValue(
            crossfade.curve,
            at: fraction(localTime.seconds, over: crossfade.duration.seconds)
        )
    }

    static func trailingCrossfadeMultiplier(
        _ crossfade: ClipAudioCrossfade?,
        localTime: RationalTime,
        clipDuration: RationalTime
    ) -> Double {
        guard let crossfade, crossfade.duration > .zero else {
            return 1
        }
        let remaining = clipDuration.seconds - localTime.seconds
        if remaining <= 0 {
            return 0
        }
        if remaining >= crossfade.duration.seconds {
            return 1
        }
        return curveValue(
            crossfade.curve,
            at: fraction(remaining, over: crossfade.duration.seconds)
        )
    }

    static func fraction(_ value: Double, over duration: Double) -> Double {
        guard duration > 0, value.isFinite else {
            return 1
        }
        return clamped(value / duration, minimum: 0, maximum: 1)
    }

    static func curveValue(_ curve: ClipAudioFadeCurve, at fraction: Double) -> Double {
        let clampedFraction = clamped(fraction, minimum: 0, maximum: 1)
        switch curve {
        case .linear:
            return clampedFraction
        case .easeIn:
            return clampedFraction * clampedFraction
        case .easeOut:
            let inverse = 1 - clampedFraction
            return 1 - (inverse * inverse)
        case .easeInOut:
            if clampedFraction < 0.5 {
                return 2 * clampedFraction * clampedFraction
            }
            let inverse = -2 * clampedFraction + 2
            return 1 - ((inverse * inverse) / 2)
        }
    }

    static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}
