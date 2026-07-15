// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

struct ConsolidateObjectIdentity: Codable, Hashable {
    let device: UInt64
    let inode: UInt64
}

struct ConsolidateFileIdentity: Codable, Hashable {
    let device: UInt64
    let inode: UInt64
    let fileType: UInt32

    init(_ information: stat) {
        device = UInt64(bitPattern: Int64(information.st_dev))
        inode = UInt64(information.st_ino)
        fileType = UInt32(information.st_mode) & UInt32(S_IFMT)
    }

    var objectIdentity: ConsolidateObjectIdentity {
        ConsolidateObjectIdentity(device: device, inode: inode)
    }

    var isRegularFile: Bool { fileType == UInt32(S_IFREG) }

    private enum CodingKeys: String, CodingKey {
        case device
        case inode
        case fileType
        case mode
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(UInt64.self, forKey: .device)
        inode = try values.decode(UInt64.self, forKey: .inode)
        if let encodedFileType = try values.decodeIfPresent(UInt32.self, forKey: .fileType) {
            fileType = encodedFileType
        } else {
            let legacyMode = try values.decode(UInt32.self, forKey: .mode)
            fileType = legacyMode & UInt32(S_IFMT)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(device, forKey: .device)
        try values.encode(inode, forKey: .inode)
        try values.encode(fileType, forKey: .fileType)
    }

    static func followingSymlinks(at url: URL) throws -> ConsolidateFileIdentity? {
        var information = stat()
        let result = url.path.withCString { path in
            fstatat(AT_FDCWD, path, &information, 0)
        }
        if result != 0, errno == ENOENT { return nil }
        guard result == 0 else {
            throw ConsolidateStalePartialRemovalError.operationFailed(
                operation: "inspect protected source",
                url: url,
                code: errno
            )
        }
        return ConsolidateFileIdentity(information)
    }

    static func withoutFollowingSymlinks(at url: URL) throws -> ConsolidateFileIdentity {
        var information = stat()
        let result = url.path.withCString { path in lstat(path, &information) }
        guard result == 0 else {
            throw ConsolidateStalePartialRemovalError.operationFailed(
                operation: "inspect stale entry",
                url: url,
                code: errno
            )
        }
        return ConsolidateFileIdentity(information)
    }
}
