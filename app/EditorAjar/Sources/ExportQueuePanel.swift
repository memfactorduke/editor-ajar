// SPDX-License-Identifier: GPL-3.0-or-later

import AjarExport
import SwiftUI

/// Minimal FR-EXP-005 export queue panel: job list, progress, cancel/pause/resume.
struct ExportQueuePanel: View {
    @ObservedObject var model: EditorAjarAppModel
    @ObservedObject var controller: EditorAjarExportQueueController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let status = controller.statusMessage, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Export queue status")
                    .accessibilityValue(status)
            }
            if controller.jobs.isEmpty {
                Text("No export jobs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("No export jobs")
            } else {
                jobList
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Export Queue Panel")
        .accessibilityLabel("Export queue")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Export Queue")
                .font(.headline)
            Spacer()
            Button("Export Sequence") {
                model.enqueueActiveSequenceExport()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Enqueue a ProRes export of the active sequence")
            .accessibilityLabel("Export active sequence")
            .accessibilityIdentifier("Enqueue Export")
            .accessibilityHint("Adds a background export job for the current sequence")

            Button("Hide") {
                model.isExportQueuePanelVisible = false
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Hide export queue")
            .accessibilityIdentifier("Hide Export Queue")
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.jobs) { job in
                ExportQueueJobRow(
                    job: job,
                    onCancel: { model.cancelExportJob(job.id) },
                    onPause: { model.pauseExportJob(job.id) },
                    onResume: { model.resumeExportJob(job.id) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Export Job List")
        .accessibilityLabel("Export jobs")
    }
}

private struct ExportQueueJobRow: View {
    let job: ExportJobSnapshot
    let onCancel: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(job.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(stateLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(stateColor)
            }

            ProgressView(value: job.progress.fractionCompleted)
                .progressViewStyle(.linear)
                .accessibilityLabel("Export progress for \(job.displayName)")
                .accessibilityValue(progressValueLabel)

            HStack(spacing: 8) {
                Text(progressCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                controls
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Export Job \(job.id.uuidString)")
        .accessibilityLabel("Export job \(job.displayName)")
        .accessibilityValue("\(stateLabel), \(progressValueLabel)")
    }

    @ViewBuilder
    private var controls: some View {
        if job.state == .running {
            Button("Pause", action: onPause)
                .buttonStyle(.bordered)
                .accessibilityLabel("Pause export \(job.displayName)")
                .accessibilityHint("Stops encoding; resume restarts from the beginning")
                .accessibilityIdentifier("Pause Export \(job.id.uuidString)")
        }
        if job.state == .pausedWillRestart {
            Button("Resume", action: onResume)
                .buttonStyle(.bordered)
                .accessibilityLabel("Resume export \(job.displayName)")
                .accessibilityHint("Restarts this export from frame zero")
                .accessibilityIdentifier("Resume Export \(job.id.uuidString)")
        }
        if job.state == .pending || job.state == .running || job.state == .pausedWillRestart {
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel export \(job.displayName)")
                .accessibilityIdentifier("Cancel Export \(job.id.uuidString)")
        }
    }

    private var stateLabel: String {
        switch job.state {
        case .pending:
            "Pending"
        case .running:
            "Running"
        case .pausedWillRestart:
            "Paused (will restart)"
        case .cancelled:
            "Cancelled"
        case .failed:
            "Failed"
        case .done:
            "Done"
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .done:
            .green
        case .failed, .cancelled:
            .orange
        case .pausedWillRestart:
            .yellow
        case .pending, .running:
            .secondary
        }
    }

    private var progressCaption: String {
        let frames =
            "\(job.progress.framesWritten)/\(job.progress.totalFrames) frames"
        if let eta = job.progress.estimatedSecondsRemaining {
            return "\(frames) · ~\(Int(eta.rounded()))s left"
        }
        return frames
    }

    private var progressValueLabel: String {
        let percent = Int((job.progress.fractionCompleted * 100).rounded())
        return "\(percent) percent"
    }
}
