// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation

final class EditorAjarDisplayLinkDriver {
    private var displayLink: CVDisplayLink?
    private var lastHostTime: UInt64?
    private let onFrame: @MainActor (Double) -> Void

    init(onFrame: @escaping @MainActor (Double) -> Void) {
        self.onFrame = onFrame
    }

    deinit {
        stop()
    }

    func start() {
        if displayLink == nil {
            var createdDisplayLink: CVDisplayLink?
            let createResult = CVDisplayLinkCreateWithActiveCGDisplays(&createdDisplayLink)
            guard createResult == kCVReturnSuccess, let createdDisplayLink else {
                return
            }

            let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(createdDisplayLink, displayLinkCallback, opaqueSelf)
            displayLink = createdDisplayLink
        }

        guard let displayLink, !CVDisplayLinkIsRunning(displayLink) else {
            return
        }

        lastHostTime = nil
        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        guard let displayLink, CVDisplayLinkIsRunning(displayLink) else {
            return
        }

        CVDisplayLinkStop(displayLink)
        lastHostTime = nil
    }

    func tick(outputTime: UnsafePointer<CVTimeStamp>) -> CVReturn {
        let currentHostTime = outputTime.pointee.hostTime
        let deltaSeconds: Double
        if let lastHostTime {
            let ticks = currentHostTime - lastHostTime
            deltaSeconds = Double(ticks) / CVGetHostClockFrequency()
        } else {
            deltaSeconds = 0
        }
        lastHostTime = currentHostTime

        guard deltaSeconds > 0 else {
            return kCVReturnSuccess
        }

        Task { @MainActor in
            onFrame(deltaSeconds)
        }
        return kCVReturnSuccess
    }
}

private let displayLinkCallback: CVDisplayLinkOutputCallback = {
    _, _, outputTime, _, _, userInfo in
    guard let userInfo else {
        return kCVReturnSuccess
    }

    let driver = Unmanaged<EditorAjarDisplayLinkDriver>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return driver.tick(outputTime: outputTime)
}
