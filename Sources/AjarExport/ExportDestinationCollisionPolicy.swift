// SPDX-License-Identifier: GPL-3.0-or-later

/// Captures whether the user or caller authorized replacing an existing export destination.
public enum ExportDestinationCollisionPolicy: Equatable, Sendable {
    /// An existing destination was visible and replacement was explicitly confirmed.
    case replaceExisting

    /// The chosen destination was vacant; fail if a file appears before atomic publication.
    case requireVacant
}
