// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

enum MediaBrowserLayout: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
}

enum MediaBrowserFilter: String, CaseIterable, Identifiable {
    case all
    case offline
    case proxyReady
    case proxyPending

    var id: String { rawValue }
}

struct MediaBrowserQuery {
    var searchText = ""
    var codec = "all"
    var filter: MediaBrowserFilter = .all

    func results(in media: [MediaRef]) -> [MediaRef] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return media.filter { reference in
            let name = reference.sourceURL?.lastPathComponent.lowercased() ?? ""
            let codecMatches = codec == "all" || reference.metadata.codecID == codec
            let searchMatches = needle.isEmpty
                || name.contains(needle)
                || reference.metadata.codecID.lowercased().contains(needle)
            return codecMatches && searchMatches && stateMatches(reference)
        }
    }

    private func stateMatches(_ reference: MediaRef) -> Bool {
        switch filter {
        case .all:
            return true
        case .offline:
            return reference.isOffline
        case .proxyReady:
            return reference.proxyState.isReady
        case .proxyPending:
            switch reference.proxyState {
            case .generating, .failed:
                return true
            case .none, .ready:
                return false
            }
        }
    }
}

