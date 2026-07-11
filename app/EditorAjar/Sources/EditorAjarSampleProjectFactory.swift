// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AjarCore
import CoreVideo
import Foundation

enum EditorAjarSampleProjectFactory {
    static let sampleToneCodecID = "editor-ajar-sample-tone"

    private static let sampleWidth = 320
    private static let sampleHeight = 180
    private static let sampleFrameCount: Int64 = 90
    private static let sampleFramesPerSecond: Int64 = 30

    /// Sample movie bytes are written exactly once per process, then treated as immutable.
    ///
    /// Rewriting on every call deleted the file out from under `AVAssetReader`s belonging to
    /// previously created app models (each render decodes this movie). MediaToolbox blocks
    /// `copyNextSampleBuffer` indefinitely when its file is replaced mid-read, and enough wedged
    /// readers exhaust the Swift cooperative thread pool — deadlocking any later actor hop
    /// (observed as a test-suite hang; NFR-STAB-001). The pixel content is deterministic, so a
    /// single write per process serves every subsequent open identically.
    private static let sampleMovieWriteResult: Result<URL, Error> = {
        do {
            let url = try sampleMovieURL()
            try writeMovie(
                to: url,
                width: sampleWidth,
                height: sampleHeight,
                frameCount: Int(sampleFrameCount),
                frameRate: Int32(sampleFramesPerSecond)
            )
            return .success(url)
        } catch {
            return .failure(error)
        }
    }()

