// SPDX-License-Identifier: GPL-3.0-or-later

import AjarRender
import Metal
import MetalKit
import SwiftUI

struct ProgramMetalView: NSViewRepresentable {
    let device: MTLDevice?
    let texture: MTLTexture?

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.texture = texture
        view.setNeedsDisplay(view.bounds)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture?
        private let presenter: MetalTexturePresenter?

        init(device: MTLDevice?) {
            if let device {
                presenter = try? MetalTexturePresenter(device: device)
            } else {
                presenter = nil
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let texture, let presenter else {
                return
            }

            try? presenter.present(sourceTexture: texture, in: view)
        }
    }
}
