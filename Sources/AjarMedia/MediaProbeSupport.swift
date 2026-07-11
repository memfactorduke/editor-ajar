// SPDX-License-Identifier: GPL-3.0-or-later

// swiftlint:disable sorted_imports
import AVFoundation
import AjarCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
// swiftlint:enable sorted_imports

extension AVFoundationMediaProbe {
    func validateNativeVideoDecode(
        asset: AVAsset,
        track: AVAssetTrack,
        sourceURL: URL
    ) throws {
        let reader = try makeValidationReader(asset: asset, sourceURL: sourceURL)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              CMSampleBufferGetImageBuffer(sample) != nil else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        if reader.status == .reading {
            reader.cancelReading()
        }
    }

    func validateNativeAudioDecode(
        asset: AVAsset,
        track: AVAssetTrack,
        sourceURL: URL
    ) throws {
        let reader = try makeValidationReader(asset: asset, sourceURL: sourceURL)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        reader.add(output)
        guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        if reader.status == .reading {
            reader.cancelReading()
        }
    }

    func makeValidationReader(
        asset: AVAsset,
        sourceURL: URL
    ) throws -> AVAssetReader {
        do {
            return try AVAssetReader(asset: asset)
        } catch {
            throw MediaProbeError.timingReadFailed(
                url: sourceURL,
                reason: String(describing: error)
            )
        }
    }

    func inspectTiming(
        asset: AVAsset,
        track: AVAssetTrack,
        sourceURL: URL
    ) throws -> VideoTimingFacts {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaProbeError.timingReadFailed(
                url: sourceURL,
                reason: String(describing: error)
            )
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }

        var statistics = SampleTimingStatistics()
        while let sample = output.copyNextSampleBuffer() {
            statistics.observe(sample)
        }
        if reader.status == .failed {
            throw MediaProbeError.timingReadFailed(
                url: sourceURL,
                reason: reader.error.map(String.init(describing:)) ?? "asset reader failed"
            )
        }
        let facts = statistics.facts
        guard facts.frameCount > 0 else {
            throw MediaProbeError.unsupportedFormat(sourceURL)
        }
        return facts
    }

    func makeRationalTime(_ time: CMTime, sourceURL: URL) throws -> RationalTime {
        guard time.isNumeric, time.value > 0, time.timescale > 0 else {
            throw MediaProbeError.metadataUnavailable(
                url: sourceURL,
                reason: "source duration is missing or not positive"
            )
        }
        do {
            return try RationalTime(value: time.value, timescale: Int64(time.timescale))
        } catch {
            throw MediaProbeError.metadataUnavailable(
                url: sourceURL,
                reason: String(describing: error)
            )
        }
    }

    func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    func stillCodecID(for url: URL, source: CGImageSource) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "jpeg"
        case "heic", "heif":
            return "heif"
        case "tif", "tiff":
            return "tiff"
        case "gif":
            return "gif"
        case "png":
            return "png"
        default:
            return (CGImageSourceGetType(source) as String?) ?? "image"
        }
    }

    func stillColorSpace(for image: CGImage) -> MediaColorSpace {
        guard let name = image.colorSpace?.name else {
            return .unspecified
        }
        let normalizedName = (name as String).lowercased()
        if normalizedName.contains("displayp3") || normalizedName.contains("display p3") {
            return .displayP3
        }
        if normalizedName.contains("2020") || normalizedName.contains("2100") {
            return .rec2020
        }
        if normalizedName.contains("709") {
            return .rec709
        }
        if normalizedName.contains("srgb") {
            return .sRGB
        }
        return .unknown
    }

    func videoColorSpace(for description: CMFormatDescription) -> MediaColorSpace {
        guard let rawExtensions = CMFormatDescriptionGetExtensions(description),
              let primaries = (rawExtensions as NSDictionary)[
                kCMFormatDescriptionExtension_ColorPrimaries
              ] as? String
        else {
            // Rec.709 is the safe import inference for untagged SDR video currently supported by
            // the native playback path. Tagged P3/2020 sources take the branches below.
            return .rec709
        }
        let rec2020 = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        let displayP3 = kCMFormatDescriptionColorPrimaries_P3_D65 as String
        let cinemaP3 = kCMFormatDescriptionColorPrimaries_DCI_P3 as String
        let rec709 = kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        let ebu3213 = kCMFormatDescriptionColorPrimaries_EBU_3213 as String
        let smpteC = kCMFormatDescriptionColorPrimaries_SMPTE_C as String
        switch primaries {
        case rec2020:
            return .rec2020
        case displayP3, cinemaP3:
            return .displayP3
        case rec709, ebu3213, smpteC:
            return .rec709
        default:
            return .unknown
        }
    }

    func codecID(for subtype: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xFF),
            UInt8((subtype >> 16) & 0xFF),
            UInt8((subtype >> 8) & 0xFF),
            UInt8(subtype & 0xFF)
        ]
        let fourCC = String(bytes: bytes, encoding: .macOSRoman)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        switch fourCC {
        case "avc1", "avc3":
            return "h264"
        case "hvc1", "hev1":
            return "hevc"
        case "apco":
            return "prores_proxy"
        case "apcs":
            return "prores_lt"
        case "apcn":
            return "prores_422"
        case "apch":
            return "prores_422_hq"
        case "ap4h", "ap4x":
            return "prores_4444"
        case "lpcm":
            return "pcm"
        default:
            return fourCC.isEmpty ? "unknown" : fourCC
        }
    }

    func frameRate(near framesPerSecond: Double) -> FrameRate? {
        guard framesPerSecond.isFinite, framesPerSecond > 0 else {
            return nil
        }
        for candidate in Self.standardFrameRates
            where abs(candidate.framesPerSecond - framesPerSecond) < 0.02 {
            return candidate.rate
        }
        let scaled = Int64((framesPerSecond * 1_000).rounded())
        return try? FrameRate(frames: scaled, per: 1_000)
    }

    static var standardFrameRates: [(rate: FrameRate, framesPerSecond: Double)] {
        let values: [(Int64, Int64)] = [
            (24_000, 1_001), (24, 1), (25, 1), (30_000, 1_001), (30, 1),
            (48_000, 1_001), (48, 1), (50, 1), (60_000, 1_001), (60, 1), (120, 1)
        ]
        return values.compactMap { frames, seconds in
            guard let rate = try? FrameRate(frames: frames, per: seconds) else {
                return nil
            }
            return (rate, Double(frames) / Double(seconds))
        }
    }
}

