// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

struct GoldenFrameManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let requirements: [String]
    let frame: String
    let referencePNG: String
    let outputDimensions: PixelDimensions?
    let syntheticMedia: SyntheticMovieSpec?
    let clips: [GoldenFrameClipSpec]?
    let tolerance: GoldenFrameTolerance

    static func load(from url: URL) throws -> GoldenFrameManifest {
        do {
            let manifest = try JSONDecoder().decode(
                GoldenFrameManifest.self,
                from: try Data(contentsOf: url)
            )
            guard manifest.schemaVersion == 1 else {
                throw AjarCLIError.invalidGoldenManifest(
                    "\(url.path) uses unsupported schema \(manifest.schemaVersion)"
                )
            }
            guard !manifest.requirements.isEmpty else {
                throw AjarCLIError.invalidGoldenManifest("\(url.path) has no requirement refs")
            }
            _ = try manifest.resolvedClipSpecs()
            return manifest
        } catch let error as AjarCLIError {
            throw error
        } catch {
            throw AjarCLIError.invalidGoldenManifest(
                "\(url.path): \(String(describing: error))"
            )
        }
    }

    func resolvedClipSpecs() throws -> [GoldenFrameClipSpec] {
        if let clips, !clips.isEmpty {
            return clips
        }
        if let syntheticMedia {
            return [
                GoldenFrameClipSpec(
                    syntheticMedia: syntheticMedia,
                    compound: nil,
                    speed: nil,
                    reverse: nil,
                    freezeFrame: nil,
                    timeRemap: nil,
                    transform: nil,
                    transformAnimation: nil,
                    effects: nil,
                    effectsAnimation: nil,
                    trackOpacity: nil,
                    trackBlendMode: nil
                )
            ]
        }
        throw AjarCLIError.invalidGoldenManifest("\(id) has no synthetic media")
    }
}

struct GoldenFrameClipSpec: Codable, Equatable, Sendable {
    let syntheticMedia: SyntheticMovieSpec
    let compound: GoldenFrameCompoundSpec?
    let speed: RationalValue?
    let reverse: Bool?
    let freezeFrame: Bool?
    let timeRemap: [GoldenTimeRemapKeyframeSpec]?
    let transform: ClipTransform?
    let transformAnimation: AnimatableClipTransform?
    let effects: ClipEffects?
    let effectsAnimation: AnimatableClipEffects?
    let trackOpacity: Animatable<RationalValue>?
    let trackBlendMode: ClipBlendMode?
}

struct GoldenFrameCompoundSpec: Codable, Equatable, Sendable {
    let innerTransform: ClipTransform?
    let innerEffects: ClipEffects?
}
