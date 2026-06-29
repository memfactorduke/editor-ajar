// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Stored limits for deterministic audio ducking rules.
public enum AudioDuckingLimits {
    /// Silence threshold.
    public static let minimumThreshold = RationalValue.zero

    /// Conservative linear threshold ceiling matching the current track gain ceiling.
    public static let maximumThreshold = AudioMixLimits.maximumGain

    /// Full attenuation.
    public static let minimumReductionGain = RationalValue.zero

    /// No attenuation.
    public static let maximumReductionGain = RationalValue.one
}

/// Time parameter names used by audio-ducking validation errors.
public enum AudioDuckingTimeParameter: String, Codable, Equatable, Sendable {
    /// Attack ramp duration.
    case attack

    /// Release ramp duration.
    case release

    /// Hold duration after the trigger falls below threshold.
    case hold
}

/// A deterministic sidechain ducking rule for one trigger audio track and target audio tracks.
public struct AudioDuckingRule: Codable, Equatable, Sendable {
    /// Audio track whose detected level drives the ducking envelope.
    public let triggerTrackID: UUID

    /// Audio tracks multiplied by the ducking envelope.
    public let targetTrackIDs: [UUID]

    /// Peak detector threshold in linear amplitude.
    public let threshold: RationalValue

    /// Linear target gain when ducking is fully engaged. `1` means no reduction.
    public let reductionGain: RationalValue

    /// Time to ramp from no ducking to full ducking.
    public let attack: RationalTime

    /// Time to ramp from full ducking to no ducking after hold expires.
    public let release: RationalTime

    /// Time to remain fully ducked after the trigger falls below threshold.
    public let hold: RationalTime

    /// Creates an audio ducking rule.
    public init(
        triggerTrackID: UUID,
        targetTrackIDs: [UUID],
        threshold: RationalValue,
        reductionGain: RationalValue,
        attack: RationalTime,
        release: RationalTime,
        hold: RationalTime = .zero
    ) {
        self.triggerTrackID = triggerTrackID
        self.targetTrackIDs = targetTrackIDs
        self.threshold = threshold
        self.reductionGain = reductionGain
        self.attack = attack
        self.release = release
        self.hold = hold
    }
}

/// Typed audio-ducking validation errors.
public enum AudioDuckingValidationError: Equatable, Sendable {
    /// A rule must target at least one audio track.
    case targetTracksEmpty

    /// The trigger track is not present in the sequence audio tracks.
    case triggerTrackMissing(UUID)

    /// A target track is not present in the sequence audio tracks.
    case targetTrackMissing(UUID)

    /// The same target track was listed more than once.
    case duplicateTargetTrack(UUID)

    /// A rule cannot target the same track that drives it.
    case targetMatchesTrigger(UUID)

    /// Trigger threshold is outside the supported linear-amplitude range.
    case thresholdOutOfRange(
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// Fully-ducked gain is outside the supported linear-gain range.
    case reductionGainOutOfRange(
        value: RationalValue,
        minimum: RationalValue,
        maximum: RationalValue
    )

    /// Envelope timing values must not be negative.
    case timeNegative(parameter: AudioDuckingTimeParameter, duration: RationalTime)
}

enum AudioDuckingValidator {
    static func indexedErrors(
        for rules: [AudioDuckingRule],
        audioTrackIDs: Set<UUID>
    ) -> [(index: Int, error: AudioDuckingValidationError)] {
        var indexedErrors: [(index: Int, error: AudioDuckingValidationError)] = []
        for index in rules.indices {
            for error in errors(for: rules[index], audioTrackIDs: audioTrackIDs) {
                indexedErrors.append((index: index, error: error))
            }
        }
        return indexedErrors
    }

    static func errors(
        for rule: AudioDuckingRule,
        audioTrackIDs: Set<UUID>
    ) -> [AudioDuckingValidationError] {
        var errors: [AudioDuckingValidationError] = []
        if rule.targetTrackIDs.isEmpty {
            errors.append(.targetTracksEmpty)
        }
        if !audioTrackIDs.contains(rule.triggerTrackID) {
            errors.append(.triggerTrackMissing(rule.triggerTrackID))
        }

        var seenTargetIDs = Set<UUID>()
        for targetTrackID in rule.targetTrackIDs {
            if !audioTrackIDs.contains(targetTrackID) {
                errors.append(.targetTrackMissing(targetTrackID))
            }
            if seenTargetIDs.contains(targetTrackID) {
                errors.append(.duplicateTargetTrack(targetTrackID))
            } else {
                seenTargetIDs.insert(targetTrackID)
            }
            if targetTrackID == rule.triggerTrackID {
                errors.append(.targetMatchesTrigger(targetTrackID))
            }
        }

        appendThresholdErrors(rule.threshold, to: &errors)
        appendReductionGainErrors(rule.reductionGain, to: &errors)
        appendTimeErrors(rule.attack, parameter: .attack, to: &errors)
        appendTimeErrors(rule.release, parameter: .release, to: &errors)
        appendTimeErrors(rule.hold, parameter: .hold, to: &errors)
        return errors
    }

    private static func appendThresholdErrors(
        _ threshold: RationalValue,
        to errors: inout [AudioDuckingValidationError]
    ) {
        if threshold.doubleValue < AudioDuckingLimits.minimumThreshold.doubleValue
            || threshold.doubleValue > AudioDuckingLimits.maximumThreshold.doubleValue {
            errors.append(
                .thresholdOutOfRange(
                    value: threshold,
                    minimum: AudioDuckingLimits.minimumThreshold,
                    maximum: AudioDuckingLimits.maximumThreshold
                )
            )
        }
    }

    private static func appendReductionGainErrors(
        _ reductionGain: RationalValue,
        to errors: inout [AudioDuckingValidationError]
    ) {
        if reductionGain.doubleValue < AudioDuckingLimits.minimumReductionGain.doubleValue
            || reductionGain.doubleValue > AudioDuckingLimits.maximumReductionGain.doubleValue {
            errors.append(
                .reductionGainOutOfRange(
                    value: reductionGain,
                    minimum: AudioDuckingLimits.minimumReductionGain,
                    maximum: AudioDuckingLimits.maximumReductionGain
                )
            )
        }
    }

    private static func appendTimeErrors(
        _ duration: RationalTime,
        parameter: AudioDuckingTimeParameter,
        to errors: inout [AudioDuckingValidationError]
    ) {
        if duration < .zero {
            errors.append(.timeNegative(parameter: parameter, duration: duration))
        }
    }
}
