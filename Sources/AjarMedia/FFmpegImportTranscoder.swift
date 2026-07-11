// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation

// The production transcode method deliberately keeps transaction cleanup adjacent to every exit.
// swiftlint:disable function_body_length function_parameter_count

/// Typed failures from the optional, system-installed FFmpeg import boundary (FR-MED-003).
public enum FFmpegTranscodeError: Error, Equatable, Sendable {
    /// No supported system binary was found. FFmpeg is deliberately not bundled.
    case ffmpegUnavailable(guidance: String)

    /// FFmpeg exited unsuccessfully; only a bounded diagnostic tail is retained.
    case ffmpegFailed(exitCode: Int32, stderrTail: String)

    /// The import task was cancelled and the child process was terminated.
    case transcodeCancelled

    /// FFmpeg stopped reporting progress or exceeded the duration-scaled wall-clock cap.
    case transcodeTimedOut(reason: String)

    /// The package transcode transaction could not be prepared or published.
    case transactionFailed(reason: String)
}

/// Completed native working copy plus source facts needed by the import summary.
public struct FFmpegTranscodeResult: Equatable, Sendable {
    public let outputURL: URL
    public let detectedCodec: String
    public let elapsedSeconds: Double

    /// Whether an already-published working transcode was reused.
    public let reusedExistingTranscode: Bool

    public init(
        outputURL: URL,
        detectedCodec: String,
        elapsedSeconds: Double,
        reusedExistingTranscode: Bool = false
    ) {
        self.outputURL = outputURL
        self.detectedCodec = detectedCodec
        self.elapsedSeconds = elapsedSeconds
        self.reusedExistingTranscode = reusedExistingTranscode
    }
}

/// Injectable import-only transcode boundary. Playback modules never depend on this surface.
public protocol FFmpegImportTranscoding: Sendable {
    func transcode(
        sourceURL: URL,
        originalHash: ContentHash,
        projectPackageURL: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> FFmpegTranscodeResult
}

/// Production system-binary FFmpeg importer (ADR-0003).
public struct SystemFFmpegImportTranscoder: FFmpegImportTranscoding, @unchecked Sendable {
    public static let installGuidance =
        "Install FFmpeg 4 or newer with Homebrew: brew install ffmpeg"

    private let environment: [String: String]
    private let fileManager: FileManager
    private let stallTimeoutSeconds: Double
    private let maximumWallClockSeconds: Double

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        stallTimeoutSeconds: Double = 60,
        maximumWallClockSeconds: Double = 30 * 60
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.stallTimeoutSeconds = stallTimeoutSeconds
        self.maximumWallClockSeconds = maximumWallClockSeconds
    }

    public func transcode(
        sourceURL: URL,
        originalHash: ContentHash,
        projectPackageURL: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> FFmpegTranscodeResult {
        let binaryURL = try await discoverBinary()
        let directoryURL = projectPackageURL.appendingPathComponent(
            "transcodes",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw FFmpegTranscodeError.transactionFailed(reason: String(describing: error))
        }
        let destinationURL = directoryURL.appendingPathComponent(
            originalHash.digest + "-prores422.mov"
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            return FFmpegTranscodeResult(
                outputURL: destinationURL,
                detectedCodec: "unknown (reused existing transcode)",
                elapsedSeconds: 0,
                reusedExistingTranscode: true
            )
        }

        let transaction: MediaTranscodeOutputTransaction
        do {
            transaction = try MediaTranscodeOutputTransaction(
                destinationURL: destinationURL,
                fileManager: fileManager
            )
        } catch {
            throw FFmpegTranscodeError.transactionFailed(reason: String(describing: error))
        }
        let sourceFacts = await Self.inspectSource(binaryURL: binaryURL, sourceURL: sourceURL)
        let started = Date()
        do {
            let execution = try await FFmpegProcessExecution.run(
                binaryURL: binaryURL,
                arguments: [
                    "-nostdin", "-y", "-i", sourceURL.path,
                    "-map", "0:v?", "-map", "0:a?",
                    "-c:v", "prores_ks", "-profile:v", "2",
                    "-c:a", "pcm_s24le",
                    "-progress", "pipe:1", "-nostats",
                    transaction.temporaryURL.path
                ],
                expectedDurationSeconds: sourceFacts.durationSeconds,
                stallTimeoutSeconds: stallTimeoutSeconds,
                maximumWallClockSeconds: maximumWallClockSeconds,
                progress: progress
            )
            guard execution.exitCode == 0 else {
                throw FFmpegTranscodeError.ffmpegFailed(
                    exitCode: execution.exitCode,
                    stderrTail: execution.stderrTail
                )
            }
            try transaction.commit()
            return FFmpegTranscodeResult(
                outputURL: destinationURL,
                detectedCodec: sourceFacts.codec,
                elapsedSeconds: Date().timeIntervalSince(started)
            )
        } catch is CancellationError {
            try? transaction.cleanUp()
            throw FFmpegTranscodeError.transcodeCancelled
        } catch {
            try? transaction.cleanUp()
            throw error
        }
    }

    func discoverBinary() async throws -> URL {
        var directories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("ffmpeg")
            guard fileManager.isExecutableFile(atPath: candidate.path),
                  let major = await Self.versionMajor(binaryURL: candidate),
                  major >= 4 else {
                continue
            }
            return candidate
        }
        throw FFmpegTranscodeError.ffmpegUnavailable(guidance: Self.installGuidance)
    }