struct VideoFacts {
    let codecID: String
    let dimensions: PixelDimensions
    let frameRate: FrameRate?
    let timing: VideoTimingFacts
    let duration: RationalTime?
    let colorSpace: MediaColorSpace
}

struct AudioFacts {
    let codecID: String
    let layout: AjarCore.AudioChannelLayout?
}

struct VideoTimingFacts {
    let frameCount: Int64
    let isVariableFrameRate: Bool
    let averageFrameRate: FrameRate?
}

struct SampleTimingStatistics {
    private var presentationSeconds: [Double] = []

    init(presentationSeconds: [Double] = []) {
        self.presentationSeconds = presentationSeconds
    }

    mutating func observe(_ sample: CMSampleBuffer) {
        guard CMSampleBufferGetNumSamples(sample) > 0 else {
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard timestamp.isFinite else {
            return
        }
        presentationSeconds.append(timestamp)
    }

    var facts: VideoTimingFacts {
        let sortedTimestamps = presentationSeconds.sorted()
        let timestampPairs = zip(sortedTimestamps, sortedTimestamps.dropFirst())
        let intervals = timestampPairs.compactMap { previous, current -> Double? in
            let interval = current - previous
            return interval.isFinite && interval > 0 ? interval : nil
        }
        let minimumInterval = intervals.min() ?? 0
        let maximumInterval = intervals.max() ?? 0
        let observedIntervals = minimumInterval.isFinite && maximumInterval > 0
        let tolerance = observedIntervals ? max(0.000_1, minimumInterval * 0.02) : 0
        let frameCount = Int64(sortedTimestamps.count)
        let isVariable = frameCount > 2
            && observedIntervals
            && maximumInterval - minimumInterval > tolerance

        let elapsed: Double?
        if let first = sortedTimestamps.first,
           let last = sortedTimestamps.last,
           frameCount > 1 {
            elapsed = last - first + minimumInterval
        } else {
            elapsed = nil
        }
        let averageRate: FrameRate?
        if let elapsed, elapsed.isFinite, elapsed > 0 {
            averageRate = approximateFrameRate(Double(frameCount) / elapsed)
        } else {
            averageRate = nil
        }
        return VideoTimingFacts(
            frameCount: frameCount,
            isVariableFrameRate: isVariable,
            averageFrameRate: averageRate
        )
    }

    private func approximateFrameRate(_ framesPerSecond: Double) -> FrameRate? {
        guard framesPerSecond.isFinite, framesPerSecond > 0 else {
            return nil
        }
        let scaled = Int64((framesPerSecond * 1_000).rounded())
        return try? FrameRate(frames: scaled, per: 1_000)
    }
}
