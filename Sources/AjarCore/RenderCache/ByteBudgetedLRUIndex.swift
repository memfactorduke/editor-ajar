// SPDX-License-Identifier: GPL-3.0-or-later

/// Deterministic least-recently-used index bounded by a total byte budget (FR-PLAY-005).
///
/// The disk frame cache uses this pure index to decide which entries to delete. The eviction
/// rule is deterministic and documented: after any `recordUse(of:byteCount:)`, entries are
/// evicted strictly least-recently-used first until the total is at or under the budget. The
/// key that was just recorded is always the most recently used, so it is evicted only when it
/// alone exceeds the whole budget.
public struct ByteBudgetedLRUIndex<Key: Hashable> {
    /// Maximum total payload bytes retained by the index.
    public let byteBudget: Int

    /// Total bytes currently tracked by the index.
    public private(set) var totalByteCount = 0

    private var order: [Key] = []
    private var sizes: [Key: Int] = [:]

    /// Creates an index with a byte budget; negative budgets clamp to zero.
    public init(byteBudget: Int) {
        self.byteBudget = max(0, byteBudget)
    }

    /// Number of entries currently tracked by the index.
    public var count: Int {
        order.count
    }

    /// All tracked keys ordered from least to most recently used.
    public var keysFromLeastRecentlyUsed: [Key] {
        order
    }

    /// Whether the index tracks the key.
    public func contains(_ key: Key) -> Bool {
        sizes[key] != nil
    }

    /// The tracked byte count for a key, or nil when untracked.
    public func byteCount(for key: Key) -> Int? {
        sizes[key]
    }

    /// Marks a tracked key as most recently used without changing its size.
    public mutating func markUsed(_ key: Key) {
        guard sizes[key] != nil else {
            return
        }
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Removes a key from the index.
    public mutating func remove(_ key: Key) {
        guard let size = sizes.removeValue(forKey: key) else {
            return
        }
        totalByteCount -= size
        order.removeAll { $0 == key }
    }

    /// Records a key as most recently used with its byte count and returns the evicted keys.
    ///
    /// Existing keys are re-sized and refreshed. Eviction is least-recently-used first until the
    /// total byte count fits the budget; the returned keys are in eviction order.
    public mutating func recordUse(of key: Key, byteCount: Int) -> [Key] {
        let clampedByteCount = max(0, byteCount)
        if let existingByteCount = sizes[key] {
            totalByteCount -= existingByteCount
        }
        sizes[key] = clampedByteCount
        totalByteCount += clampedByteCount
        order.removeAll { $0 == key }
        order.append(key)
        return evictUntilWithinBudget()
    }

    private mutating func evictUntilWithinBudget() -> [Key] {
        var evictedKeys: [Key] = []
        while totalByteCount > byteBudget, let leastRecentlyUsedKey = order.first {
            order.removeFirst()
            if let size = sizes.removeValue(forKey: leastRecentlyUsedKey) {
                totalByteCount -= size
            }
            evictedKeys.append(leastRecentlyUsedKey)
        }
        return evictedKeys
    }
}

extension ByteBudgetedLRUIndex: Sendable where Key: Sendable {}
