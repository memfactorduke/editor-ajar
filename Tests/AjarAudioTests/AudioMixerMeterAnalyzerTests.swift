// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import XCTest

@testable import AjarAudio

final class AudioMixerMeterAnalyzerTests: XCTestCase {
    func testFRAUD003MetersMonoTracksAndSummedMixPeakRMS() throws {
        let toneID = try uuid("00000000-0000-0000-0000-000000105001")
        let quietID = try uuid("00000000-0000-0000-0000-000000105002")
        let toneTrackID = try uuid("00000000-0000-0000-0000-000000105003")
        let quietTrackID = try uuid("00000000-0000-0000-0000-000000105004")
        let sequence = try makeSequence(tracks: [
            makeTrack(
                id: toneTrackID,
                items: [.clip(try makeClip(mediaID: toneID, duration: time(1, 1)))]
            ),
            makeTrack(
                id: quietTrackID,
                items: [.clip(try makeClip(mediaID: quietID, duration: time(1, 1)))]
            )
        ])

        let report = try AudioMixerMeterAnalyzer.measure(
            sequence: sequence,
            range: TimeRange(start: .zero, duration: time(1, 1)),
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
            sourceProvider: InMemoryAudioSourceProvider(sources: [
                toneID: try audioSource(samples: [0, 1, 0, -1]),
                quietID: try audioSource(samples: [0.5, 0.5, 0.5, 0.5])
            ])
        )

        XCTAssertEqual(report.sampleRate, 4)
        XCTAssertEqual(report.channelCount, 2)
        XCTAssertEqual(report.frameCount, 4)
        XCTAssertEqual(report.trackLevels.map(\.trackID), [toneTrackID, quietTrackID])
        assertLevels(report.trackLevels[0].levels, peak: 1, rms: 0.5.squareRoot())
        assertLevels(report.trackLevels[1].levels, peak: 0.5, rms: 0.5)
        assertLevels(report.mixLevels, peak: 1.5, rms: 0.75.squareRoot())
        let fullScalePeak = try XCTUnwrap(report.trackLevels[0].levels[0].peakDBFS)
        XCTAssertEqual(fullScalePeak, 0, accuracy: 0.00001)
    }

    func testFRAUD003MetersStereoRenderedBufferPerChannel() throws {
        let buffer = try RenderedAudioBuffer(
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
            frameCount: 4,
            samples: [
                1, 0.25,
                -1, -0.25,
                0, 0.5,
                0, -0.5
            ]
        )

        let levels = AudioMixerMeterAnalyzer.measure(buffer: buffer)

        assertLevel(levels[0], channelIndex: 0, peak: 1, rms: 0.5.squareRoot())
        assertLevel(levels[1], channelIndex: 1, peak: 0.5, rms: 0.15625.squareRoot())
        XCTAssertNil(AudioMeterChannelLevel.dbFS(for: 0))
        XCTAssertNil(AudioMeterChannelLevel.dbFS(for: -1))
    }

    func testFRAUD003MeterReportIsDeterministicAndCodable() throws {
        let report = try deterministicReport()
        let repeated = try deterministicReport()
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(AudioMixerMeterReport.self, from: encoded)

        XCTAssertEqual(report, repeated)
        XCTAssertEqual(decoded, report)
    }

    func testFRAUD003MeteringReportsSilenceAsZero() throws {
        let emptyTrackID = try uuid("00000000-0000-0000-0000-000000105101")
        let sequence = try makeSequence(tracks: [
            makeTrack(id: emptyTrackID, items: [])
        ])

        let report = try AudioMixerMeterAnalyzer.measure(
            sequence: sequence,
            range: TimeRange(start: .zero, duration: time(1, 1)),
            format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
            sourceProvider: InMemoryAudioSourceProvider(sources: [:])
        )

        XCTAssertEqual(report.trackLevels.map(\.trackID), [emptyTrackID])
        assertLevels(report.trackLevels[0].levels, peak: 0, rms: 0)
        assertLevels(report.mixLevels, peak: 0, rms: 0)
    }

    func testFRAUD003MeteringPropagatesTypedRenderErrors() throws {
        let mediaID = try uuid("00000000-0000-0000-0000-000000105201")
        let sequence = try makeSequence(items: [
            .clip(try makeClip(mediaID: mediaID, duration: time(1, 1)))
        ])

        XCTAssertThrowsError(
            try AudioMixerMeterAnalyzer.measure(
                sequence: sequence,
                range: TimeRange(start: .zero, duration: time(1, 1)),
                format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
                sourceProvider: InMemoryAudioSourceProvider(sources: [:])
            )
        ) { error in
            XCTAssertEqual(error as? AudioRenderError, .missingAudioSource(mediaID))
        }

        XCTAssertThrowsError(
            try AudioMixerMeterAnalyzer.measure(
                sequence: sequence,
                range: TimeRange(start: .zero, duration: time(1, 1)),
                format: AudioRenderFormat(sampleRate: 0, channelCount: 2),
                sourceProvider: InMemoryAudioSourceProvider(sources: [:])
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioRenderError,
                .invalidFormat(sampleRate: 0, channelCount: 2, frameCount: 0)
            )
        }
    }
}

private func deterministicReport() throws -> AudioMixerMeterReport {
    let mediaID = try uuid("00000000-0000-0000-0000-000000105301")
    let trackID = try uuid("00000000-0000-0000-0000-000000105302")
    let sequence = try makeSequence(tracks: [
        makeTrack(
            id: trackID,
            items: [.clip(try makeClip(mediaID: mediaID, duration: time(1, 1)))]
        )
    ])

    return try AudioMixerMeterAnalyzer.measure(
        sequence: sequence,
        range: TimeRange(start: .zero, duration: time(1, 1)),
        format: AudioRenderFormat(sampleRate: 4, channelCount: 2),
        sourceProvider: InMemoryAudioSourceProvider(sources: [
            mediaID: try audioSource(samples: [1, -1, 1, -1])
        ])
    )
}

private func assertLevels(
    _ levels: [AudioMeterChannelLevel],
    peak: Double,
    rms: Double,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(levels.map(\.channelIndex), [0, 1], file: file, line: line)
    for level in levels {
        assertLevel(level, channelIndex: level.channelIndex, peak: peak, rms: rms)
    }
}

private func assertLevel(
    _ level: AudioMeterChannelLevel,
    channelIndex: Int,
    peak: Double,
    rms: Double,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(level.channelIndex, channelIndex, file: file, line: line)
    XCTAssertEqual(level.peak, peak, accuracy: 0.00001, file: file, line: line)
    XCTAssertEqual(level.rms, rms, accuracy: 0.00001, file: file, line: line)
}