    static func versionMajor(in banner: String) -> Int? {
        let firstLine = banner.split(separator: "\n").first.map(String.init) ?? ""
        let token = firstLine.split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
        let numeric = token.drop { !$0.isNumber }
        return Int(numeric.prefix { $0.isNumber })
    }

    private static func versionMajor(binaryURL: URL) async -> Int? {
        let process = Process()
        let output = Pipe()
        process.executableURL = binaryURL
        process.arguments = ["-version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let termination = ProcessTerminationAwaiter()
        process.terminationHandler = { process in
            Task { await termination.didTerminate(status: process.terminationStatus) }
        }
        do {
            try process.run()
            async let outputData = output.fileHandleForReading.readToEnd()
            guard await termination.wait() == 0 else { return nil }
            let data = try await outputData ?? Data()
            let text = String(bytes: data, encoding: .utf8) ?? ""
            // Vendor builds sometimes use N-123 or other non-semver banners. A successful,
            // recognizable FFmpeg banner is accepted when its version is not parseable; the
            // banner remains available here as typed diagnostic input for future telemetry.
            return versionMajor(in: text) ?? (text.hasPrefix("ffmpeg version ") ? 4 : nil)
        } catch {
            return nil
        }
    }

    private static func detectedCodec(in diagnostic: String) -> String {
        guard let range = diagnostic.range(of: "Video: ") else { return "audio/unknown" }
        let suffix = diagnostic[range.upperBound...]
        return String(suffix.prefix { $0 != "," && $0 != "\n" })
    }

    private static func inspectSource(binaryURL: URL, sourceURL: URL) async -> (
        durationSeconds: Double?, codec: String
    ) {
        let process = Process()
        let errors = Pipe()
        process.executableURL = binaryURL
        process.arguments = ["-nostdin", "-i", sourceURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let termination = ProcessTerminationAwaiter()
        process.terminationHandler = { process in
            Task { await termination.didTerminate(status: process.terminationStatus) }
        }
        do {
            try process.run()
            async let errorData = errors.fileHandleForReading.readToEnd()
            _ = await termination.wait()
            let data = try await errorData ?? Data()
            let diagnostic = String(bytes: data, encoding: .utf8) ?? ""
            return (durationSeconds(in: diagnostic), detectedCodec(in: diagnostic))
        } catch {
            return (nil, "unknown")
        }
    }

    private static func durationSeconds(in diagnostic: String) -> Double? {
        guard let marker = diagnostic.range(of: "Duration: ") else { return nil }
        let value = diagnostic[marker.upperBound...].prefix(11)
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3_600 + parts[1] * 60 + parts[2]
    }
}

private final class MediaTranscodeOutputTransaction {
    let destinationURL: URL
    let temporaryURL: URL
    private let fileManager: FileManager
    private var committed = false

    init(destinationURL: URL, fileManager: FileManager) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw FFmpegTranscodeError.transactionFailed(
                reason: "transcodes directory is missing"
            )
        }
        self.destinationURL = destinationURL
        self.fileManager = fileManager
        temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.deletingPathExtension().lastPathComponent)."
                + "\(UUID().uuidString).ajar-partial.mov"
        )
    }

    func commit() throws {
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw FFmpegTranscodeError.transactionFailed(reason: "FFmpeg produced no output")
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        committed = true
    }

    func cleanUp() throws {
        if !committed, fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
    }
}

