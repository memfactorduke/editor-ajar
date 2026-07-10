// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import CoreVideo
import Foundation
import Metal
import XCTest

@testable import AjarExport

final class StillFrameExportTests: XCTestCase {
    /// Bit-exact PNG round-trip of a structured, fully-opaque multi-color BGRA buffer.
    ///
    /// Encode and decode both use the ADR-0019 delivery color-space mapping (not DeviceRGB),
    /// so color tags cannot silently convert pixels. Alpha is 255 everywhere to avoid
    /// premultiplied alpha round-trip ambiguity.
    func testFREXP004StillFramePNGIsBitExactAgainstRenderedDeliveryBGRA() throws {
        let colorSpace: ExportColorSpace = .rec709
        let width = 32
        let height = 32
        let pixelBuffer = try makeMultiColorOpaqueBGRABuffer(width: width, height: height)
        let expectedBGRA = try StillFrameImageWriter.packedBGRA8(from: pixelBuffer)

        // Fixture must actually be multi-color (not a uniform gap).
        XCTAssertNotEqual(
            pixelAt(expectedBGRA, width: width, x: 0, y: 0),
            pixelAt(expectedBGRA, width: width, x: width - 1, y: 0),
            "fixture TL vs TR must differ"
        )
        XCTAssertNotEqual(
            pixelAt(expectedBGRA, width: width, x: 0, y: 0),
            pixelAt(expectedBGRA, width: width, x: 0, y: height - 1),
            "fixture TL vs BL must differ"
        )
        // Fully opaque.
        for y in 0..<height {
            for x in 0..<width {
                XCTAssertEqual(
                    pixelAt(expectedBGRA, width: width, x: x, y: y).a,
                    255,
                    "fixture must be fully opaque at (\(x),\(y))"
                )
            }
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-still-bitexact-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let destinationURL = directoryURL.appendingPathComponent("still.png")

        try StillFrameImageWriter.write(
            pixelBuffer: pixelBuffer,
            format: .png,
            jpegQuality: 1,
            colorSpace: colorSpace,
            to: destinationURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        // Decode with the SAME color space the PNG was written with (ADR-0019).
        let decoded = try StillFrameImageWriter.decodeBGRA8(
            from: destinationURL,
            colorSpace: colorSpace
        )
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(decoded.bytes, expectedBGRA)
    }

    func testFREXP004StillFrameJPEGWritesFile() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable on this runner")
        }

        let fixture = try StillFixture(fileExtension: "jpg")
        let request = try fixture.makeRequest(format: .jpeg, jpegQuality: 0.85)
        try await StillFrameExporter.export(
            request: request,
            sourceProvider: SourceLessExportProvider()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.destinationURL.path))
        let attrs = try FileManager.default.attributesOfItem(
            atPath: request.destinationURL.path
        )
        let size = attrs[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 32)
    }

    func testFREXP004StillFrameRejectsTimeOutsideTimeline() throws {
        let fixture = try StillFixture()
        let pastEnd = try RationalTime.atFrame(100, frameRate: fixture.frameRate)
        XCTAssertThrowsError(
            try fixture.makeRequest(format: .png, time: pastEnd)
        ) { error in
            XCTAssertEqual(
                error as? ExportError,
                .stillFrameTimeOutOfRange(pastEnd)
            )
        }
    }
}

// MARK: - Multi-color fixture helpers

private struct BGRAPixel: Equatable {
    let b: UInt8
    let g: UInt8
    let r: UInt8
    let a: UInt8
}

/// Four solid opaque quadrants: red / green / blue / white — structured coverage, no alpha.
private func makeMultiColorOpaqueBGRABuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    // Match ExportDeliveryPixelConverterTests: plain host buffer, no IOSurface attrs
    // (IOSurface-backed allocation can fail on some runners with status -6662).
    let status = CVPixelBufferCreate(
        nil,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        throw ExportError.pixelBufferCreationFailed(status)
    }
    let lock = CVPixelBufferLockBaseAddress(buffer, [])
    guard lock == kCVReturnSuccess else {
        throw ExportError.stillFrameWriteFailed("could not lock multi-color fixture buffer")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw ExportError.stillFrameWriteFailed("multi-color fixture has no base address")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let midX = width / 2
    let midY = height / 2
    // BGRA little-endian: B, G, R, A — four solid opaque quadrants.
    let red = BGRAPixel(b: 0, g: 0, r: 255, a: 255)
    let green = BGRAPixel(b: 0, g: 255, r: 0, a: 255)
    let blue = BGRAPixel(b: 255, g: 0, r: 0, a: 255)
    let white = BGRAPixel(b: 255, g: 255, r: 255, a: 255)

    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let pixel: BGRAPixel
            switch (x < midX, y < midY) {
            case (true, true):
                pixel = red
            case (false, true):
                pixel = green
            case (true, false):
                pixel = blue
            case (false, false):
                pixel = white
            }
            let offset = x * 4
            row[offset] = pixel.b
            row[offset + 1] = pixel.g
            row[offset + 2] = pixel.r
            row[offset + 3] = pixel.a
        }
    }
    return buffer
}

private func pixelAt(_ data: Data, width: Int, x: Int, y: Int) -> BGRAPixel {
    let offset = (y * width + x) * 4
    return BGRAPixel(
        b: data[offset],
        g: data[offset + 1],
        r: data[offset + 2],
        a: data[offset + 3]
    )
}

private struct StillFixture {
    let directoryURL: URL
    let destinationURL: URL
    let project: Project
    let sequence: Sequence
    let frameRate: FrameRate
    let resolution: PixelDimensions
    let time: RationalTime

    init(fileExtension: String = "png") throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-still-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        destinationURL = directoryURL.appendingPathComponent("still.\(fileExtension)")
        frameRate = try FrameRate(frames: 30)
        resolution = PixelDimensions(width: 32, height: 32)
        let duration = try frameRate.duration(ofFrames: 30)
        let range = try TimeRange(start: .zero, duration: duration)
        time = try RationalTime.atFrame(5, frameRate: frameRate)
        sequence = Sequence(
            id: UUID(),
            name: "Still",
            videoTracks: [Track(id: UUID(), kind: .video, items: [.gap(range)])],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )
        project = Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: resolution,
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: [],
            sequences: [sequence]
        )
    }

    func makeRequest(
        format: StillImageFormat,
        time requestedTime: RationalTime? = nil,
        jpegQuality: Double = 0.92
    ) throws -> StillFrameExportRequest {
        try StillFrameExportRequest(
            project: project,
            sequenceID: sequence.id,
            time: requestedTime ?? time,
            destinationURL: destinationURL,
            resolution: resolution,
            colorSpace: .rec709,
            format: format,
            jpegQuality: jpegQuality
        )
    }
}
