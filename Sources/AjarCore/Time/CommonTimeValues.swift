// SPDX-License-Identifier: GPL-3.0-or-later

/// Two exact time numerators represented at the same positive timescale.
public struct CommonTimeValues: Codable, Hashable, Sendable {
    /// The left-hand value's numerator at `timescale`.
    public let left: Int64

    /// The right-hand value's numerator at `timescale`.
    public let right: Int64

    /// The common positive timescale shared by `left` and `right`.
    public let timescale: Int64
}
