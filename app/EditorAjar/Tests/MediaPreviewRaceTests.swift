// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import EditorAjar

@MainActor
extension MediaPreviewIdentityTests {
    func testRelinkDuringIdentityLookupCannotStartObsoleteExtraction() async throws {
        let root = try temporaryDirectory(named: "identity-lookup-relink-race")
        let originalHash = ContentHash.sha256(data: Data("lookup-original".utf8))
        let oldURL = root.appendingPathComponent("lookup-old.mov")
        let replacementURL = root.appendingPathComponent("lookup-new.mov")
        let oldData = Data("lookup-old".utf8)
        let replacementData = Data("lookup-new".utf8)
        try writePlayableSource(oldData, to: oldURL)
        try writePlayableSource(replacementData, to: replacementURL)
        let old = try transcodedMedia(
            sourceURL: oldURL,
            originalHash: originalHash,
            playableHash: ContentHash.sha256(data: oldData)
        )
        let replacement = try transcodedMedia(
            id: old.id,
            sourceURL: replacementURL,
            originalHash: originalHash,
            playableHash: ContentHash.sha256(data: replacementData)
        )
        let identityProbe = ControlledContentIdentityProbe(blockedCalls: [1])
        let extractionProbe = PreviewExtractionProbe()
        let cache = MediaPreviewCache(
            packageURL: root,
            contentIdentityResolver: { media in
                try await identityProbe.resolve(media: media)
            },
            extractor: { _, _ in
                await extractionProbe.recordCall()
                return Self.minimalPNGData
            }
        )
        let model = try model(with: old, cache: cache, root: root)

        let oldRequest = Task { await model.requestMediaPreview(for: old) }
        try await waitUntil { await identityProbe.hasStarted(call: 1) }
        XCTAssertTrue(
            model.applyEditForTesting(
                .updateMediaReferences(kind: .relink, replacements: [replacement])
            )
        )
        await identityProbe.release(call: 1)
        await oldRequest.value

        let obsoleteExtractionCount = await extractionProbe.callCount
        XCTAssertEqual(obsoleteExtractionCount, 0)
        XCTAssertNil(model.mediaThumbnailData[old.id])
        await model.requestMediaPreview(for: replacement)
        let replacementExtractionCount = await extractionProbe.callCount
        XCTAssertEqual(replacementExtractionCount, 1)
        XCTAssertEqual(model.mediaThumbnailData[old.id], Self.minimalPNGData)
    }

    func testProjectSessionSwapDuringIdentityLookupRejectsOldRequest() async throws {
        let root = try temporaryDirectory(named: "identity-lookup-session-race")
        let sourceURL = root.appendingPathComponent("same-media.mov")
        let sourceData = Data("same-media".utf8)
        try writePlayableSource(sourceData, to: sourceURL)
        let media = try ordinaryMedia(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: sourceData)
        )
        let identityProbe = ControlledContentIdentityProbe(blockedCalls: [1])
        let extractionProbe = PreviewExtractionProbe()
        let cache = MediaPreviewCache(
            packageURL: root,
            contentIdentityResolver: { media in
                try await identityProbe.resolve(media: media)
            },
            extractor: { _, _ in
                await extractionProbe.recordCall()
                return Self.minimalPNGData
            }
        )
        let model = try model(with: media, cache: cache, root: root)

        let oldRequest = Task { await model.requestMediaPreview(for: media) }
        try await waitUntil { await identityProbe.hasStarted(call: 1) }
        model.authorizeDiscardForNextDocumentReplacement()
        try model.createNewProject(settings: .sensibleDefaults)
        XCTAssertTrue(model.applyEditForTesting(.addMediaReferences([media])))
        model.setMediaPreviewCacheForTesting(cache)
        await cache.cancelAll()
        await identityProbe.release(call: 1)
        await oldRequest.value

