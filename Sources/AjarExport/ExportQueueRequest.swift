// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Internal type erasure for the movie and animated-GIF requests scheduled by `ExportQueue`.
enum ExportQueueRequest: Sendable {
    case movie(ExportRequest)
    case animatedGIF(AnimatedGIFExportRequest)

    var kind: ExportJobKind {
        switch self {
        case .movie:
            .movie
        case .animatedGIF:
            .animatedGIF
        }
    }

    var destinationURL: URL {
        switch self {
        case .movie(let request):
            request.destinationURL
        case .animatedGIF(let request):
            request.destinationURL
        }
    }

    var destinationCollisionPolicy: ExportDestinationCollisionPolicy {
        switch self {
        case .movie(let request):
            request.destinationCollisionPolicy
        case .animatedGIF(let request):
            request.destinationCollisionPolicy
        }
    }

    var sequenceID: UUID {
        switch self {
        case .movie(let request):
            request.sequenceID
        case .animatedGIF(let request):
            request.sequenceID
        }
    }
}
