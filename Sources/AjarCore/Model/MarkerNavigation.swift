// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure marker navigation helpers.
public enum MarkerNavigation {
    /// Returns the first marker strictly after `time`, or `nil` when no later marker exists.
    public static func nextMarker(in sequence: Sequence, after time: RationalTime) -> Marker? {
        sortedMarkers(in: sequence).first { marker in
            marker.time > time
        }
    }

    /// Returns the last marker strictly before `time`, or `nil` when no earlier marker exists.
    public static func previousMarker(in sequence: Sequence, before time: RationalTime) -> Marker? {
        sortedMarkers(in: sequence).last { marker in
            marker.time < time
        }
    }

    private static func sortedMarkers(in sequence: Sequence) -> [Marker] {
        sequence.markers.sorted { left, right in
            if left.time == right.time {
                return left.id.uuidString < right.id.uuidString
            }
            return left.time < right.time
        }
    }
}
