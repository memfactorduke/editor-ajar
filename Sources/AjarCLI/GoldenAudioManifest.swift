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
    let referenceSamples: [Float]

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