    static func makeSampleProject() throws -> Project {
        let frameRate = try FrameRate(frames: sampleFramesPerSecond)
        let width = sampleWidth
        let height = sampleHeight
        let frameCount = sampleFrameCount
        let mediaURL = try sampleMovieWriteResult.get()
        let audioURL = try sampleToneURL()

        let duration = try frameRate.duration(ofFrames: frameCount)
        // Canvas title occupies the head of V2 so FR-TXT-003 is visible at playhead 0.
        // Tail of V2 stays free so FR-COL-007 grade-target fixtures can abut without overlap.
        let titleFrameCount: Int64 = 60
        let titleDuration = try frameRate.duration(ofFrames: titleFrameCount)
        let mediaID = try uuid("00000000-0000-0000-0000-000000000025")
        let audioMediaID = try uuid("00000000-0000-0000-0000-000000000026")
        let clipID = try uuid("00000000-0000-0000-0000-000000000125")
        let audioClipID = try uuid("00000000-0000-0000-0000-000000000126")
        let linkGroupID = try uuid("00000000-0000-0000-0000-000000000127")
        let titleClipID = try uuid("00000000-0000-0000-0000-000000000128")
        let media = MediaRef(
            id: mediaID,
            sourceURL: mediaURL,
            contentHash: ContentHash.sha256(data: Data("editor-ajar-sample-playback".utf8)),
            metadata: MediaMetadata(
                codecID: "prores4444",
                pixelDimensions: PixelDimensions(width: width, height: height),
                frameRate: frameRate,
                duration: duration,
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let audioMedia = MediaRef(
            id: audioMediaID,
            sourceURL: audioURL,
            contentHash: ContentHash.sha256(data: Data("editor-ajar-sample-tone".utf8)),
            metadata: MediaMetadata(
                codecID: Self.sampleToneCodecID,
                pixelDimensions: nil,
                frameRate: nil,
                duration: duration,
                colorSpace: .unspecified,
                audioChannelLayout: AudioChannelLayout(channelCount: 2, layoutTag: "stereo"),
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
        let clip = Clip(
            id: clipID,
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .video,
            name: "Sample Playback Clip",
            linkGroupID: linkGroupID
        )
        let audioClip = Clip(
            id: audioClipID,
            source: .media(id: audioMediaID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .audio,
            name: "Sample Playback Audio",
            linkGroupID: linkGroupID
        )
        let title = TitleSource(boxes: [
            TitleTextBox(
                id: try uuid("00000000-0000-0000-0000-000000000129"),
                text: "Edit me",
                origin: CanvasPoint(x: RationalValue(70), y: RationalValue(50)),
                width: RationalValue(180),
                height: RationalValue(36),
                style: TitleTextStyle(fontSize: RationalValue(22), fontWeight: .semibold)
            ),
            TitleTextBox(
                id: try uuid("00000000-0000-0000-0000-000000000130"),
                text: "Second box",
                origin: CanvasPoint(x: RationalValue(80), y: RationalValue(105)),
                width: RationalValue(160),
                height: RationalValue(30),
                style: TitleTextStyle(fontSize: RationalValue(16))
            )
        ])
        let titleClip = Clip(
            id: titleClipID,
            source: .title(title),
            sourceRange: try TimeRange(start: .zero, duration: titleDuration),
            timelineRange: try TimeRange(start: .zero, duration: titleDuration),
            kind: .video,
            name: "Sample Canvas Title"
        )
        let sequence = Sequence(
            id: try uuid("00000000-0000-0000-0000-000000000225"),
            name: "Sample Playback Sequence",
            videoTracks: [
                Track(
                    id: try uuid("00000000-0000-0000-0000-000000000325"),
                    kind: .video,
                    items: [.clip(clip)]
                ),
                Track(
                    id: try uuid("00000000-0000-0000-0000-000000000326"),
                    kind: .video,
                    // Title [0, 60). Frames [60, 90) free for grade paste-target clips.
                    items: [.clip(titleClip)],
                    enabled: true,
                    hidden: false
                )
            ],
            audioTracks: [
                Track(
                    id: try uuid("00000000-0000-0000-0000-000000000425"),
                    kind: .audio,
                    items: [.clip(audioClip)]
                ),
                Track(
                    id: try uuid("00000000-0000-0000-0000-000000000426"),
                    kind: .audio,
                    items: [],
                    muted: true
                )
            ],
            markers: [],
            timebase: frameRate
        )

        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: width, height: height),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [media, audioMedia],
            sequences: [sequence]
        )
    }

    private static func sampleMovieURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-sample-media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("single-clip-playback.mov")
    }

    private static func sampleToneURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-ajar-sample-media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sample-tone.synthetic-audio")
    }

    private static func writeMovie(
        to url: URL,
        width: Int,
        height: Int,
        frameCount: Int,
        frameRate: Int32
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var outputSettings: [String: Any] = [:]
        outputSettings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        outputSettings[AVVideoWidthKey] = width
        outputSettings[AVVideoHeightKey] = height

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes(width: width, height: height)
        )

        guard writer.canAdd(input) else {
            throw EditorAjarSampleProjectError.cannotAddVideoInput
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw EditorAjarSampleProjectError.writerFailed(writer.errorDescription)
        }
        writer.startSession(atSourceTime: .zero)
        try appendFrames(
            frameCount: frameCount,
            frameRate: frameRate,
            width: width,
            height: height,
            adaptor: adaptor,
            input: input,
            writer: writer
        )

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            throw EditorAjarSampleProjectError.writerFailed(writer.errorDescription)
        }
    }

    private static func appendFrames(
        frameCount: Int,
        frameRate: Int32,
        width: Int,
        height: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws {
        let writingQueue = DispatchQueue(label: "org.editorajar.sample-movie-writer")
        let inputFinished = DispatchSemaphore(value: 0)
        var writeError: Error?
        var frameIndex = 0

        input.requestMediaDataWhenReady(on: writingQueue) {
            while input.isReadyForMoreMediaData, frameIndex < frameCount {
                do {
                    let pixelBuffer = try makePixelBuffer(
                        width: width,
                        height: height,
                        frameIndex: frameIndex
                    )
                    let presentationTime = CMTime(value: Int64(frameIndex), timescale: frameRate)
                    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                        writeError = EditorAjarSampleProjectError.writerFailed(writer.errorDescription)
                        input.markAsFinished()
                        inputFinished.signal()
                        return
                    }
                    frameIndex += 1
                } catch {
                    writeError = error
                    input.markAsFinished()
                    inputFinished.signal()
                    return
                }
            }

            if frameIndex == frameCount {
                input.markAsFinished()
                inputFinished.signal()
            }
        }

        inputFinished.wait()
        if let writeError {
            writer.cancelWriting()
            throw writeError
        }
    }

    private static func pixelBufferAttributes(width: Int, height: Int) -> [String: Any] {
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        return attributes
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            pixelBufferAttributes(width: width, height: height) as CFDictionary,
            &pixelBuffer
        )

        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw EditorAjarSampleProjectError.pixelBufferCreationFailed(result)
        }

        try fill(pixelBuffer: pixelBuffer, frameIndex: frameIndex)
        return pixelBuffer
    }

    private static func fill(pixelBuffer: CVPixelBuffer, frameIndex: Int) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw EditorAjarSampleProjectError.missingBaseAddress
        }

        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let bytes = baseAddress.bindMemory(to: UInt8.self, capacity: rowBytes * height)

        for yPosition in 0..<height {
            for xPosition in 0..<width {
                let offset = yPosition * rowBytes + xPosition * 4
                bytes[offset] = UInt8((xPosition + frameIndex * 3) % 256)
                bytes[offset + 1] = UInt8((yPosition * 2 + frameIndex * 5) % 256)
                bytes[offset + 2] = UInt8((180 + frameIndex * 2) % 256)
                bytes[offset + 3] = 255
            }
        }
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw EditorAjarSampleProjectError.invalidFixtureUUID(value)
        }
        return uuid
    }
}

enum EditorAjarSampleProjectError: Error, CustomStringConvertible {
    case invalidFixtureUUID(String)
    case cannotAddVideoInput
    case writerFailed(String)
    case pixelBufferCreationFailed(Int32)
    case missingBaseAddress

    var description: String {
        switch self {
        case .invalidFixtureUUID(let value):
            "invalid sample UUID \(value)"
        case .cannotAddVideoInput:
            "sample movie writer cannot add video input"
        case .writerFailed(let message):
            "sample movie writer failed: \(message)"
        case .pixelBufferCreationFailed(let code):
            "sample pixel buffer creation failed with code \(code)"
        case .missingBaseAddress:
            "sample pixel buffer has no base address"
        }
    }
}

private extension AVAssetWriter {
    var errorDescription: String {
        error.map(String.init(describing:)) ?? "unknown writer error"
    }
}
