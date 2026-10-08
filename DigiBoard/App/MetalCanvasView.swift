import MetalKit
import SwiftUI

/// 渲染画布：SwiftUI 外壳 + UIKit 的 `MTKView`（决策 D10）。
/// 触摸处理留在 UIKit，便于与上游 `onTouchEvent` 一对一对齐。
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
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
