import SwiftUI

struct ContentView: View {
    @StateObject private var model = BoardViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                MetalCanvasView(renderer: renderer, preferredFPS: 30)
                    .ignoresSafeArea()

                VStack {
                    statusBar
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
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
            if model.fps > 0 {
                chip(String(format: "%.1f fps", model.fps), systemImage: "speedometer")
            }
            if model.inferenceMillis > 0 {
                chip(String(format: "分割 %.0f ms", model.inferenceMillis),
                     systemImage: "person.crop.rectangle")
            }
            if model.detectionMillis > 0 {
                chip(String(format: "角点 %.0f ms", model.detectionMillis),
                     systemImage: "rectangle.dashed")
            }
            Spacer()
        }
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
