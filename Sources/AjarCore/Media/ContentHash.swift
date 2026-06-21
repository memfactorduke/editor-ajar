// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Errors produced while constructing content hashes.
public enum ContentHashError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A digest string does not match the selected hash algorithm.
    case invalidDigest(algorithm: ContentHashAlgorithm, digest: String)

    /// A human-readable description of the error.
    public var description: String {
        switch self {
        case .invalidDigest(let algorithm, let digest):
            "invalid \(algorithm.rawValue) digest: \(digest)"
        }
    }
}

/// The algorithm used to produce a media content hash.
public enum ContentHashAlgorithm: String, Codable, Hashable, Sendable {
    /// SHA-256 over the original bytes.
    case sha256
}

/// A stable digest of media bytes used for relinking and project manifests.
public struct ContentHash: Codable, Hashable, Sendable, CustomStringConvertible {
    /// The hash algorithm.
    public let algorithm: ContentHashAlgorithm

    /// The lowercase hexadecimal digest.
    public let digest: String

    /// Decodes and validates a content hash.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let algorithm = try container.decode(ContentHashAlgorithm.self, forKey: .algorithm)
        let digest = try container.decode(String.self, forKey: .digest)

        do {
            try self.init(algorithm: algorithm, digest: digest)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .digest,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    /// Creates a content hash from a hexadecimal digest.
    public init(algorithm: ContentHashAlgorithm = .sha256, digest: String) throws {
        let normalizedDigest = digest.lowercased()
        guard Self.isValidHexDigest(normalizedDigest, for: algorithm) else {
            throw ContentHashError.invalidDigest(algorithm: algorithm, digest: digest)
        }

        self.algorithm = algorithm
        self.digest = normalizedDigest
    }

    /// Computes a SHA-256 content hash over in-memory bytes.
    public static func sha256(bytes: [UInt8]) -> ContentHash {
        ContentHash(algorithm: .sha256, uncheckedDigest: SHA256.hash(bytes: bytes))
    }

    /// Computes a SHA-256 content hash over in-memory data.
    public static func sha256(data: Data) -> ContentHash {
        sha256(bytes: Array(data))
    }

    /// A stable string representation suitable for logs and manifests.
    public var description: String {
        "\(algorithm.rawValue):\(digest)"
    }

    /// Encodes a content hash for `media.json`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(digest, forKey: .digest)
    }

    private init(algorithm: ContentHashAlgorithm, uncheckedDigest digest: String) {
        self.algorithm = algorithm
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case digest
    }

    private static func isValidHexDigest(
        _ digest: String,
        for algorithm: ContentHashAlgorithm
    ) -> Bool {
        let expectedLength: Int
        switch algorithm {
        case .sha256:
            expectedLength = 64
        }

        guard digest.count == expectedLength else {
            return false
        }

        return digest.allSatisfy { character in
            character.isHexDigit && character.isLowercaseHexCompatible
        }
    }
}

private extension Character {
    var isLowercaseHexCompatible: Bool {
        !isLetter || isLowercase
    }
}

private enum SHA256 {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(bytes: [UInt8]) -> String {
        var hash = initialHash
        let message = paddedMessage(bytes)

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            let schedule = messageSchedule(from: message, chunkStart: chunkStart)
            compress(schedule: schedule, into: &hash)
        }

        return hash.flatMap(bigEndianBytes).map(hexByte).joined()
    }

    private static func paddedMessage(_ bytes: [UInt8]) -> [UInt8] {
        var message = bytes
        let bitLength = UInt64(bytes.count) * 8

        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }

        message.append(contentsOf: bigEndianBytes(bitLength))
        return message
    }

    private static func messageSchedule(from message: [UInt8], chunkStart: Int) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 64)

        for index in 0..<16 {
            let offset = chunkStart + index * 4
            let byte0 = UInt32(message[offset]) << 24
            let byte1 = UInt32(message[offset + 1]) << 16
            let byte2 = UInt32(message[offset + 2]) << 8
            let byte3 = UInt32(message[offset + 3])
            words[index] = byte0 | byte1 | byte2 | byte3
        }

        for index in 16..<64 {
            let s0Part0 = rotateRight(words[index - 15], by: 7)
            let s0Part1 = rotateRight(words[index - 15], by: 18)
            let s0Part2 = words[index - 15] >> 3
            let s0 = s0Part0 ^ s0Part1 ^ s0Part2
            let s1Part0 = rotateRight(words[index - 2], by: 17)
            let s1Part1 = rotateRight(words[index - 2], by: 19)
            let s1Part2 = words[index - 2] >> 10
            let s1 = s1Part0 ^ s1Part1 ^ s1Part2
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }

        return words
    }

    private static func compress(schedule: [UInt32], into hash: inout [UInt32]) {
        var working = hash

        for index in 0..<64 {
            let s1Part0 = rotateRight(working[4], by: 6)
            let s1Part1 = rotateRight(working[4], by: 11)
            let s1Part2 = rotateRight(working[4], by: 25)
            let s1 = s1Part0 ^ s1Part1 ^ s1Part2
            let choose = (working[4] & working[5]) ^ (~working[4] & working[6])
            let temp1 = working[7] &+ s1 &+ choose &+ constants[index] &+ schedule[index]
            let s0Part0 = rotateRight(working[0], by: 2)
            let s0Part1 = rotateRight(working[0], by: 13)
            let s0Part2 = rotateRight(working[0], by: 22)
            let s0 = s0Part0 ^ s0Part1 ^ s0Part2
            let majorityPart0 = working[0] & working[1]
            let majorityPart1 = working[0] & working[2]
            let majorityPart2 = working[1] & working[2]
            let majority = majorityPart0 ^ majorityPart1 ^ majorityPart2
            let temp2 = s0 &+ majority

            working[7] = working[6]
            working[6] = working[5]
            working[5] = working[4]
            working[4] = working[3] &+ temp1
            working[3] = working[2]
            working[2] = working[1]
            working[1] = working[0]
            working[0] = temp1 &+ temp2
        }

        for index in 0..<8 {
            hash[index] = hash[index] &+ working[index]
        }
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
        return bytes
    }

    private static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(UInt8((value >> 56) & 0xff))
        bytes.append(UInt8((value >> 48) & 0xff))
        bytes.append(UInt8((value >> 40) & 0xff))
        bytes.append(UInt8((value >> 32) & 0xff))
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
        return bytes
    }

    private static func hexByte(_ byte: UInt8) -> String {
        let hex = String(byte, radix: 16)
        if byte < 16 {
            return "0" + hex
        }
        return hex
    }
}
