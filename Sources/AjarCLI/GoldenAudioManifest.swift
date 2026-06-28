// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation

struct GoldenAudioManifest: Decodable, Equatable {
    let id: String
    let sampleRate: Int
    let channelCount: Int
    let duration: String
    let tolerance: Float
    let sources: [GoldenAudioSourceSpec]
    let clips: [GoldenAudioClipSpec]
    let tracks: [GoldenAudioTrackSpec]
    let referenceSamples: [Float]

    private enum CodingKeys: String, CodingKey {
        case id
        case sampleRate
        case channelCount
        case duration
        case tolerance
        case sources
        case clips
        case tracks
        case referenceSamples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        duration = try container.decode(String.self, forKey: .duration)
        tolerance = try container.decode(Float.self, forKey: .tolerance)
        sources = try container.decode([GoldenAudioSourceSpec].self, forKey: .sources)
        clips = try container.decodeIfPresent([GoldenAudioClipSpec].self, forKey: .clips) ?? []
        tracks = try container.decodeIfPresent([GoldenAudioTrackSpec].self, forKey: .tracks) ?? []
        referenceSamples = try container.decode([Float].self, forKey: .referenceSamples)
    }

    static func load(from url: URL) throws -> GoldenAudioManifest {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(GoldenAudioManifest.self, from: data)
        } catch let error as AjarCLIError {
            throw error
        } catch {
            throw AjarCLIError.invalidGoldenManifest(
                "\(url.path): \(String(describing: error))"
            )
        }
    }

    func renderDuration() throws -> RationalTime {
        try Self.rationalTime(duration)
    }

    func trackSpecs() throws -> [GoldenAudioTrackSpec] {
        if !tracks.isEmpty {
            return tracks
        }
        guard !clips.isEmpty else {
            throw AjarCLIError.invalidGoldenManifest("golden-audio manifest has no clips")
        }
        return [GoldenAudioTrackSpec(clips: clips)]
    }

    static func rationalTime(_ rawValue: String) throws -> RationalTime {
        if rawValue.contains("/") {
            let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let value = Int64(parts[0]),
                  let timescale = Int64(parts[1])
            else {
                throw AjarCLIError.invalidGoldenManifest("invalid audio time '\(rawValue)'")
            }
            return try RationalTime(value: value, timescale: timescale)
        }

        guard let seconds = Int64(rawValue) else {
            throw AjarCLIError.invalidGoldenManifest("invalid audio time '\(rawValue)'")
        }
        return try RationalTime(value: seconds, timescale: 1)
    }
}

struct GoldenAudioTrackSpec: Decodable, Equatable {
    let enabled: Bool
    let muted: Bool
    let solo: Bool
    let gain: Double
    let pan: Double
    let clips: [GoldenAudioClipSpec]

    private enum CodingKeys: String, CodingKey {
        case enabled
        case muted
        case solo
        case gain
        case pan
        case clips
    }

    init(clips: [GoldenAudioClipSpec]) {
        enabled = true
        muted = false
        solo = false
        gain = 1
        pan = 0
        self.clips = clips
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try container.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        clips = try container.decode([GoldenAudioClipSpec].self, forKey: .clips)
    }

    func track(id: UUID, items: [TimelineItem]) -> Track {
        Track(
            id: id,
            kind: .audio,
            items: items,
            enabled: enabled,
            muted: muted,
            solo: solo,
            audioGain: .constant(RationalValue.approximating(gain)),
            audioPan: .constant(RationalValue.approximating(pan))
        )
    }
}

struct GoldenAudioSourceSpec: Decodable, Equatable {
    let sampleRate: Int
    let channelCount: Int
    let samples: [Float]

    func buffer() throws -> AudioSourceBuffer {
        guard channelCount > 0, samples.count % channelCount == 0 else {
            throw AjarCLIError.invalidGoldenManifest("source samples do not match channels")
        }
        return try AudioSourceBuffer(
            format: AudioRenderFormat(sampleRate: sampleRate, channelCount: channelCount),
            frameCount: samples.count / channelCount,
            samples: samples
        )
    }
}

struct GoldenAudioClipSpec: Decodable, Equatable {
    let sourceIndex: Int
    let timelineStart: String
    let sourceStart: String
    let duration: String
    let gain: Double
    let pan: Double
    let fadeIn: String?
    let fadeOut: String?

    private enum CodingKeys: String, CodingKey {
        case sourceIndex
        case timelineStart
        case sourceStart
        case duration
        case gain
        case pan
        case fadeIn
        case fadeOut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceIndex = try container.decode(Int.self, forKey: .sourceIndex)
        timelineStart = try container.decodeIfPresent(String.self, forKey: .timelineStart) ?? "0"
        sourceStart = try container.decodeIfPresent(String.self, forKey: .sourceStart) ?? "0"
        duration = try container.decode(String.self, forKey: .duration)
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        fadeIn = try container.decodeIfPresent(String.self, forKey: .fadeIn)
        fadeOut = try container.decodeIfPresent(String.self, forKey: .fadeOut)
    }

    func clip(id: UUID, mediaID: UUID) throws -> Clip {
        let clipDuration = try GoldenAudioManifest.rationalTime(duration)
        return Clip(
            id: id,
            source: .media(id: mediaID),
            sourceRange: try TimeRange(
                start: GoldenAudioManifest.rationalTime(sourceStart),
                duration: clipDuration
            ),
            timelineRange: try TimeRange(
                start: GoldenAudioManifest.rationalTime(timelineStart),
                duration: clipDuration
            ),
            kind: .audio,
            name: "Golden Audio Clip",
            audioMix: try audioMix()
        )
    }

    private func audioMix() throws -> ClipAudioMix {
        ClipAudioMix(
            gain: .constant(RationalValue.approximating(gain)),
            pan: .constant(RationalValue.approximating(pan)),
            fadeIn: try fade(edgeDuration: fadeIn),
            fadeOut: try fade(edgeDuration: fadeOut)
        )
    }

    private func fade(edgeDuration: String?) throws -> ClipAudioFade {
        guard let edgeDuration else {
            return .none
        }
        return ClipAudioFade(duration: try GoldenAudioManifest.rationalTime(edgeDuration))
    }
}
