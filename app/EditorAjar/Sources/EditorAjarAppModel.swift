// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import Metal
import SwiftUI

@MainActor
final class EditorAjarAppModel: ObservableObject {
    @Published private(set) var project: Project?
    @Published private(set) var isPlaying = false
    @Published private(set) var playheadFrame: Int64 = 0
    @Published private(set) var durationFrames: Int64 = 1
    @Published private(set) var presentedTexture: MTLTexture?
    @Published private(set) var loadMessage: String

    private var playbackController: EditorAjarPlaybackController?
    private var renderPipeline: EditorAjarRenderPipeline?
    private var displayLinkDriver: EditorAjarDisplayLinkDriver?
    private var renderGeneration = 0

    init() {
        loadMessage = "Loading sample project"

        switch Self.makeSampleProject() {
        case .success(let project):
            self.project = project
            durationFrames = Self.durationFrames(for: project)
            if let sequence = project.sequences.first {
                playbackController = EditorAjarPlaybackController(
                    frameRate: sequence.timebase,
                    durationFrames: durationFrames
                )
            }
        case .failure(let error):
            project = nil
            loadMessage = "Sample project unavailable: \(error)"
        }

        do {
            renderPipeline = try EditorAjarRenderPipeline()
            if project != nil {
                loadMessage = "Sample project loaded"
            }
        } catch {
            loadMessage = "Metal playback unavailable: \(error)"
        }

        displayLinkDriver = EditorAjarDisplayLinkDriver { [weak self] deltaSeconds in
            self?.displayLinkTick(deltaSeconds)
        }
        requestRenderForCurrentFrame()
    }

    var activeSequence: Sequence? {
        project?.sequences.first
    }

    var activeSequenceName: String {
        activeSequence?.name ?? "No Sequence"
    }

    var projectSummary: String {
        guard let project else {
            return "No project"
        }

        let sequenceCount = project.sequences.count
        let mediaCount = project.mediaPool.count
        return "\(sequenceCount) sequence, \(mediaCount) media items"
    }

    var frameRateDescription: String {
        playbackController?.frameRateDescription ?? "--"
    }

    var playheadDescription: String {
        "Frame \(playheadFrame)"
    }

    var metalDevice: MTLDevice? {
        renderPipeline?.device
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            displayLinkDriver?.start()
        } else {
            displayLinkDriver?.stop()
        }
    }

    func stepBackward() {
        isPlaying = false
        displayLinkDriver?.stop()
        playbackController?.stepBackward()
        syncPlayheadFromController()
        requestRenderForCurrentFrame()
    }

    func stepForward() {
        isPlaying = false
        displayLinkDriver?.stop()
        playbackController?.stepForward()
        syncPlayheadFromController()
        requestRenderForCurrentFrame()
    }

    func scrub(to frame: Int64) {
        isPlaying = false
        displayLinkDriver?.stop()
        playbackController?.scrub(to: frame)
        syncPlayheadFromController()
        requestRenderForCurrentFrame()
    }

    static func makeSampleProject() -> Result<Project, Error> {
        do {
            return .success(try EditorAjarSampleProjectFactory.makeSampleProject())
        } catch {
            return .failure(error)
        }
    }

    private func displayLinkTick(_ deltaSeconds: Double) {
        guard isPlaying, playbackController?.advance(by: deltaSeconds) == true else {
            return
        }

        syncPlayheadFromController()
        requestRenderForCurrentFrame()
    }

    private func syncPlayheadFromController() {
        playheadFrame = playbackController?.playheadFrame ?? 0
    }

    private func requestRenderForCurrentFrame() {
        guard let project,
              let sequence = activeSequence,
              let renderPipeline
        else {
            return
        }

        renderGeneration += 1
        let generation = renderGeneration
        let frame = playheadFrame
        loadMessage = "Rendering frame \(frame)"

        Task { [weak self, project, sequence, renderPipeline, frame, generation] in
            do {
                let texture = try await renderPipeline.renderFrame(
                    project: project,
                    sequence: sequence,
                    frame: frame
                )
                await MainActor.run {
                    guard self?.renderGeneration == generation else {
                        return
                    }
                    self?.presentedTexture = texture
                    self?.loadMessage = "Rendered \(sequence.name), frame \(frame)"
                }
            } catch {
                await MainActor.run {
                    guard self?.renderGeneration == generation else {
                        return
                    }
                    self?.loadMessage = "Render failed at frame \(frame): \(error)"
                }
            }
        }
    }

    private static func durationFrames(for project: Project) -> Int64 {
        guard let sequence = project.sequences.first else {
            return 1
        }

        let frameRate = sequence.timebase
        var lastFrame: Int64 = 1
        for track in sequence.videoTracks + sequence.audioTracks {
            for item in track.items {
                guard let endTime = try? item.timelineRange.end(),
                      let endFrame = try? endTime.frameIndex(at: frameRate, rounding: .up)
                else {
                    continue
                }
                lastFrame = max(lastFrame, endFrame)
            }
        }
        return max(1, lastFrame)
    }
}
