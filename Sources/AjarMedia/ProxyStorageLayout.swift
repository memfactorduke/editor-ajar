// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

/// Package-relative layout for regeneratable proxy media (FR-MED-004 / ADR-0007).
///
/// Proxies live under `caches/proxies/` inside the `.ajar` package. They travel with the package
/// but are excluded from document identity/hashing (ADR-0007). Safe to delete anytime.
public enum ProxyStorageLayout {
    /// Directory segment under the package root that holds proxies.
    public static let proxiesDirectoryComponents = ["caches", "proxies"]

    /// Builds a package-relative proxy path:
    /// `caches/proxies/<mediaID>-<contentHash-prefix>-<width>x<height>.mov`.
    public static func relativePath(
        mediaID: UUID,
        contentHash: ContentHash?,
        resolution: PixelDimensions
    ) -> String {
        let hashPrefix = contentHashPrefix(contentHash)
        let fileName =
            "\(mediaID.uuidString.lowercased())-\(hashPrefix)-"
            + "\(resolution.width)x\(resolution.height).mov"
        return (proxiesDirectoryComponents + [fileName]).joined(separator: "/")
    }

    /// Absolute URL for a package-relative proxy path under `packageRootURL`.
    public static func absoluteURL(
        packageRootURL: URL,
        relativePath: String
    ) -> URL {
        relativePath.split(separator: "/").reduce(packageRootURL) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    /// Ensures `caches/proxies/` exists under the package root.
    public static func ensureProxiesDirectory(
        packageRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = proxiesDirectoryComponents.reduce(packageRootURL) { partial, component in
            partial.appendingPathComponent(component)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Short stable prefix of the content hash for path uniqueness across relinks.
    public static func contentHashPrefix(_ contentHash: ContentHash?, length: Int = 12) -> String {
        guard let contentHash else {
            return "nohash"
        }
        let digest = contentHash.digest.lowercased()
        if digest.count <= length {
            return digest
        }
        return String(digest.prefix(length))
    }
}
