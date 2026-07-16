// SPDX-License-Identifier: GPL-3.0-or-later

import AjarExport
import Foundation

extension GoldenExportHarness {
    static func runAnimatedGIFCase(
        manifest: GoldenExportManifest
    ) async throws -> CaseOutcome {
        let fixture = try ExportGoldenFixture(
            frameCount: Int64(manifest.frameCount),
            width: manifest.width,
            height: manifest.height,
            includeAudio: false,
            animatedTitle: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        let destinationURL = fixture.directoryURL.appendingPathComponent("animated.gif")
        let exported: (result: ExportResult, session: AnimatedGIFExportSession)
        do {
            exported = try await fixture.exportAnimatedGIF(to: destinationURL)
        } catch {
            return .failed("FAIL \(manifest.id) animated GIF export error: \(error)")
        }
        guard exported.result.videoFrameCount == Int64(manifest.frameCount) else {
            return .failed(
                "FAIL \(manifest.id) frameCount=\(exported.result.videoFrameCount) "
                    + "expected=\(manifest.frameCount)"
            )
        }
        guard exported.session.sourceSelectionPolicy == .alwaysOriginal,
              exported.session.sourceSelectionRecords.allSatisfy({ $0.tier == .original })
        else {
            return .failed("FAIL \(manifest.id) source selection used non-original media")
        }

        let decoded = try GoldenAnimatedGIFDecoder.decode(from: destinationURL)
        if let structuralFailure = structuralFailure(
            decoded: decoded,
            session: exported.session,
            manifest: manifest
        ) {
            return .failed(structuralFailure)
        }

        let rawExpected = try await fixture.renderExpectedRawBGRAFrames()
        let expected = try GoldenAnimatedGIFDecoder.convertExpectedToSRGB(
            rawExpected,
            sourceColorSpace: fixture.colorSpace
        )
        return try comparisonOutcome(
            manifestID: manifest.id,
            actual: decoded.frames,
            expected: expected
        )
    }

    private static func comparisonOutcome(
        manifestID: String,
        actual: [ExportDecodedBGRAFrame],
        expected: [ExportDecodedBGRAFrame]
    ) throws -> CaseOutcome {
        let comparison = ExportGoldenComparator.compareSequences(
            actual: actual,
            expected: expected,
            tolerance: .animatedGIFPaletteLossy
        )
        if comparison.passed {
            return .passed(
                "PASS \(manifestID) animated GIF frames=\(actual.count) "
                    + "maxChΔ=\(comparison.maximumChannelDelta) "
                    + "mae=\(String(format: "%.3f", comparison.meanAbsoluteError))"
            )
        }
        try GoldenExportFrameDumper.dumpIfRequested(
            manifestID: manifestID,
            actual: actual,
            expected: expected,
            comparison: comparison
        )
        let diagnostic = comparison.diagnostic.map { " \($0)" } ?? ""
        return .failed(
            "FAIL \(manifestID) animated GIF maxChΔ=\(comparison.maximumChannelDelta) "
                + "mae=\(String(format: "%.3f", comparison.meanAbsoluteError))"
                + diagnostic
        )
    }

    private static func structuralFailure(
        decoded: GoldenAnimatedGIFDecodeResult,
        session: AnimatedGIFExportSession,
        manifest: GoldenExportManifest
    ) -> String? {
        guard decoded.frames.count == manifest.frameCount else {
            return "FAIL \(manifest.id) decodedFrames=\(decoded.frames.count) "
                + "expected=\(manifest.frameCount)"
        }
        guard decoded.frames.allSatisfy({
            $0.width == manifest.width && $0.height == manifest.height
        }) else {
            return "FAIL \(manifest.id) animated GIF dimensions differ from "
                + "\(manifest.width)x\(manifest.height)"
        }
        guard decoded.loopCount == 0 else {
            return "FAIL \(manifest.id) loopCount=\(String(describing: decoded.loopCount)) "
                + "expected=0"
        }
        let expectedDelays: [Int]
        do {
            expectedDelays = try (0..<manifest.frameCount).map {
                try session.request.delayCentiseconds(forFrame: Int64($0))
            }
        } catch {
            return "FAIL \(manifest.id) could not calculate GIF delays: \(error)"
        }
        guard decoded.delayCentiseconds == expectedDelays else {
            return "FAIL \(manifest.id) delays=\(decoded.delayCentiseconds) "
                + "expected=\(expectedDelays)"
        }
        return nil
    }
}
