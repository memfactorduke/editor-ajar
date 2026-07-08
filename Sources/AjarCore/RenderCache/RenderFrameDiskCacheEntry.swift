// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Errors produced while encoding or decoding a disk frame cache entry.
public enum RenderFrameDiskCacheEntryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The entry is shorter than its declared layout.
    case truncatedEntry(expectedAtLeast: Int, actual: Int)

    /// The entry does not start with the frame cache magic bytes.
    case invalidMagic

    /// The entry was written by an unknown on-disk format version.
    case unsupportedFormatVersion(UInt32)

    /// A header field failed validation.
    case invalidHeaderField(String)

    /// The payload byte count declared by the header does not match the stored payload.
    case payloadSizeMismatch(declared: Int, actual: Int)

    /// The stored payload does not match the header checksum.
    case payloadChecksumMismatch

    /// The decoded identity does not match the identity the caller asked for.
    case identityMismatch

    /// A human-readable description of the failure.
    public var description: String {
        switch self {
        case .truncatedEntry(let expectedAtLeast, let actual):
            "truncated frame cache entry: expected at least \(expectedAtLeast) bytes, got \(actual)"
        case .invalidMagic:
            "frame cache entry magic bytes are invalid"
        case .unsupportedFormatVersion(let version):
            "unsupported frame cache entry format version \(version)"
        case .invalidHeaderField(let field):
            "invalid frame cache entry header field: \(field)"
        case .payloadSizeMismatch(let declared, let actual):
            "frame cache payload size mismatch: header declares \(declared) bytes, got \(actual)"
        case .payloadChecksumMismatch:
            "frame cache payload checksum mismatch"
        case .identityMismatch:
            "frame cache entry identity does not match the requested identity"
        }
    }
}

/// One versioned, self-validating disk cache entry for a rendered frame (FR-PLAY-005).
///
/// On-disk layout, all integers little-endian:
/// magic `AJFC` (4 bytes), format version (u32), color mode raw (u32), pixel format raw (u32),
/// width (u32), height (u32), bytes per row (u32), hash algorithm UTF-8 length (u32) + bytes,
/// hash digest UTF-8 length (u32) + bytes, payload FNV-1a 64 checksum (u64), payload byte
/// count (u64), payload bytes. Any truncation, corruption, or identity mismatch decodes as a
/// typed error so the platform tier can treat the entry as a miss and quarantine it — the disk
/// tier never returns wrong pixels.
public struct RenderFrameDiskCacheEntry: Equatable, Sendable {
    /// The current on-disk format version written by `encoded()`.
    public static let formatVersion: UInt32 = 1

    /// The magic bytes that start every entry.
    public static let magic: [UInt8] = Array("AJFC".utf8)

    /// The cache identity of the stored frame.
    public let identity: RenderFrameCacheIdentity

    /// Number of payload bytes per pixel row.
    public let bytesPerRow: Int

    /// Tightly packed pixel bytes for the frame.
    public let payload: Data

    /// Creates an entry from decoded or captured frame bytes.
    public init(identity: RenderFrameCacheIdentity, bytesPerRow: Int, payload: Data) {
        self.identity = identity
        self.bytesPerRow = max(0, bytesPerRow)
        self.payload = payload
    }

