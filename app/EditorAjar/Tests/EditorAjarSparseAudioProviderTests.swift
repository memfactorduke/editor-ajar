// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
final class EditorAjarSparseAudioProviderTests: XCTestCase {
    private static let sampleRate = 48_000

    func testSameMediaWindowsHoursApartStayUnderBudgetAndMixExactly() throws {
        let fixture = try makeFixture()
        let provider = try EditorAjarProjectAudioSourceProvider(
            project: fixture.project,
            sequence: fixture.sequence,
            range: fixture.renderRange
        )
        let firstSource = try provider.audioSource(
            for: fixture.mediaID,
            covering: fixture.firstRange
        )
        let distantSource = try provider.audioSource(
            for: fixture.mediaID,
            covering: fixture.distantRange
        )

        let retainedBytes =
            (firstSource.samples.count + distantSource.samples.count)
            * MemoryLayout<Float>.size
        XCTAssertLessThan(
            retainedBytes,
            EditorAjarProjectAudioSourceProvider.maximumPreparedSourceBytes
        )
        XCTAssertGreaterThan(
            distantSource.frameOffset,
            firstSource.frameOffset + firstSource.frameCount
        )

        let rendered = try OfflineAudioMixer.render(
            project: fixture.project,
            sequence: fixture.sequence,
            range: fixture.renderRange,
            sourceProvider: provider
        )
        assertExactSamples(rendered)
    }

    private func makeFixture() throws -> SparseAudioFixture {
        let frameRate = try FrameRate(frames: 30)
        let mediaID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-00000000A071")
        )
        let oneSecond = try RationalTime(value: 1, timescale: 1)
        let firstRange = try TimeRange(start: .zero, duration: oneSecond)
        let distantRange = try TimeRange(
            start: RationalTime(value: 3_600, timescale: 1),
            duration: oneSecond
        )
        let media = try makeMedia(mediaID: mediaID)
        let sequence = try makeSequence(
            mediaID: mediaID,
            frameRate: frameRate,
            firstRange: firstRange,
            distantRange: distantRange
        )
        let project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 16, height: 16),
                colorSpace: .rec709,
                audioSampleRate: Self.sampleRate
            ),
            mediaPool: [media],
            sequences: [sequence]
        )
        return SparseAudioFixture(
            project: project,
            sequence: sequence,
            mediaID: mediaID,
            firstRange: firstRange,
            distantRange: distantRange,
            renderRange: try TimeRange(
                start: .zero,
                duration: RationalTime(value: 2, timescale: 1)
            )
        )
    }

    private func makeMedia(mediaID: UUID) throws -> MediaRef {
        MediaRef(
            id: mediaID,
            sourceURL: URL(fileURLWithPath: "/tmp/editor-ajar-sparse.synthetic-audio"),
            contentHash: ContentHash.sha256(data: Data("sparse-audio".utf8)),
            metadata: MediaMetadata(
                codecID: EditorAjarSampleProjectFactory.sampleToneCodecID,
                pixelDimensions: nil,
                frameRate: nil,
                duration: try RationalTime(value: 3_601, timescale: 1),
                colorSpace: .unspecified,
                audioChannelLayout: AudioChannelLayout(
                    channelCount: 2,
                    layoutTag: "stereo"
                ),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    private func makeSequence(
        mediaID: UUID,
        frameRate: FrameRate,
        firstRange: TimeRange,
        distantRange: TimeRange
    ) throws -> Sequence {
        let oneSecond = try RationalTime(value: 1, timescale: 1)
        let distantTimelineRange = try TimeRange(start: oneSecond, duration: oneSecond)
        return Sequence(
            id: UUID(),
            name: "Sparse same-media audio",
            videoTracks: [],
            audioTracks: [
                Track(
                    id: UUID(),
                    kind: .audio,
                    items: [
                        .clip(
                            sparseClip(
                                mediaID: mediaID,
                                sourceRange: firstRange,
                                timelineRange: firstRange,
                                name: "Start"
                            )
                        ),
                        .clip(
                            sparseClip(
                                mediaID: mediaID,
                                sourceRange: distantRange,
                                timelineRange: distantTimelineRange,
                                name: "One hour later"
                            )
                        )
                    ]
                )
            ],
            markers: [],
            timebase: frameRate
        )
    }

    private func sparseClip(
        mediaID: UUID,
        sourceRange: TimeRange,
        timelineRange: TimeRange,
        name: String
    ) -> Clip {
        Clip(
            id: UUID(),
            source: .media(id: mediaID),
            sourceRange: sourceRange,
            timelineRange: timelineRange,
            kind: .audio,
            name: name
        )
    }

    private func assertExactSamples(_ rendered: RenderedAudioBuffer) {
        let localFrame = 123
        let firstExpected = sampleTone(at: localFrame)
        let distantExpected = sampleTone(at: (3_600 * Self.sampleRate) + localFrame)
        XCTAssertEqual(rendered.samples[localFrame * 2], firstExpected, accuracy: 0.000_001)
        XCTAssertEqual(
            rendered.samples[((Self.sampleRate + localFrame) * 2)],
            distantExpected,
            accuracy: 0.000_001
        )
    }

    private func sampleTone(at absoluteFrame: Int) -> Float {
        Float(
            sin(
                2 * Double.pi * 440 * Double(absoluteFrame) / Double(Self.sampleRate)
            ) * 0.12
        )
    }
}

private struct SparseAudioFixture {
    let project: Project
    let sequence: Sequence
    let mediaID: UUID
    let firstRange: TimeRange
    let distantRange: TimeRange
    let renderRange: TimeRange
}
