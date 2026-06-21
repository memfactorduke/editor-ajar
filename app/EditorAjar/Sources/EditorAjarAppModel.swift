// SPDX-License-Identifier: GPL-3.0-or-later

import AjarCore
import Foundation
import SwiftUI

@MainActor
final class EditorAjarAppModel: ObservableObject {
    @Published private(set) var project: Project?
    @Published private(set) var isPlaying = false
    @Published private(set) var playheadFrame: Int64 = 0
    @Published private(set) var loadMessage: String

    init() {
        switch Self.makeSampleProject() {
        case .success(let project):
            self.project = project
            loadMessage = "Sample project loaded"
        case .failure(let error):
            project = nil
            loadMessage = "Sample project unavailable: \(error)"
        }
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
        project?.settings.frameRate.description ?? "--"
    }

    var playheadDescription: String {
        "Frame \(playheadFrame)"
    }

    func togglePlayback() {
        isPlaying.toggle()
    }

    func stepBackward() {
        isPlaying = false
        playheadFrame = max(0, playheadFrame - 1)
    }

    func stepForward() {
        isPlaying = false
        playheadFrame += 1
    }

    static func makeSampleProject() -> Result<Project, Error> {
        do {
            let frameRate = try FrameRate(frames: 30)
            let settings = ProjectSettings(
                frameRate: frameRate,
                resolution: PixelDimensions(width: 1_920, height: 1_080),
                colorSpace: .rec709,
                audioSampleRate: 48_000
            )
            let sequence = Sequence(
                id: UUID(),
                name: "Untitled Sequence",
                videoTracks: [
                    Track(id: UUID(), kind: .video, items: [])
                ],
                audioTracks: [
                    Track(id: UUID(), kind: .audio, items: [])
                ],
                markers: [],
                timebase: frameRate
            )
            let project = Project(
                schemaVersion: 1,
                settings: settings,
                mediaPool: [],
                sequences: [sequence]
            )
            return .success(project)
        } catch {
            return .failure(error)
        }
    }
}
