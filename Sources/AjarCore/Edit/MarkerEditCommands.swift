// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension EditReducer {
    static func addMarker(
        _ marker: Marker,
        sequenceID: UUID,
        to project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            guard !sequence.markers.contains(where: { $0.id == marker.id }) else {
                throw EditReducerError.duplicateMarkerID(
                    sequenceID: sequenceID,
                    markerID: marker.id
                )
            }

            return copying(sequence, markers: sortedMarkers(sequence.markers + [marker]))
        }
    }

    static func removeMarker(
        markerID: UUID,
        sequenceID: UUID,
        from project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            var markers = sequence.markers
            guard let index = markers.firstIndex(where: { $0.id == markerID }) else {
                throw EditReducerError.markerNotFound(sequenceID: sequenceID, markerID: markerID)
            }

            markers.remove(at: index)
            return copying(sequence, markers: markers)
        }
    }

    static func updateMarker(
        _ marker: Marker,
        sequenceID: UUID,
        in project: Project
    ) throws -> Project {
        try replacingSequence(in: project, sequenceID: sequenceID) { sequence in
            var markers = sequence.markers
            guard let index = markers.firstIndex(where: { $0.id == marker.id }) else {
                throw EditReducerError.markerNotFound(sequenceID: sequenceID, markerID: marker.id)
            }

            markers[index] = marker
            return copying(sequence, markers: sortedMarkers(markers))
        }
    }
}
