// SPDX-License-Identifier: GPL-3.0-or-later

import AjarRender
import Metal
import XCTest

final class MetalScopeAnalyzerTests: XCTestCase {
    func testFRCOL003ComputesDeterministicScopeBuffersOnGPU() throws {
        let device = try scopeMetalDeviceOrSkip()
        let frame = try analyzeScopeFixture(device: device)
        try waitForScopeFrame(frame)

        let histogram = try readScopeUInt32Buffer(frame.histogramBuffer, device: device)
        let waveform = try readScopeUInt32Buffer(frame.waveformBuffer, device: device)
        let rgbParade = try readScopeUInt32Buffer(frame.rgbParadeBuffer, device: device)
        let vectorscope = try readScopeUInt32Buffer(frame.vectorscopeBuffer, device: device)

        XCTAssertEqual(histogram.count, MetalScopeLayout.histogramElementCount)
        XCTAssertEqual(waveform.count, scopeFixtureWidth * MetalScopeLayout.binCount)
        XCTAssertEqual(
            rgbParade.count,
            scopeFixtureWidth
                * MetalScopeLayout.rgbParadeChannelCount
                * MetalScopeLayout.binCount
        )
        XCTAssertEqual(vectorscope.count, MetalScopeLayout.vectorscopeElementCount)

        XCTAssertEqual(scopeSum(histogram), UInt32(scopeFixtureSamples.count * 4))
        XCTAssertEqual(scopeSum(waveform), UInt32(scopeFixtureSamples.count))
        XCTAssertEqual(scopeSum(rgbParade), UInt32(scopeFixtureSamples.count * 3))
        XCTAssertEqual(scopeSum(vectorscope), UInt32(scopeFixtureSamples.count))

        assertScopeHistogram(histogram)
        assertScopeWaveform(waveform)
        assertScopeRGBParade(rgbParade)
        assertScopeVectorscope(vectorscope)
    }

    func testFRCOL003RendersScopeTexturesWithoutCPUReadbackInAnalyzer() throws {
        let device = try scopeMetalDeviceOrSkip()
        let frame = try analyzeScopeFixture(device: device)
        try waitForScopeFrame(frame)

        XCTAssertEqual(frame.histogramTexture.width, MetalScopeLayout.binCount)
        XCTAssertEqual(frame.histogramTexture.height, MetalScopeLayout.histogramChannelCount)
        XCTAssertEqual(frame.waveformTexture.width, scopeFixtureWidth)
        XCTAssertEqual(frame.waveformTexture.height, MetalScopeLayout.binCount)
        XCTAssertEqual(frame.rgbParadeTexture.width, scopeFixtureWidth * 3)
        XCTAssertEqual(frame.rgbParadeTexture.height, MetalScopeLayout.binCount)
        XCTAssertEqual(frame.vectorscopeTexture.width, MetalScopeLayout.binCount)
        XCTAssertEqual(frame.vectorscopeTexture.height, MetalScopeLayout.binCount)

        let histogramPixels = try readScopeRGBA8(texture: frame.histogramTexture, device: device)
        let waveformPixels = try readScopeRGBA8(texture: frame.waveformTexture, device: device)
        let paradePixels = try readScopeRGBA8(texture: frame.rgbParadeTexture, device: device)
        let vectorscopePixels = try readScopeRGBA8(
            texture: frame.vectorscopeTexture,
            device: device
        )

        XCTAssertEqual(
            scopePixel(
                histogramPixels,
                width: MetalScopeLayout.binCount,
                x: 255,
                y: MetalScopeHistogramChannel.red.rawValue
            ),
            [255, 0, 0, 255]
        )
        XCTAssertEqual(
            scopePixel(waveformPixels, width: scopeFixtureWidth, x: 1, y: scopeLumaBin(.red)),
            [255, 255, 255, 255]
        )
        XCTAssertEqual(
            scopePixel(
                paradePixels,
                width: scopeFixtureWidth * 3,
                x: scopeFixtureWidth + 2,
                y: 255
            ),
            [0, 255, 0, 255]
        )

        let redVectorPosition = scopeVectorscopePosition(.red)
        XCTAssertEqual(
            scopePixel(
                vectorscopePixels,
                width: MetalScopeLayout.binCount,
                x: redVectorPosition.x,
                y: redVectorPosition.y
            ),
            [255, 255, 255, 255]
        )
    }
}

