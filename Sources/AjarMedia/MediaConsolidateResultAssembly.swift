// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

extension MediaConsolidateCommand {
    func missingSourceFailure(for media: MediaRef) -> MediaConsolidateFailure {
        MediaConsolidateFailure(
            mediaID: media.id,
            reason: .sourceResolutionFailed(
                .sourceMissing(mediaID: media.id, lastKnownURL: media.sourceURL)
            )
        )
    }

    func makeResult(
        prepared: [PreparedConsolidation],
        failure: MediaConsolidateFailure?
    ) -> MediaConsolidateResult {
        let replacements = prepared.map(\.reference)
        let command =
            prepared.isEmpty
            ? nil
            : EditCommand.updateMediaReferences(kind: .consolidate, replacements: replacements)
        return MediaConsolidateResult(
            command: command,
            publishedFileURLs: prepared.map(\.destinationURL),
            consolidatedMediaIDs: prepared.map(\.reference.id),
            failure: failure
        )
    }
}
