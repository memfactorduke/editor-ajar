// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarExport
import Foundation

/// Errors from app-side custom export-preset persistence (FR-EXP-003).
///
/// Custom presets are **not** part of the project document. They live under Application Support
/// so they do not affect `schemaMinor` / ADR-0018 project versioning.
enum EditorAjarExportPresetStoreError: Error, Equatable, CustomStringConvertible {
    case encodingFailed(String)
    case decodingFailed(String)
    case ioFailed(String)

    var description: String {
        switch self {
        case .encodingFailed(let reason):
            "export preset encode failed: \(reason)"
        case .decodingFailed(let reason):
            "export preset decode failed: \(reason)"
        case .ioFailed(let reason):
            "export preset I/O failed: \(reason)"
        }
    }
}

/// On-disk envelope for custom presets only (built-ins are never persisted).
struct EditorAjarExportPresetFile: Codable, Equatable, Sendable {
    var presets: [ExportPreset]
}

/// Application Support JSON store for **custom** export presets (FR-EXP-003).
///
/// Writes use `AjarAtomicFileWriter` (same-directory temp + replace). Built-in presets are never
/// written here; the app merges them at load time for the picker.
struct EditorAjarExportPresetStore: Sendable {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Default path: `~/Library/Application Support/EditorAjar/export-presets.json`.
    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("EditorAjar", isDirectory: true)
            .appendingPathComponent("export-presets.json")
    }

    /// Loads custom presets; missing file yields an empty list.
    func loadCustomPresets() throws -> [ExportPreset] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw EditorAjarExportPresetStoreError.ioFailed(String(describing: error))
        }
        do {
            let decoded = try JSONDecoder().decode(EditorAjarExportPresetFile.self, from: data)
            return decoded.presets.filter { !$0.isBuiltIn }
        } catch {
            throw EditorAjarExportPresetStoreError.decodingFailed(String(describing: error))
        }
    }

    /// Atomically replaces the custom-preset file (built-ins must not be included).
    func saveCustomPresets(_ presets: [ExportPreset]) throws {
        let customs = presets.filter { !$0.isBuiltIn }
        let envelope = EditorAjarExportPresetFile(presets: customs)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(envelope)
        } catch {
            throw EditorAjarExportPresetStoreError.encodingFailed(String(describing: error))
        }
        do {
            try AjarAtomicFileWriter.write(data, to: fileURL, fileManager: fileManager)
        } catch {
            throw EditorAjarExportPresetStoreError.ioFailed(String(describing: error))
        }
    }

    /// Built-ins first, then custom presets (picker order).
    static func mergedPresets(custom: [ExportPreset]) -> [ExportPreset] {
        ExportBuiltInPresets.all + custom.filter { !$0.isBuiltIn }
    }
}
