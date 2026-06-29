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
    let ducking: [GoldenAudioDuckingSpec]
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
        case ducking
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
        ducking = try container.decodeIfPresent([GoldenAudioDuckingSpec].self, forKey: .ducking)
            ?? []
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

    func audioDuckingRules(trackIDs: [UUID]) throws -> [AudioDuckingRule] {
        try ducking.map { try $0.rule(trackIDs: trackIDs) }
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

struct GoldenAudioDuckingSpec: Decodable, Equatable {
    let triggerTrackIndex: Int
    let targetTrackIndexes: [Int]
    let threshold: Double
    let reductionGain: Double
    let attack: String
    let release: String
    let hold: String

    private enum CodingKeys: String, CodingKey {
        case triggerTrackIndex
        case targetTrackIndexes
        case threshold
        case reductionGain
        case attack
        case release
        case hold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        triggerTrackIndex = try container.decode(Int.self, forKey: .triggerTrackIndex)
        targetTrackIndexes = try container.decode([Int].self, forKey: .targetTrackIndexes)
        threshold = try container.decode(Double.self, forKey: .threshold)
        reductionGain = try container.decode(Double.self, forKey: .reductionGain)
        attack = try container.decodeIfPresent(String.self, forKey: .attack) ?? "0"
        release = try container.decodeIfPresent(String.self, forKey: .release) ?? "0"
        hold = try container.decodeIfPresent(String.self, forKey: .hold) ?? "0"
    }

    func rule(trackIDs: [UUID]) throws -> AudioDuckingRule {
        guard triggerTrackIndex >= 0, triggerTrackIndex < trackIDs.count else {
            throw AjarCLIError.invalidGoldenManifest("ducking triggerTrackIndex is out of range")
        }
        let targetIDs = try targetTrackIndexes.map { targetIndex in
            guard targetIndex >= 0, targetIndex < trackIDs.count else {
                throw AjarCLIError.invalidGoldenManifest(
                    "ducking targetTrackIndexes contains an out-of-range index"
                )
            }
            return trackIDs[targetIndex]
        }
        return AudioDuckingRule(
            triggerTrackID: trackIDs[triggerTrackIndex],
            targetTrackIDs: targetIDs,
            threshold: RationalValue.approximating(threshold),
            reductionGain: RationalValue.approximating(reductionGain),
            attack: try GoldenAudioManifest.rationalTime(attack),
            release: try GoldenAudioManifest.rationalTime(release),
            hold: try GoldenAudioManifest.rationalTime(hold)
        )
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
    let sourceIndex: Int?
    let compound: GoldenAudioCompoundSpec?
    let timelineStart: String
    let sourceStart: String
    let duration: String
    let speed: RationalValue?
    let gain: Double
    let pan: Double
    let fadeIn: String?
    let fadeOut: String?

    private enum CodingKeys: String, CodingKey {
        case sourceIndex
        case compound
        case timelineStart
        case sourceStart
        case duration
        case speed
        case gain
        case pan
        case fadeIn
        case fadeOut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceIndex = try container.decodeIfPresent(Int.self, forKey: .sourceIndex)
        compound = try container.decodeIfPresent(GoldenAudioCompoundSpec.self, forKey: .compound)
        timelineStart = try container.decodeIfPresent(String.self, forKey: .timelineStart) ?? "0"
        sourceStart = try container.decodeIfPresent(String.self, forKey: .sourceStart) ?? "0"
        duration = try container.decode(String.self, forKey: .duration)
        speed = try container.decodeIfPresent(RationalValue.self, forKey: .speed)
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        fadeIn = try container.decodeIfPresent(String.self, forKey: .fadeIn)
        fadeOut = try container.decodeIfPresent(String.self, forKey: .fadeOut)
    }

    func clip(id: UUID, source: ClipSource) throws -> Clip {
        let clipDuration = try GoldenAudioManifest.rationalTime(duration)
        let clipSpeed = speed ?? .one
        return Clip(
            id: id,
            source: source,
            sourceRange: try TimeRange(
                start: GoldenAudioManifest.rationalTime(sourceStart),
                duration: clipDuration
            ),
            timelineRange: try TimeRange(
                start: GoldenAudioManifest.rationalTime(timelineStart),
                duration: Clip.timelineDuration(forSourceDuration: clipDuration, speed: clipSpeed)
            ),
            kind: .audio,
            name: "Golden Audio Clip",
            audioMix: try audioMix(),
            speed: clipSpeed
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

struct GoldenAudioCompoundSpec: Decodable, Equatable {
    let clips: [GoldenAudioClipSpec]
    let tracks: [GoldenAudioTrackSpec]

    private enum CodingKeys: String, CodingKey {
        case clips
        case tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clips = try container.decodeIfPresent([GoldenAudioClipSpec].self, forKey: .clips) ?? []
        tracks = try container.decodeIfPresent([GoldenAudioTrackSpec].self, forKey: .tracks) ?? []
    }

    func trackSpecs() throws -> [GoldenAudioTrackSpec] {
        if !tracks.isEmpty {
            return tracks
        }
        guard !clips.isEmpty else {
            throw AjarCLIError.invalidGoldenManifest("compound audio manifest has no clips")
        }
        return [GoldenAudioTrackSpec(clips: clips)]
    }
}
