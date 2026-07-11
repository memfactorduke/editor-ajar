// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import XCTest

@testable import AjarMedia

final class FFmpegImportTranscoderTests: XCTestCase {
    func testFRMED003VersionParserAcceptsVendorPrefixesAndUnparseableBanner() throws {
        XCTAssertEqual(
            SystemFFmpegImportTranscoder.versionMajor(in: "ffmpeg version N-117000"),
            117000
        )
        XCTAssertEqual(SystemFFmpegImportTranscoder.versionMajor(in: "ffmpeg version n6.1"), 6)
        XCTAssertNil(SystemFFmpegImportTranscoder.versionMajor(in: "ffmpeg version custom-build"))
    }

    func testFRMED003StalledProcessTimesOutAndCleansTemporaryOutput() async throws {
        let root = try temporaryDirectory("timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("ffmpeg")
        let script = """
        #!/bin/sh
        if [ "$1" = "-version" ]; then echo "ffmpeg version custom-build"; exit 0; fi
        case " $* " in
          *" -progress "*) sleep 5 ;;
          *) echo "Duration: 00:00:01.00, Video: vp9" >&2; exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )
        let source = root.appendingPathComponent("source.mkv")
        let bytes = Data("source".utf8)
        try bytes.write(to: source)
        let transcoder = SystemFFmpegImportTranscoder(
            environment: ["PATH": root.path],
            stallTimeoutSeconds: 0.1,
            maximumWallClockSeconds: 1
        )

        do {
            _ = try await transcoder.transcode(
                sourceURL: source,
                originalHash: ContentHash.sha256(data: bytes),
                projectPackageURL: root,
                progress: { _ in }
            )
            XCTFail("expected timeout")
        } catch let error as FFmpegTranscodeError {
            guard case .transcodeTimedOut = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("transcodes").path
        )
        XCTAssertTrue(names.isEmpty)
    }
    func testFRMED003SystemFFmpegCreatesPlayableProResWorkingMovie() async throws {
        let ffmpeg = try await requireFFmpeg()
        let root = try temporaryDirectory("success")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("vp9.mkv")
        try run(
            ffmpeg,
            [
                "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc=size=64x64:rate=5",
                "-t", "0.4", "-c:v", "libvpx-vp9", sourceURL.path
            ]
        )
        let hash = try SHA256MediaFileHasher().contentHash(of: sourceURL)

        let result = try await SystemFFmpegImportTranscoder().transcode(
            sourceURL: sourceURL,
            originalHash: hash,
            projectPackageURL: root,
            progress: { _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertEqual(result.outputURL.lastPathComponent, "\(hash.digest)-prores422.mov")
        let metadata: MediaMetadata
        do {
            metadata = try await AVFoundationMediaProbe().probe(result.outputURL).metadata
        } catch {
            throw XCTSkip("AVFoundation decode is unavailable in this sandbox: \(error)")
        }
        XCTAssertEqual(metadata.codecID, "prores_422")
    }

    func testFRMED003CancellationTerminatesProcessAndLeavesNoPartialMovie() async throws {
        let ffmpeg = try await requireFFmpeg()
        let root = try temporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("long-vp9.mkv")
        try run(
            ffmpeg,
            [
                "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30",
                "-t", "5", "-c:v", "libvpx-vp9", "-deadline", "realtime", sourceURL.path
            ]
        )
        let hash = try SHA256MediaFileHasher().contentHash(of: sourceURL)
        let task = Task {
            try await SystemFFmpegImportTranscoder().transcode(
                sourceURL: sourceURL,
                originalHash: hash,
                projectPackageURL: root,
                progress: { _ in }
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as FFmpegTranscodeError {
            XCTAssertEqual(error, .transcodeCancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let transcodesURL = root.appendingPathComponent("transcodes", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: transcodesURL.path)) ?? []
        XCTAssertTrue(names.isEmpty, "cancelled transcode left files: \(names)")
    }

    private func requireFFmpeg() async throws -> URL {
        do {
            return try await SystemFFmpegImportTranscoder().discoverBinary()
        } catch {
            throw XCTSkip("FFmpeg 4+ is not installed: \(error)")
        }
    }

    private func run(_ executableURL: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "FFmpegImportTranscoderTests",
                code: Int(process.terminationStatus)
            )
        }
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ajar-ffmpeg-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