        let obsoleteExtractionCount = await extractionProbe.callCount
        XCTAssertEqual(obsoleteExtractionCount, 0)
        XCTAssertNil(model.mediaThumbnailData[media.id])
        await model.requestMediaPreview(for: media)
        let replacementExtractionCount = await extractionProbe.callCount
        XCTAssertEqual(replacementExtractionCount, 1)
        XCTAssertEqual(model.mediaThumbnailData[media.id], Self.minimalPNGData)
    }

    func testSaveAsResetsCacheRootAndRejectsPreSaveRequest() async throws {
        let root = try temporaryDirectory(named: "identity-lookup-save-as-race")
        let sourceURL = root.appendingPathComponent("external.mov")
        let sourceData = Data("save-as-source".utf8)
        try sourceData.write(to: sourceURL)
        let media = try ordinaryMedia(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: sourceData)
        )
        let identityProbe = ControlledContentIdentityProbe(blockedCalls: [1])
        let obsoleteExtractionProbe = PreviewExtractionProbe()
        let oldCache = MediaPreviewCache(
            packageURL: root,
            contentIdentityResolver: { media in
                try await identityProbe.resolve(media: media)
            },
            extractor: { _, _ in
                await obsoleteExtractionProbe.recordCall()
                return Self.minimalPNGData
            }
        )
        let model = try model(with: media, cache: oldCache, root: root)

        let oldRequest = Task { await model.requestMediaPreview(for: media) }
        try await waitUntil { await identityProbe.hasStarted(call: 1) }
        let destinationURL = root.appendingPathComponent("Saved.ajar", isDirectory: true)
        let previousPreviewGeneration = model.mediaPreviewGeneration
        try model.saveProjectAs(to: destinationURL)
        XCTAssertFalse(model.hasMediaPreviewCacheForTesting)
        XCTAssertNotEqual(model.mediaPreviewGeneration, previousPreviewGeneration)
        XCTAssertEqual(
            model.mediaPreviewPackageRootURL?.standardizedFileURL,
            destinationURL.standardizedFileURL
        )

        let replacementExtractionProbe = PreviewExtractionProbe()
        let newCache = MediaPreviewCache(packageURL: destinationURL) { _, _ in
            await replacementExtractionProbe.recordCall()
            return Self.minimalPNGData
        }
        model.setMediaPreviewCacheForTesting(newCache)
        await identityProbe.release(call: 1)
        await oldRequest.value

        let obsoleteCount = await obsoleteExtractionProbe.callCount
        XCTAssertEqual(obsoleteCount, 0)
        let savedMedia = try XCTUnwrap(
            model.project?.mediaPool.first(where: { $0.id == media.id })
        )
        await model.requestMediaPreview(for: savedMedia)
        let replacementCount = await replacementExtractionProbe.callCount
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(model.mediaThumbnailData[media.id], Self.minimalPNGData)
    }

    func testRelinkRejectsStaleInFlightThumbnailPublication() async throws {
        let root = try temporaryDirectory(named: "thumbnail-relink-race")
        let originalHash = ContentHash.sha256(data: Data("thumbnail-original".utf8))
        let oldURL = root.appendingPathComponent("thumbnail-old.mov")
        let replacementURL = root.appendingPathComponent("thumbnail-new.mov")
        let oldData = Data("thumbnail-old".utf8)
        let replacementData = Data("thumbnail-new".utf8)
        try writePlayableSource(oldData, to: oldURL)
        try writePlayableSource(replacementData, to: replacementURL)
        let old = try transcodedMedia(
            sourceURL: oldURL,
            originalHash: originalHash,
            playableHash: ContentHash.sha256(data: oldData)
        )
        let replacement = try transcodedMedia(
            id: old.id,
            sourceURL: replacementURL,
            originalHash: originalHash,
            playableHash: ContentHash.sha256(data: replacementData)
        )
        let probe = ControlledPreviewProbe(blockedCalls: [1])
        let cache = MediaPreviewCache(packageURL: root, workerLimit: 2) { media, kind in
            try await probe.extract(media: media, kind: kind)
        }
        let model = try model(with: old, cache: cache, root: root)

        let oldRequest = Task { await model.requestMediaPreview(for: old) }
        try await waitUntil { await probe.hasStarted(call: 1) }
        XCTAssertTrue(
            model.applyEditForTesting(
                .updateMediaReferences(kind: .relink, replacements: [replacement])
            )
        )
        let replacementRequest = Task { await model.requestMediaPreview(for: replacement) }
        try await waitUntil {
            model.mediaThumbnailData[old.id] == Data("thumbnail-2".utf8)
        }

        await probe.release(call: 1)
        await oldRequest.value
        await replacementRequest.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.mediaThumbnailData[old.id], Data("thumbnail-2".utf8))
    }

    func testRelinkClearsTimelineWaveformBeforeSchedulingReplacement() async throws {
        let root = try temporaryDirectory(named: "waveform-relink-refresh")
        let originalHash = ContentHash.sha256(data: Data("waveform-original".utf8))
        let oldURL = root.appendingPathComponent("waveform-old.wav")
        let replacementURL = root.appendingPathComponent("waveform-new.wav")
        let oldData = Data("waveform-old".utf8)
        let replacementData = Data("waveform-new".utf8)
        try writePlayableSource(oldData, to: oldURL)
        try writePlayableSource(replacementData, to: replacementURL)
        let old = try transcodedMedia(
            sourceURL: oldURL,
            originalHash: originalHash,
            playableHash: ContentHash.sha256(data: oldData),
            isVideo: false
        )
        let replacement = try transcodedMedia(
            id: old.id,
            sourceURL: replacementURL,
            originalHash: originalHash,
            playableHash: ContentHash.sha256(data: replacementData),
            isVideo: false
        )
        let warmCache = MediaPreviewCache(packageURL: root) { _, _ in
            try waveformData(marker: 99)
        }
        let model = try model(with: old, cache: warmCache, root: root)

        await model.requestMediaPreview(for: old)
        XCTAssertEqual(model.mediaWaveformSummary[old.id]?.sampleRate, 48_099)
        XCTAssertTrue(model.insertMediaOnTimeline(mediaID: old.id))
        let probe = ControlledPreviewProbe(blockedCalls: [1])
        let raceCache = MediaPreviewCache(
            packageURL: root.appendingPathComponent("race-cache", isDirectory: true),
            workerLimit: 2
        ) { media, kind in
            try await probe.extract(media: media, kind: kind)
        }
        model.setMediaPreviewCacheForTesting(raceCache)
        let oldRequest = Task { await model.requestMediaPreview(for: old) }
        try await waitUntil { await probe.hasStarted(call: 1) }
        XCTAssertTrue(
            model.applyEditForTesting(
                .updateMediaReferences(kind: .relink, replacements: [replacement])
            )
        )

        XCTAssertNil(
            model.mediaWaveformSummary[old.id],
            "old waveform must be cleared synchronously before replacement extraction"
        )
        try await waitUntil { await probe.hasStarted(call: 2) }
        try await waitUntil {
            model.mediaWaveformSummary[old.id]?.sampleRate == 48_002
        }
        await probe.release(call: 1)
        await oldRequest.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.mediaWaveformSummary[old.id]?.sampleRate, 48_002)
    }

    func testDelayedOldCleanupCannotDeleteRestartedPreviewRecord() async throws {
        let root = try temporaryDirectory(named: "preview-generation-race")
        let sourceURL = root.appendingPathComponent("restart.wav")
        let sourceData = Data("restart".utf8)
        try writePlayableSource(sourceData, to: sourceURL)
        let media = try ordinaryMedia(
            sourceURL: sourceURL,
            contentHash: ContentHash.sha256(data: sourceData),
            isVideo: false
        )
        let probe = ControlledPreviewProbe(blockedCalls: [1, 2])
        let cache = MediaPreviewCache(packageURL: root, workerLimit: 1) { media, kind in
            try await probe.extract(media: media, kind: kind)
        }
        let model = try model(with: media, cache: cache, root: root)

        let first = Task { await model.requestMediaPreview(for: media) }
        try await waitUntil { await probe.hasStarted(call: 1) }
        let oldGeneration = try XCTUnwrap(
            model.mediaPreviewTaskGenerationForTesting(media.id)
        )
        let contentIdentity = try await cache.contentIdentity(for: media)
        model.cancelMediaPreview(for: media.id)
        await cache.cancel(for: contentIdentity, kind: .waveform)
        let restarted = Task { await model.requestMediaPreview(for: media) }
        try await waitUntil {
            guard let current = model.mediaPreviewTaskGenerationForTesting(media.id) else {
                return false
            }
            return current != oldGeneration
        }

        model.finishMediaPreviewTaskForTesting(
            mediaID: media.id,
            generation: oldGeneration
        )
        XCTAssertEqual(model.mediaPreviewTaskCountForTesting, 1)

        await probe.release(call: 1)
        try await waitUntil { await probe.hasStarted(call: 2) }
        await probe.release(call: 2)
        await first.value
        await restarted.value
        try await waitUntil { model.mediaPreviewTaskCountForTesting == 0 }
        XCTAssertNotNil(model.mediaWaveformSummary[media.id])
    }

    func testRelinkRejectsStaleInFlightHoverPublication() async throws {
        let root = try temporaryDirectory(named: "hover-relink-race")
        let originalHash = ContentHash.sha256(data: Data("hover-original".utf8))
        let oldURL = root.appendingPathComponent("hover-old.mov")
        let replacementURL = root.appendingPathComponent("hover-new.mov")
        let oldData = Data("hover-old".utf8)
        let replacementData = Data("hover-new".utf8)
        try writePlayableSource(oldData, to: oldURL)
        try writePlayableSource(replacementData, to: replacementURL)
        let old = try transcodedMedia(
            sourceURL: oldURL,
            originalHash: originalHash,
            playableHash: ContentHash.sha256(data: oldData)
        )
        let replacement = try transcodedMedia(
            id: old.id,
            sourceURL: replacementURL,
            originalHash: originalHash,
            playableHash: ContentHash.sha256(data: replacementData)
        )
        let hoverProbe = ControlledHoverProbe(blockedCalls: [1])
        let cache = MediaPreviewCache(
            packageURL: root,
            workerLimit: 2,
            hoverExtractor: { media, time in
                await hoverProbe.frame(media: media, time: time)
            },
            extractor: { _, _ in Self.minimalPNGData }
        )
        let model = try model(with: old, cache: cache, root: root)

        model.requestMediaHoverPreview(mediaID: old.id, fraction: 0.25)
        try await waitUntil { await hoverProbe.hasStarted(call: 1) }
        XCTAssertTrue(
            model.applyEditForTesting(
                .updateMediaReferences(kind: .relink, replacements: [replacement])
            )
        )
        model.requestMediaHoverPreview(mediaID: replacement.id, fraction: 0.75)
        try await waitUntil {
            model.mediaHoverPreviewData[old.id] == Data("hover-2".utf8)
        }

        await hoverProbe.release(call: 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.mediaHoverPreviewData[old.id], Data("hover-2".utf8))
    }
}