private struct ScopeSample: Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

private enum ScopeTestError: Error {
    case textureCreationFailed
    case bufferCreationFailed
    case commandQueueCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
}

private let scopeFixtureWidth = 4
private let scopeFixtureHeight = 2
private let scopeFixtureSamples: [ScopeSample] = [
    .black, .red, .green, .blue,
    .white, .gray, .cyan, .magenta
]

private extension ScopeSample {
    static let black = ScopeSample(red: 0, green: 0, blue: 0)
    static let red = ScopeSample(red: 255, green: 0, blue: 0)
    static let green = ScopeSample(red: 0, green: 255, blue: 0)
    static let blue = ScopeSample(red: 0, green: 0, blue: 255)
    static let white = ScopeSample(red: 255, green: 255, blue: 255)
    static let gray = ScopeSample(red: 128, green: 128, blue: 128)
    static let cyan = ScopeSample(red: 0, green: 255, blue: 255)
    static let magenta = ScopeSample(red: 255, green: 0, blue: 255)
}

private func analyzeScopeFixture(device: MTLDevice) throws -> MetalScopeFrame {
    let analyzer = try MetalScopeAnalyzer(device: device)
    let texture = try makeScopeFixtureTexture(device: device)
    return try analyzer.analyze(texture: texture)
}

private func makeScopeFixtureTexture(device: MTLDevice) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: scopeFixtureWidth,
        height: scopeFixtureHeight,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]

    guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw ScopeTestError.textureCreationFailed
    }

    texture.replace(
        region: MTLRegionMake2D(0, 0, scopeFixtureWidth, scopeFixtureHeight),
        mipmapLevel: 0,
        withBytes: scopeFixtureBGRA(),
        bytesPerRow: scopeFixtureWidth * 4
    )
    return texture
}

private func scopeFixtureBGRA() -> [UInt8] {
    scopeFixtureSamples.flatMap { sample in
        [sample.blue, sample.green, sample.red, 255]
    }
}

private func waitForScopeFrame(_ frame: MetalScopeFrame) throws {
    frame.commandBuffer.waitUntilCompleted()
    XCTAssertNil(frame.commandBuffer.error)
    XCTAssertEqual(frame.commandBuffer.status, .completed)
}

private func readScopeUInt32Buffer(_ source: MTLBuffer, device: MTLDevice) throws -> [UInt32] {
    guard let destination = device.makeBuffer(length: source.length, options: .storageModeShared)
    else {
        throw ScopeTestError.bufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw ScopeTestError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw ScopeTestError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw ScopeTestError.blitEncoderCreationFailed
    }

    blitEncoder.copy(
        from: source,
        sourceOffset: 0,
        to: destination,
        destinationOffset: 0,
        size: source.length
    )
    blitEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let count = source.length / MemoryLayout<UInt32>.stride
    let pointer = destination.contents().bindMemory(to: UInt32.self, capacity: count)
    return Array(UnsafeBufferPointer(start: pointer, count: count))
}

private func readScopeRGBA8(texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
    let rowBytes = texture.width * 4
    let byteCount = rowBytes * texture.height
    guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
        throw ScopeTestError.bufferCreationFailed
    }
    guard let commandQueue = device.makeCommandQueue() else {
        throw ScopeTestError.commandQueueCreationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        throw ScopeTestError.commandBufferCreationFailed
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw ScopeTestError.blitEncoderCreationFailed
    }

    blitEncoder.copy(
        from: texture,
        sourceSlice: 0,
        sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
        to: buffer,
        destinationOffset: 0,
        destinationBytesPerRow: rowBytes,
        destinationBytesPerImage: byteCount
    )
    blitEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: byteCount)
    return Array(UnsafeBufferPointer(start: pointer, count: byteCount))
}

