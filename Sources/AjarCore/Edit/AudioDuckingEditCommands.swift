// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    static func setSequenceAudioDucking(
        sequenceID: UUID,
        ducking: [AudioDuckingRule],
        in project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            try validateAudioDucking(ducking, sequence: sequence)
            return copying(sequence, audioDucking: ducking)
        }
    }

    static func clearSequenceAudioDucking(
        sequenceID: UUID,
        in project: Project
    ) throws -> Project {
        try setSequenceAudioDucking(sequenceID: sequenceID, ducking: [], in: project)
    }

    static func validateAudioDucking(
        _ ducking: [AudioDuckingRule],
        sequence: Sequence
    ) throws {
        let audioTrackIDs = Set(sequence.audioTracks.map(\.id))
        guard let indexedError = AudioDuckingValidator.indexedErrors(
            for: ducking,
            audioTrackIDs: audioTrackIDs
        ).first else {
            return
        }

        throw EditReducerError.invalidEdit(
            .invalidAudioDucking(
                sequenceID: sequence.id,
                ruleIndex: indexedError.index,
                error: indexedError.error
            )
        )
    }
}
