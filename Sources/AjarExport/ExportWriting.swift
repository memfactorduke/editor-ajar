// SPDX-License-Identifier: GPL-3.0-or-later

import AjarAudio
import CoreMedia
import CoreVideo
import Foundation

protocol ExportWriting: AnyObject {
    func start() throws
    func makeVideoPixelBuffer() throws -> CVPixelBuffer
    func appendVideoIfReady(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws -> Bool
    func appendAudioIfReady(
        _ buffer: RenderedAudioBuffer,
        frames: Range<Int>,
        presentationFrameOffset: Int
    ) throws -> Bool
    func checkForFailure() throws
    func finish(at endTime: CMTime) async throws
    func cancel()
}

typealias ExportWriterFactory = (URL, ExportSettings) throws -> any ExportWriting
