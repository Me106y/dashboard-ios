import MetalKit
import SwiftUI

/// 渲染画布：SwiftUI 外壳 + UIKit 的 `MTKView`（决策 D10）。
///
/// 需求变更：不再需要拖动角点与点击切换视图，因此这里不再转发触摸事件，
/// 画布是纯输出。
struct MetalCanvasView: UIViewRepresentable {
    let renderer: Renderer
    var preferredFPS: Int = 30
    /// 暂停渲染循环。调试模式跑完一遍后置 true：画面停在最后一帧（不再解码、不再耗电），
    /// 报告卡片叠在静止的终帧上。`MTKView` 会保留最后presented的 drawable，画面不会丢。
    var isPaused: Bool = false

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.metal.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = preferredFPS
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = isPaused
        view.clearColor = MTLClearColorMake(0.06, 0.07, 0.09, 1)
        view.autoResizeDrawable = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Renderer 是 MTKView 的 weak delegate：切换输入源会换一个 Renderer，
        // 这里必须重新绑定，否则旧 Renderer 释放后 delegate 变 nil，画面直接停住。
        if uiView.delegate !== renderer {
            uiView.delegate = renderer
        }
        uiView.preferredFramesPerSecond = preferredFPS
        if uiView.isPaused != isPaused {
            uiView.isPaused = isPaused
        }
    }
}
