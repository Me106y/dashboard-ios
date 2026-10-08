import MetalKit
import SwiftUI

/// 画布上的触摸事件（已换算到视图坐标）
enum CanvasTouchPhase {
    case began
    case moved
    case ended
    case cancelled
}

/// 会转达触摸事件的 MTKView。
/// 触摸处理留在 UIKit：与上游 `OpenGLView.onTouchEvent` 是一对一映射（决策 D10），
/// 但语义按决策 D14 修正——**拖动只拖角点，单击才切换调试视图**。
final class TouchableMTKView: MTKView {
    var onTouch: ((CGPoint, CanvasTouchPhase) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        onTouch?(point, .began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        onTouch?(point, .moved)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        onTouch?(point, .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        onTouch?(point, .cancelled)
    }
}

/// SwiftUI 外壳 + UIKit `MTKView` 画布
struct MetalCanvasView: UIViewRepresentable {
    let renderer: Renderer
    var preferredFPS: Int = 30
    var onTouch: (CGPoint, CanvasTouchPhase) -> Void

    func makeUIView(context: Context) -> TouchableMTKView {
        let view = TouchableMTKView(frame: .zero, device: renderer.metal.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = preferredFPS
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0.06, 0.07, 0.09, 1)
        view.autoResizeDrawable = true
        view.isMultipleTouchEnabled = false
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ uiView: TouchableMTKView, context: Context) {
        uiView.onTouch = onTouch
        uiView.preferredFramesPerSecond = preferredFPS
    }
}
