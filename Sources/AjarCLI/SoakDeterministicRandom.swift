// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Deterministic SplitMix64 generator for the `ajar soak` scripted loop.
///
/// TESTING §3 forbids RNG without a seeded, recorded seed: the soak records its seed in the
/// run header and every draw below is a pure function of it, so a failing soak replays exactly.
struct SoakDeterministicRandom: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator whose entire draw sequence is determined by `seed`.
    init(seed: UInt64) {
        state = seed
    }

    /// Returns the next SplitMix64 value.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Draws a deterministic UUID for script-created entities (blade halves, compounds).
    mutating func uuid() -> UUID {
        let high = next()
        let low = next()
        return UUID(
            uuid: (
                UInt8(truncatingIfNeeded: high >> 56), UInt8(truncatingIfNeeded: high >> 48),
                UInt8(truncatingIfNeeded: high >> 40), UInt8(truncatingIfNeeded: high >> 32),
                UInt8(truncatingIfNeeded: high >> 24), UInt8(truncatingIfNeeded: high >> 16),
                UInt8(truncatingIfNeeded: high >> 8), UInt8(truncatingIfNeeded: high),
                UInt8(truncatingIfNeeded: low >> 56), UInt8(truncatingIfNeeded: low >> 48),
                UInt8(truncatingIfNeeded: low >> 40), UInt8(truncatingIfNeeded: low >> 32),
                UInt8(truncatingIfNeeded: low >> 24), UInt8(truncatingIfNeeded: low >> 16),
                UInt8(truncatingIfNeeded: low >> 8), UInt8(truncatingIfNeeded: low)
            )
        )
    }

    /// Draws a deterministic integer in `range`.
    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// Draws a deterministic boolean.
    mutating func bool() -> Bool {
        Bool.random(using: &self)
    }
}
