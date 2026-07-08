// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

final class RenderFrameDiskCacheEntryTests: XCTestCase {
    func testFRPLAY005EntryRoundTripsThroughVersionedBinaryFormat() throws {
        let entry = try makeEntry()

        let decoded = try RenderFrameDiskCacheEntry.decode(entry.encoded())

        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.identity.contentHash, entry.identity.contentHash)
        XCTAssertEqual(decoded.bytesPerRow, 8)
        XCTAssertEqual(decoded.payload, entry.payload)
    }

    func testFRPLAY005DecodeValidatesExpectedIdentity() throws {
        let entry = try makeEntry()
        let otherIdentity = try makeIdentity(width: 4, height: 4)

        XCTAssertNoThrow(
            try RenderFrameDiskCacheEntry.decode(entry.encoded(), expecting: entry.identity)
        )
        XCTAssertThrowsError(
            try RenderFrameDiskCacheEntry.decode(entry.encoded(), expecting: otherIdentity)
        ) { error in
            XCTAssertEqual(
                error as? RenderFrameDiskCacheEntryError,
                .identityMismatch
            )
        }
    }

    func testFRPLAY005InvalidMagicDecodesAsTypedError() throws {
        var data = try makeEntry().encoded()
        data[data.startIndex] = 0x00

        XCTAssertThrowsError(try RenderFrameDiskCacheEntry.decode(data)) { error in
            XCTAssertEqual(error as? RenderFrameDiskCacheEntryError, .invalidMagic)
        }
    }

    func testFRPLAY005UnsupportedFormatVersionDecodesAsTypedError() throws {
        var data = try makeEntry().encoded()
        data[data.index(data.startIndex, offsetBy: 4)] = 0xff

        XCTAssertThrowsError(try RenderFrameDiskCacheEntry.decode(data)) { error in
            guard case .unsupportedFormatVersion = error as? RenderFrameDiskCacheEntryError else {
                XCTFail("expected unsupportedFormatVersion, got \(error)")
                return
            }
        }
    }

    func testFRPLAY005TruncatedEntryDecodesAsTypedError() throws {
        let data = try makeEntry().encoded()

        for prefixLength in [0, 3, 4, 12, 30, data.count - 20] {
            let truncated = data.prefix(prefixLength)
            XCTAssertThrowsError(
                try RenderFrameDiskCacheEntry.decode(Data(truncated)),
                "prefix length \(prefixLength) must not decode"
            )
        }
    }

    func testFRPLAY005TruncatedPayloadDecodesAsSizeMismatch() throws {
        let data = try makeEntry().encoded()
        let truncated = Data(data.dropLast(1))

        XCTAssertThrowsError(try RenderFrameDiskCacheEntry.decode(truncated)) { error in
            guard case .payloadSizeMismatch = error as? RenderFrameDiskCacheEntryError else {
                XCTFail("expected payloadSizeMismatch, got \(error)")
                return
            }
        }
    }

    func testFRPLAY005CorruptPayloadByteDecodesAsChecksumMismatch() throws {
        var data = try makeEntry().encoded()
        let lastIndex = data.index(before: data.endIndex)
        data[lastIndex] = data[lastIndex] &+ 1

        XCTAssertThrowsError(try RenderFrameDiskCacheEntry.decode(data)) { error in
            XCTAssertEqual(
                error as? RenderFrameDiskCacheEntryError,
                .payloadChecksumMismatch
            )
        }
    }

    func testFRPLAY005InconsistentRowGeometryDecodesAsTypedError() throws {
        // Header declares a row stride that does not tile the payload for the entry's height.
        let entry = RenderFrameDiskCacheEntry(
            identity: try makeIdentity(width: 2, height: 1),
            bytesPerRow: 5,
            payload: Data([1, 2, 3, 4, 5, 6, 7, 8])
        )

        XCTAssertThrowsError(try RenderFrameDiskCacheEntry.decode(entry.encoded())) { error in
            XCTAssertEqual(
                error as? RenderFrameDiskCacheEntryError,
                .invalidHeaderField("bytes per row")
            )
        }
    }

    func testFRPLAY005EntryFileNameIsDeterministicAndIdentityComplete() throws {
        let identity = try makeIdentity(width: 2, height: 1)
        let sameIdentity = try makeIdentity(width: 2, height: 1)
        let otherDimensions = try makeIdentity(width: 4, height: 4)
        let otherColorMode = RenderFrameCacheIdentity(
            contentHash: identity.contentHash,
            colorModeRawValue: 1,
            pixelFormatRawValue: identity.pixelFormatRawValue,
            width: identity.width,
            height: identity.height
        )

        XCTAssertEqual(identity.entryFileName, sameIdentity.entryFileName)
        XCTAssertNotEqual(identity.entryFileName, otherDimensions.entryFileName)
        XCTAssertNotEqual(identity.entryFileName, otherColorMode.entryFileName)
        XCTAssertTrue(identity.entryFileName.hasSuffix(".ajarframe"))
    }

    func testFRCMP006EditedContentHashProducesDifferentFileName() throws {
        let identity = try makeIdentity(width: 2, height: 1)
        let editedIdentity = RenderFrameCacheIdentity(
            contentHash: ContentHash.sha256(data: Data("edited graph".utf8)),
            colorModeRawValue: identity.colorModeRawValue,
            pixelFormatRawValue: identity.pixelFormatRawValue,
            width: identity.width,
            height: identity.height
        )

        XCTAssertNotEqual(identity.entryFileName, editedIdentity.entryFileName)
    }

    private func makeIdentity(width: Int, height: Int) throws -> RenderFrameCacheIdentity {
        RenderFrameCacheIdentity(
            contentHash: ContentHash.sha256(data: Data("frame graph".utf8)),
            colorModeRawValue: 0,
            pixelFormatRawValue: 80,
            width: width,
            height: height
        )
    }

    private func makeEntry() throws -> RenderFrameDiskCacheEntry {
        RenderFrameDiskCacheEntry(
            identity: try makeIdentity(width: 2, height: 1),
            bytesPerRow: 8,
            payload: Data([1, 2, 3, 4, 5, 6, 7, 8])
        )
    }
}