private enum FFmpegProcessExecution {
    struct ResultValue {
        let exitCode: Int32
        let stderrTail: String
    }

    static func run(
        binaryURL: URL,
        arguments: [String],
        expectedDurationSeconds: Double?,
        stallTimeoutSeconds: Double,
        maximumWallClockSeconds: Double,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ResultValue {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = binaryURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        let termination = ProcessTerminationAwaiter()
        process.terminationHandler = { process in
            Task { await termination.didTerminate(status: process.terminationStatus) }
        }
        try process.run()

        return try await withTaskCancellationHandler {
            let heartbeat = ProgressHeartbeat()
            async let progressRead: Void = streamProgress(
                from: output.fileHandleForReading,
                expectedDurationSeconds: expectedDurationSeconds,
                heartbeat: heartbeat,
                progress: progress
            )
            async let errorData = errors.fileHandleForReading.readToEnd()
            let exitCode = try await awaitExitOrTimeout(
                process: process,
                termination: termination,
                heartbeat: heartbeat,
                expectedDurationSeconds: expectedDurationSeconds,
                stallTimeoutSeconds: stallTimeoutSeconds,
                maximumWallClockSeconds: maximumWallClockSeconds
            )
            try await progressRead
            let stderr = try await errorData ?? Data()
            if Task.isCancelled { throw CancellationError() }
            let diagnostic = String(bytes: stderr.suffix(16_384), encoding: .utf8) ?? ""
            return ResultValue(exitCode: exitCode, stderrTail: diagnostic)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func streamProgress(
        from handle: FileHandle,
        expectedDurationSeconds: Double?,
        heartbeat: ProgressHeartbeat,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        for try await line in handle.bytes.lines {
            if line.hasPrefix("out_time_") || line.hasPrefix("progress=") {
                await heartbeat.advanced()
            }
            if line == "progress=end" {
                await progress(1)
            } else if line.hasPrefix("out_time_us="),
                      let duration = expectedDurationSeconds,
                      duration > 0,
                      let microseconds = Double(line.dropFirst("out_time_us=".count)) {
                await progress(min(0.99, max(0, microseconds / 1_000_000 / duration)))
            }
        }
    }

    private static func awaitExitOrTimeout(
        process: Process,
        termination: ProcessTerminationAwaiter,
        heartbeat: ProgressHeartbeat,
        expectedDurationSeconds: Double?,
        stallTimeoutSeconds: Double,
        maximumWallClockSeconds: Double
    ) async throws -> Int32 {
        let wallCap = min(
            maximumWallClockSeconds,
            max(stallTimeoutSeconds, (expectedDurationSeconds ?? 180) * 10)
        )
        // One minute catches a wedged encoder without punishing slow media; 10x source duration,
        // capped at 30 minutes, permits software decode while bounding a permanently busy child.
        let started = ContinuousClock.now
        while true {
            if let status = await termination.status { return status }
            let now = ContinuousClock.now
            let stalled = await heartbeat.secondsSinceAdvance(at: now) >= stallTimeoutSeconds
            let expired = started.duration(to: now) >= .seconds(wallCap)
            if stalled || expired {
                if process.isRunning { process.terminate() }
                _ = await termination.wait()
                throw FFmpegTranscodeError.transcodeTimedOut(
                    reason: stalled
                        ? "no progress for \(Int(stallTimeoutSeconds)) seconds"
                        : "wall-clock limit exceeded"
                )
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

private actor ProcessTerminationAwaiter {
    private var storedStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    var status: Int32? { storedStatus }

    func didTerminate(status: Int32) {
        guard storedStatus == nil else { return }
        storedStatus = status
        waiters.forEach { $0.resume(returning: status) }
        waiters.removeAll()
    }

    func wait() async -> Int32 {
        if let storedStatus { return storedStatus }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ProgressHeartbeat {
    private var lastAdvance = ContinuousClock.now

    func advanced() { lastAdvance = .now }

    func secondsSinceAdvance(at now: ContinuousClock.Instant) -> Double {
        let components = lastAdvance.duration(to: now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// swiftlint:enable function_body_length function_parameter_count
