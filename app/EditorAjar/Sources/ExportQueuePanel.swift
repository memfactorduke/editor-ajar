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
                    .accessibilityLabel(AppString.localized("exportQueue.status.ax", "Export queue status"))
                    .accessibilityValue(status)
            }
            if controller.jobs.isEmpty {
                Text(AppString.localized("exportQueue.empty", "No export jobs"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(AppString.localized("exportQueue.empty", "No export jobs"))
            } else {
                jobList
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Export Queue Panel")
        .accessibilityLabel(AppString.localized("exportQueue.panel.ax", "Export queue"))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(AppString.localized("exportQueue.title", "Export Queue"))
                .font(.headline)
            Spacer()
            Button(AppString.localized("exportQueue.enqueue", "Export Sequence")) {
                model.enqueueActiveSequenceExport()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help(AppString.localized(
                "exportQueue.enqueue.help", "Enqueue a ProRes export of the active sequence"
            ))
            .accessibilityLabel(AppString.localized("exportQueue.enqueue.ax", "Export active sequence"))
            .accessibilityIdentifier("Enqueue Export")
            .accessibilityHint(AppString.localized(
                "exportQueue.enqueue.hint", "Adds a background export job for the current sequence"
            ))

            Button(AppString.localized("exportQueue.hide", "Hide")) {
                model.isExportQueuePanelVisible = false
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(AppString.localized("exportQueue.hide.ax", "Hide export queue"))
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
        .accessibilityLabel(AppString.localized("exportQueue.jobList.ax", "Export jobs"))
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
                .accessibilityLabel(AppString.localized(
                    "exportQueue.job.progress.ax", "Export progress for \(job.displayName)"
                ))
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
        .accessibilityLabel(AppString.localized("exportQueue.job.ax", "Export job \(job.displayName)"))
        .accessibilityValue("\(stateLabel), \(progressValueLabel)")
    }

    @ViewBuilder
    private var controls: some View {
        if job.state == .running {
            Button(AppString.localized("exportQueue.job.pause", "Pause"), action: onPause)
                .buttonStyle(.bordered)
                .accessibilityLabel(AppString.localized(
                    "exportQueue.job.pause.ax", "Pause export \(job.displayName)"
                ))
                .accessibilityHint(AppString.localized(
                    "exportQueue.job.pause.hint", "Stops encoding; resume restarts from the beginning"
                ))
                .accessibilityIdentifier("Pause Export \(job.id.uuidString)")
        }
        if job.state == .pausedWillRestart {
            Button(AppString.localized("exportQueue.job.resume", "Resume"), action: onResume)
                .buttonStyle(.bordered)
                .accessibilityLabel(AppString.localized(
                    "exportQueue.job.resume.ax", "Resume export \(job.displayName)"
                ))
                .accessibilityHint(AppString.localized(
                    "exportQueue.job.resume.hint", "Restarts this export from frame zero"
                ))
                .accessibilityIdentifier("Resume Export \(job.id.uuidString)")
        }
        if job.state == .pending || job.state == .running || job.state == .pausedWillRestart {
            Button(AppString.localized("exportQueue.job.cancel", "Cancel"), action: onCancel)
                .buttonStyle(.bordered)
                .accessibilityLabel(AppString.localized(
                    "exportQueue.job.cancel.ax", "Cancel export \(job.displayName)"
                ))
                .accessibilityIdentifier("Cancel Export \(job.id.uuidString)")
        }
    }

    private var stateLabel: String {
        switch job.state {
        case .pending:
            AppString.localized("exportQueue.state.pending", "Pending")
        case .running:
            AppString.localized("exportQueue.state.running", "Running")
        case .pausedWillRestart:
            AppString.localized("exportQueue.state.paused", "Paused (will restart)")
        case .cancelled:
            AppString.localized("exportQueue.state.cancelled", "Cancelled")
        case .failed:
            AppString.localized("exportQueue.state.failed", "Failed")
        case .done:
            AppString.localized("exportQueue.state.done", "Done")
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
        let frames = AppString.localized(
            "exportQueue.job.frames",
            "\(job.progress.framesWritten)/\(job.progress.totalFrames) frames"
        )
        if let eta = job.progress.estimatedSecondsRemaining {
            return AppString.localized(
                "exportQueue.job.eta", "\(frames) · ~\(Int(eta.rounded()))s left"
            )
        }
        return frames
    }

    private var progressValueLabel: String {
        let percent = Int((job.progress.fractionCompleted * 100).rounded())
        return AppString.localized("exportQueue.job.percent", "\(percent) percent")
    }
}