private func assertScopeHistogram(
    _ histogram: [UInt32],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(histogram[scopeHistogramIndex(.red, bin: 0)], 4, file: file, line: line)
    XCTAssertEqual(histogram[scopeHistogramIndex(.red, bin: 128)], 1, file: file, line: line)
    XCTAssertEqual(histogram[scopeHistogramIndex(.red, bin: 255)], 3, file: file, line: line)
    XCTAssertEqual(histogram[scopeHistogramIndex(.green, bin: 0)], 4, file: file, line: line)
    XCTAssertEqual(histogram[scopeHistogramIndex(.green, bin: 128)], 1, file: file, line: line)
    XCTAssertEqual(histogram[scopeHistogramIndex(.green, bin: 255)], 3, file: file, line: line)
    XCTAssertEqual(histogram[scopeHistogramIndex(.blue, bin: 0)], 3, file: file, line: line)
    XCTAssertEqual(histogram[scopeHistogramIndex(.blue, bin: 128)], 1, file: file, line: line)
    XCTAssertEqual(histogram[scopeHistogramIndex(.blue, bin: 255)], 4, file: file, line: line)

    for sample in scopeFixtureSamples {
        XCTAssertEqual(
            histogram[scopeHistogramIndex(.luma, bin: scopeLumaBin(sample))],
            1,
            file: file,
            line: line
        )
    }
}

private func assertScopeWaveform(
    _ waveform: [UInt32],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for x in 0..<scopeFixtureWidth {
        for sample in scopeSamples(inColumn: x) {
            let index = MetalScopeLayout.waveformIndex(x: x, bin: scopeLumaBin(sample))
            XCTAssertEqual(waveform[index], 1, file: file, line: line)
        }
    }
}

private func assertScopeRGBParade(
    _ rgbParade: [UInt32],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    var expectedCounts: [Int: UInt32] = [:]
    for x in 0..<scopeFixtureWidth {
        for sample in scopeSamples(inColumn: x) {
            expectedCounts[scopeParadeIndex(.red, x: x, bin: Int(sample.red)), default: 0] += 1
            expectedCounts[scopeParadeIndex(.green, x: x, bin: Int(sample.green)), default: 0] += 1
            expectedCounts[scopeParadeIndex(.blue, x: x, bin: Int(sample.blue)), default: 0] += 1
        }
    }

    for (index, expectedCount) in expectedCounts {
        XCTAssertEqual(rgbParade[index], expectedCount, file: file, line: line)
    }
}

private func assertScopeVectorscope(
    _ vectorscope: [UInt32],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    var expectedCounts: [Int: UInt32] = [:]
    for sample in scopeFixtureSamples {
        let position = scopeVectorscopePosition(sample)
        let index = MetalScopeLayout.vectorscopeIndex(x: position.x, y: position.y)
        expectedCounts[index, default: 0] += 1
    }

    for (index, expectedCount) in expectedCounts {
        XCTAssertEqual(vectorscope[index], expectedCount, file: file, line: line)
    }
}

private func scopeSamples(inColumn x: Int) -> [ScopeSample] {
    [
        scopeFixtureSamples[x],
        scopeFixtureSamples[x + scopeFixtureWidth]
    ]
}

private func scopeHistogramIndex(_ channel: MetalScopeHistogramChannel, bin: Int) -> Int {
    MetalScopeLayout.histogramIndex(channel: channel, bin: bin)
}

private func scopeParadeIndex(_ channel: MetalScopeRGBChannel, x: Int, bin: Int) -> Int {
    MetalScopeLayout.rgbParadeIndex(channel: channel, x: x, bin: bin, width: scopeFixtureWidth)
}

private func scopeLumaBin(_ sample: ScopeSample) -> Int {
    scopeBin(
        (0.2126 * scopeUnit(sample.red))
            + (0.7152 * scopeUnit(sample.green))
            + (0.0722 * scopeUnit(sample.blue))
    )
}

private func scopeVectorscopePosition(_ sample: ScopeSample) -> (x: Int, y: Int) {
    let red = scopeUnit(sample.red)
    let green = scopeUnit(sample.green)
    let blue = scopeUnit(sample.blue)
    let luma = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    let cb = (blue - luma) / (2 * (1 - 0.0722))
    let cr = (red - luma) / (2 * (1 - 0.2126))
    return (x: scopeBin(cb + 0.5), y: scopeBin(cr + 0.5))
}

private func scopeUnit(_ value: UInt8) -> Double {
    Double(value) / 255
}

private func scopeBin(_ value: Double) -> Int {
    let clamped = min(max(value, 0), 1)
    return min(Int((clamped * 255) + 0.5), 255)
}

private func scopeSum(_ values: [UInt32]) -> UInt32 {
    values.reduce(UInt32(0), +)
}

private func scopePixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
    let offset = ((y * width) + x) * 4
    return Array(pixels[offset..<(offset + 4)])
}

private func scopeMetalDeviceOrSkip() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw XCTSkip("Metal device unavailable on this runner")
    }
    return device
}
