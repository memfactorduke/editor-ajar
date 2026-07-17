// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Builds conservative reservation keys for export outputs that may not exist yet.
enum ExportDestinationReservation {
    /// Resolving the existing parent catches aliases such as `/tmp` vs `/private/tmp`; Unicode
    /// normalization and case folding prevent a case-insensitive macOS volume from treating two
    /// spellings as distinct reservations. On a case-sensitive volume this can reject a safe
    /// case-only pair, which is preferable to allowing one queued export to destroy another.
    static func key(for destinationURL: URL) -> String {
        let standardized = destinationURL.standardizedFileURL
        let resolvedParent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolvedDestination = resolvedParent.appendingPathComponent(
            standardized.lastPathComponent,
            isDirectory: false
        )
        let normalizedPath = resolvedDestination.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        return normalizedPath.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
