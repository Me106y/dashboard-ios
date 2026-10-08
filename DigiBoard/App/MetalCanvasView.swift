import MetalKit
import SwiftUI

/// 渲染画布：SwiftUI 外壳 + UIKit 的 `MTKView`（决策 D10）。
///
/// 需求变更：不再需要拖动角点与点击切换视图，因此这里不再转发触摸事件，
/// 画布是纯输出。
struct MetalCanvasView: UIViewRepresentable {
    let renderer: Renderer
    var preferredFPS: Int = 30

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.metal.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = preferredFPS
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0.06, 0.07, 0.09, 1)
        view.autoResizeDrawable = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.preferredFramesPerSecond = preferredFPS
    }
}
