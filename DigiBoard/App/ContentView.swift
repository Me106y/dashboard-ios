import SwiftUI

struct ContentView: View {
    @StateObject private var model = BoardViewModel()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if let renderer = model.renderer {
                    MetalCanvasView(renderer: renderer, preferredFPS: 30) { point, phase in
                        model.handleTouch(point, phase: phase, viewSize: geometry.size)
                    }
                    .ignoresSafeArea()

                    VStack(spacing: 0) {
                        statusBar
                        Spacer()
                        if model.showsOverlay { controlBar }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(statusText).font(.footnote).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var statusText: String {
        switch model.status {
        case .preparing(let text): return text
        case .running:             return "运行中"
        case .failed(let text):    return text
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            chip(statusText, systemImage: "video.fill")
            if model.fps > 0 { chip(String(format: "%.1f fps", model.fps), systemImage: "speedometer") }
            if model.frameMillis > 0 {
                chip(String(format: "帧 %.1f ms", model.frameMillis), systemImage: "clock")
            }
            if model.inferenceMillis > 0 {
                chip(String(format: "分割 %.0f ms", model.inferenceMillis), systemImage: "person.crop.rectangle")
            }
            if model.detectionMillis > 0 {
                chip(String(format: "角点 %.0f ms", model.detectionMillis), systemImage: "rectangle.dashed")
            }
            Spacer()
            Button {
                model.showsOverlay.toggle()
            } label: {
                Image(systemName: model.showsOverlay ? "eye.slash" : "eye")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button(model.mode == .auto ? "自动角点" : "手动角点") {
                model.toggleMode()
            }
            .buttonStyle(.borderedProminent)

            Button("调试视图 \(model.debugViewIndex + 1)/\(model.debugViewCount)") {
                model.cycleDebugView()
            }
            .buttonStyle(.bordered)

            Button("重置角点") {
                model.resetCorners()
            }
            .buttonStyle(.bordered)

            Spacer()

            Text("拖动=移动角点 · 轻点画面=切换视图")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .tint(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

#Preview {
    ContentView()
}