    /// Serializes the entry into the versioned on-disk format.
    public func encoded() -> Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        data.appendLittleEndian(Self.formatVersion)
        data.appendLittleEndian(identity.colorModeRawValue)
        data.appendLittleEndian(identity.pixelFormatRawValue)
        data.appendLittleEndian(UInt32(clamping: identity.width))
        data.appendLittleEndian(UInt32(clamping: identity.height))
        data.appendLittleEndian(UInt32(clamping: bytesPerRow))
        data.appendLengthPrefixedUTF8(identity.contentHash.algorithm.rawValue)
        data.appendLengthPrefixedUTF8(identity.contentHash.digest)
        data.appendLittleEndian(Self.fnv1a64(payload))
        data.appendLittleEndian(UInt64(payload.count))
        data.append(payload)
        return data
    }

    /// Decodes and fully validates an entry, optionally checking it against an expected identity.
    public static func decode(
        _ data: Data,
        expecting expectedIdentity: RenderFrameCacheIdentity? = nil
    ) throws -> RenderFrameDiskCacheEntry {
        var reader = LittleEndianReader(data: data)
        guard try reader.readBytes(count: magic.count) == magic else {
            throw RenderFrameDiskCacheEntryError.invalidMagic
        }
        let version = try reader.readUInt32()
        guard version == formatVersion else {
            throw RenderFrameDiskCacheEntryError.unsupportedFormatVersion(version)
        }

        let (identity, bytesPerRow) = try readHeaderFields(&reader)
        let checksum = try reader.readUInt64()
        let declaredPayloadCount = try reader.readUInt64()
        let payload = try reader.readRemainder()
        guard UInt64(payload.count) == declaredPayloadCount else {
            throw RenderFrameDiskCacheEntryError.payloadSizeMismatch(
                declared: Int(clamping: declaredPayloadCount),
                actual: payload.count
            )
        }
        guard fnv1a64(payload) == checksum else {
            throw RenderFrameDiskCacheEntryError.payloadChecksumMismatch
        }
        if let expectedIdentity, expectedIdentity != identity {
            throw RenderFrameDiskCacheEntryError.identityMismatch
        }

        return RenderFrameDiskCacheEntry(
            identity: identity,
            bytesPerRow: bytesPerRow,
            payload: payload
        )
    }

    private static func readHeaderFields(
        _ reader: inout LittleEndianReader
    ) throws -> (identity: RenderFrameCacheIdentity, bytesPerRow: Int) {
        let colorModeRawValue = try reader.readUInt32()
        let pixelFormatRawValue = try reader.readUInt32()
        let width = Int(try reader.readUInt32())
        let height = Int(try reader.readUInt32())
        let bytesPerRow = Int(try reader.readUInt32())
        let algorithmString = try reader.readLengthPrefixedUTF8(fieldName: "hash algorithm")
        guard let algorithm = ContentHashAlgorithm(rawValue: algorithmString) else {
            throw RenderFrameDiskCacheEntryError.invalidHeaderField("hash algorithm")
        }
        let digest = try reader.readLengthPrefixedUTF8(fieldName: "hash digest")
        let contentHash: ContentHash
        do {
            contentHash = try ContentHash(algorithm: algorithm, digest: digest)
        } catch {
            throw RenderFrameDiskCacheEntryError.invalidHeaderField("hash digest")
        }

        let identity = RenderFrameCacheIdentity(
            contentHash: contentHash,
            colorModeRawValue: colorModeRawValue,
            pixelFormatRawValue: pixelFormatRawValue,
            width: width,
            height: height
        )
        return (identity, bytesPerRow)
    }

    /// Computes the 64-bit FNV-1a checksum used to detect payload corruption.
    static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

private struct LittleEndianReader {
    private let data: Data
    private(set) var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else {
            throw RenderFrameDiskCacheEntryError.truncatedEntry(
                expectedAtLeast: offset + max(count, 0),
                actual: data.count
            )
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Array(data[start..<end])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.enumerated().reduce(UInt32(0)) { partial, element in
            partial | (UInt32(element.element) << (8 * UInt32(element.offset)))
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(count: 8)
        return bytes.enumerated().reduce(UInt64(0)) { partial, element in
            partial | (UInt64(element.element) << (8 * UInt64(element.offset)))
        }
    }

    mutating func readLengthPrefixedUTF8(fieldName: String) throws -> String {
        let count = Int(try readUInt32())
        guard count <= 1024 else {
            throw RenderFrameDiskCacheEntryError.invalidHeaderField(fieldName)
        }
        let bytes = try readBytes(count: count)
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw RenderFrameDiskCacheEntryError.invalidHeaderField(fieldName)
        }
        return string
    }

    mutating func readRemainder() throws -> Data {
        let start = data.index(data.startIndex, offsetBy: offset)
        offset = data.count
        return Data(data[start...])
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func appendLengthPrefixedUTF8(_ string: String) {
        let bytes = Array(string.utf8)
        appendLittleEndian(UInt32(clamping: bytes.count))
        append(contentsOf: bytes)
    }
}
