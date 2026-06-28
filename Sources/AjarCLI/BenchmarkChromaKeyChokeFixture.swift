// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import AjarRender
import Foundation
import Metal

struct BenchmarkChromaKeyChokeFixture {
    let dimensions: PixelDimensions
    let project: Project
    let sequence: Sequence
    let sourceProvider: any RenderSourceTextureProvider

    init(device: MTLDevice) throws {
        dimensions = PixelDimensions(width: 3_840, height: 2_160)
        let frameRate = try FrameRate(frames: 30)
        project = try Self.makeProject(dimensions: dimensions, frameRate: frameRate)
        guard let firstSequence = project.sequences.first else {
            throw AjarCLIError.missingSequence
        }
        sequence = firstSequence

        let bottomTexture = try Self.makeTexture(
            device: device,
            dimensions: dimensions,
            pixel: [255, 0, 0, 255]
        )
        let topTexture = try Self.makeSubjectTexture(device: device, dimensions: dimensions)
        sourceProvider = BenchmarkChromaKeyTextureProvider(
            texturesByClipID: [
                try Self.uuid("00000000-0000-0000-0000-000000003014"): bottomTexture,
                try Self.uuid("00000000-0000-0000-0000-000000003015"): topTexture
            ]
        )
    }

    private static func makeProject(
        dimensions: PixelDimensions,
        frameRate: FrameRate
    ) throws -> Project {
        let bottomMediaID = try uuid("00000000-0000-0000-0000-000000003010")
        let topMediaID = try uuid("00000000-0000-0000-0000-000000003011")
        let duration = try frameRate.duration(ofFrames: 60)
        let mediaPool = try [
            makeMedia(id: bottomMediaID, dimensions: dimensions, frameRate: frameRate),
            makeMedia(id: topMediaID, dimensions: dimensions, frameRate: frameRate)
        ]
        let bottomClip = try makeClip(
            id: try uuid("00000000-0000-0000-0000-000000003014"),
            mediaID: bottomMediaID,
            duration: duration,
            effects: .none
        )
        let topClip = try makeClip(
            id: try uuid("00000000-0000-0000-0000-000000003015"),
            mediaID: topMediaID,
            duration: duration,
            effects: ClipEffects(
                chromaKey: ClipChromaKeySettings(
                    enabled: true,
                    keyColor: .green,
                    tolerance: try RationalValue(numerator: 1, denominator: 10),
                    edgeSoftness: .zero,
                    spillSuppression: .zero,
                    choke: try RationalValue(numerator: 1, denominator: 2),
                    viewMatte: false
                )
            )
        )
        let sequence = Sequence(
            id: try uuid("00000000-0000-0000-0000-000000003012"),
            name: "Benchmark Two-Layer Chroma-Key Choke 4K30 Sequence",
            videoTracks: [
                Track(
                    id: try uuid("00000000-0000-0000-0000-000000003016"),
                    kind: .video,
                    items: [.clip(bottomClip)]
                ),
                Track(
                    id: try uuid("00000000-0000-0000-0000-000000003017"),
                    kind: .video,
                    items: [.clip(topClip)]
                )
            ],
            audioTracks: [],
            markers: [],
            timebase: frameRate
        )

        return Project(
            schemaVersion: AjarProjectCodec.currentSchemaVersion,
            settings: ProjectSettings(
                frameRate: frameRate,
                resolution: dimensions,
                colorSpace: .rec709,
                audioSampleRate: 48_000
            ),
            mediaPool: mediaPool,
            sequences: [sequence]
        )
    }

    private static func makeMedia(
        id: UUID,
        dimensions: PixelDimensions,
        frameRate: FrameRate
    ) throws -> MediaRef {
        MediaRef(
            id: id,
            sourceURL: URL(fileURLWithPath: "/benchmark/\(id.uuidString).mov"),
            contentHash: ContentHash.sha256(data: Data(id.uuidString.utf8)),
            metadata: MediaMetadata(
                codecID: "synthetic-bgra",
                pixelDimensions: dimensions,
                frameRate: frameRate,
                duration: try frameRate.duration(ofFrames: 60),
                colorSpace: .rec709,
                audioChannelLayout: nil,
                isVariableFrameRate: false,
                conformedFrameRate: nil
            )
        )
    }

    private static func makeClip(
        id: UUID,
        mediaID: UUID,
        duration: RationalTime,
        effects: ClipEffects
    ) throws -> Clip {
        Clip(
            id: id,
            source: .media(id: mediaID),
            sourceRange: try TimeRange(start: .zero, duration: duration),
            timelineRange: try TimeRange(start: .zero, duration: duration),
            kind: .video,
            name: "Benchmark Chroma Key",
            effects: effects
        )
    }

    private static func makeTexture(
        device: MTLDevice,
        dimensions: PixelDimensions,
        pixel: [UInt8]
    ) throws -> MTLTexture {
        guard pixel.count == 4 else {
            throw AjarCLIError.benchmarkFailed("benchmark texture pixel must be BGRA8")
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimensions.width,
            height: dimensions.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw AjarCLIError.benchmarkFailed("could not allocate benchmark texture")
        }

        let rowBytes = dimensions.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * dimensions.height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = pixel[0]
            pixels[offset + 1] = pixel[1]
            pixels[offset + 2] = pixel[2]
            pixels[offset + 3] = pixel[3]
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, dimensions.width, dimensions.height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: rowBytes
        )
        return texture
    }

    private static func makeSubjectTexture(
        device: MTLDevice,
        dimensions: PixelDimensions
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimensions.width,
            height: dimensions.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw AjarCLIError.benchmarkFailed("could not allocate chroma-key benchmark texture")
        }

        let rowBytes = dimensions.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * dimensions.height)
        let subjectMinX = dimensions.width / 4
        let subjectMaxX = dimensions.width - subjectMinX
        let subjectMinY = dimensions.height / 4
        let subjectMaxY = dimensions.height - subjectMinY
        for yPosition in 0..<dimensions.height {
            for xPosition in 0..<dimensions.width {
                let offset = (yPosition * rowBytes) + (xPosition * 4)
                let isSubject = xPosition >= subjectMinX && xPosition < subjectMaxX
                    && yPosition >= subjectMinY && yPosition < subjectMaxY
                writeSubjectPixel(to: &pixels, offset: offset, isSubject: isSubject)
            }
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, dimensions.width, dimensions.height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: rowBytes
        )
        return texture
    }

    private static func writeSubjectPixel(
        to pixels: inout [UInt8],
        offset: Int,
        isSubject: Bool
    ) {
        pixels[offset] = 0
        pixels[offset + 1] = isSubject ? 0 : 255
        pixels[offset + 2] = isSubject ? 255 : 0
        pixels[offset + 3] = 255
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw AjarCLIError.benchmarkFailed("invalid benchmark UUID \(value)")
        }
        return uuid
    }
}

private final class BenchmarkChromaKeyTextureProvider: RenderSourceTextureProvider {
    private let texturesByClipID: [UUID: MTLTexture]

    init(texturesByClipID: [UUID: MTLTexture]) {
        self.texturesByClipID = texturesByClipID
    }

    func texture(for source: RenderSourceNode) throws -> MTLTexture {
        guard let texture = texturesByClipID[source.clipID] else {
            throw AjarCLIError.decodedTextureUnavailable(source.mediaID)
        }
        return texture
    }
}
