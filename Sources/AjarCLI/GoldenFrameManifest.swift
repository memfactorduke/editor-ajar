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
            for clip in clips {
                try clip.validateSourcePayload(manifestID: id)
            }
            return clips
        }
        if let syntheticMedia {
            return [
                GoldenFrameClipSpec(
                    syntheticMedia: syntheticMedia,
                    offline: nil,
                    title: nil,
                    compound: nil,
                    speed: nil,
                    reverse: nil,
                    freezeFrame: nil,
                    timeRemap: nil,
                    frameSampling: nil,
                    transform: nil,
                    transformAnimation: nil,
                    effects: nil,
                    effectsAnimation: nil,
                    effectStack: nil,
                    effectStackAnimation: nil,
                    trackOpacity: nil,
                    trackBlendMode: nil,
                    timelineStartFrame: nil,
                    sourceFrameCount: nil,
                    leadingTransition: nil,
                    trailingTransition: nil
                )
            ]
        }
        throw AjarCLIError.invalidGoldenManifest("\(id) has no synthetic media")
    }
}

struct GoldenFrameClipSpec: Codable, Equatable, Sendable {
    /// Synthetic movie for media-backed clips. Optional when `title` is present (ADR-0017).
    let syntheticMedia: SyntheticMovieSpec?
    /// FR-MED-007 fixture hook: retain metadata/URL but omit the file and render the slate.
    let offline: Bool?
    /// Title generator payload (FR-TXT-001). When set, the clip source is `.title`.
    let title: TitleSource?
    let compound: GoldenFrameCompoundSpec?
    let speed: RationalValue?
    let reverse: Bool?
    let freezeFrame: Bool?
    let timeRemap: [GoldenTimeRemapKeyframeSpec]?
    let frameSampling: ClipFrameSamplingMode?
    let transform: ClipTransform?
    let transformAnimation: AnimatableClipTransform?
    let effects: ClipEffects?
    let effectsAnimation: AnimatableClipEffects?
    /// FR-FX library stack (FR-FX-002/003, FR-COL-004 LUT); absent means empty.
    let effectStack: ClipEffectStack?
    /// Keyframable FR-FX stack; absent means constant of `effectStack` / empty.
    let effectStackAnimation: AnimatableClipEffectStack?
    let trackOpacity: Animatable<RationalValue>?
    let trackBlendMode: ClipBlendMode?
    /// Timeline start in frames (same rate as synthetic media). When any clip in the
    /// manifest carries a video transition, all clips share one track and this field
    /// places them on the timeline (FR-FX-001).
    let timelineStartFrame: Int64?
    /// Source range duration in frames. Defaults to `syntheticMedia.frameCount`. Set lower
    /// than the media frame count to leave a fade-tail handle for FR-FX-001 transitions.
    let sourceFrameCount: Int64?
    /// FR-FX-001 leading video transition (mirror).
    let leadingTransition: ClipVideoTransition?
    /// FR-FX-001 trailing video transition (render owner).
    let trailingTransition: ClipVideoTransition?

    var isTitleClip: Bool {
        title != nil
    }

    var hasVideoTransition: Bool {
        leadingTransition != nil || trailingTransition != nil
    }

    func validateSourcePayload(manifestID: String) throws {
        if title != nil {
            if let error = title?.validate() {
                throw AjarCLIError.invalidGoldenManifest(
                    "\(manifestID) title invalid: \(error)"
                )
            }
            return
        }
        if syntheticMedia == nil {
            throw AjarCLIError.invalidGoldenManifest(
                "\(manifestID) clip needs syntheticMedia or title"
            )
        }
    }
}

struct GoldenFrameCompoundSpec: Codable, Equatable, Sendable {
    let innerTransform: ClipTransform?
    let innerEffects: ClipEffects?
}
