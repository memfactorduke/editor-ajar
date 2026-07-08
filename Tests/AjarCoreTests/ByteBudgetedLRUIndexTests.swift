// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

final class ByteBudgetedLRUIndexTests: XCTestCase {
    func testFRPLAY005EvictsLeastRecentlyUsedFirstWhenBudgetExceeded() {
        var index = ByteBudgetedLRUIndex<String>(byteBudget: 10)

        XCTAssertEqual(index.recordUse(of: "a", byteCount: 4), [])
        XCTAssertEqual(index.recordUse(of: "b", byteCount: 4), [])
        XCTAssertEqual(index.recordUse(of: "c", byteCount: 4), ["a"])

        XCTAssertEqual(index.keysFromLeastRecentlyUsed, ["b", "c"])
        XCTAssertEqual(index.totalByteCount, 8)
        XCTAssertEqual(index.count, 2)
    }

    func testFRPLAY005MarkUsedRefreshesEvictionOrderDeterministically() {
        var index = ByteBudgetedLRUIndex<String>(byteBudget: 10)
        _ = index.recordUse(of: "a", byteCount: 4)
        _ = index.recordUse(of: "b", byteCount: 4)

        index.markUsed("a")

        XCTAssertEqual(index.recordUse(of: "c", byteCount: 4), ["b"])
        XCTAssertEqual(index.keysFromLeastRecentlyUsed, ["a", "c"])
    }

    func testFRPLAY005OversizedEntryEvictsEverythingIncludingItself() {
        var index = ByteBudgetedLRUIndex<String>(byteBudget: 10)
        _ = index.recordUse(of: "a", byteCount: 4)

        XCTAssertEqual(index.recordUse(of: "huge", byteCount: 100), ["a", "huge"])
        XCTAssertEqual(index.count, 0)
        XCTAssertEqual(index.totalByteCount, 0)
    }

    func testFRPLAY005ReRecordingUpdatesSizeWithoutDoubleCounting() {
        var index = ByteBudgetedLRUIndex<String>(byteBudget: 10)
        _ = index.recordUse(of: "a", byteCount: 4)
        _ = index.recordUse(of: "a", byteCount: 6)

        XCTAssertEqual(index.totalByteCount, 6)
        XCTAssertEqual(index.byteCount(for: "a"), 6)
        XCTAssertEqual(index.count, 1)
    }

    func testFRPLAY005RemoveReleasesTrackedBytes() {
        var index = ByteBudgetedLRUIndex<String>(byteBudget: 10)
        _ = index.recordUse(of: "a", byteCount: 4)
        _ = index.recordUse(of: "b", byteCount: 4)

        index.remove("a")
        index.remove("missing")

        XCTAssertEqual(index.totalByteCount, 4)
        XCTAssertFalse(index.contains("a"))
        XCTAssertEqual(index.keysFromLeastRecentlyUsed, ["b"])
    }

    func testFRPLAY005NegativeInputsClampToZero() {
        var index = ByteBudgetedLRUIndex<String>(byteBudget: -5)

        XCTAssertEqual(index.byteBudget, 0)
        XCTAssertEqual(index.recordUse(of: "a", byteCount: -3), [])
        XCTAssertEqual(index.totalByteCount, 0)
        XCTAssertTrue(index.contains("a"))
    }

    func testFRPLAY005EvictionSequenceIsDeterministicAcrossManyEntries() {
        var first = ByteBudgetedLRUIndex<Int>(byteBudget: 50)
        var second = ByteBudgetedLRUIndex<Int>(byteBudget: 50)
        var firstEvictions: [Int] = []
        var secondEvictions: [Int] = []

        for key in 0..<40 {
            firstEvictions.append(contentsOf: first.recordUse(of: key, byteCount: 7))
            secondEvictions.append(contentsOf: second.recordUse(of: key, byteCount: 7))
        }

        XCTAssertEqual(firstEvictions, secondEvictions)
        XCTAssertEqual(first.keysFromLeastRecentlyUsed, second.keysFromLeastRecentlyUsed)
        XCTAssertLessThanOrEqual(first.totalByteCount, 50)
    }
}
