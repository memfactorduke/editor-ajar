// SPDX-License-Identifier: GPL-3.0-or-later

extension ProjectValidator {
    static func validateAudioDucking(
        in sequence: Sequence,
        state: inout ValidationState
    ) {
        let audioTrackIDs = Set(sequence.audioTracks.map(\.id))
        for indexedError in AudioDuckingValidator.indexedErrors(
            for: sequence.audioDucking,
            audioTrackIDs: audioTrackIDs
        ) {
            state.errors.append(
                .invalidAudioDucking(
                    sequenceID: sequence.id,
                    ruleIndex: indexedError.index,
                    error: indexedError.error
                )
            )
        }
    }
}
