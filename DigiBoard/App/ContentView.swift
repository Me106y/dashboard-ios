import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = BoardViewModel()
    @State private var showingVideoPicker = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                MetalCanvasView(renderer: renderer, preferredFPS: 30)
                    .ignoresSafeArea()

                VStack {
                    statusBar
                    Spacer()
                    controlBar
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
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
        .fileImporter(isPresented: $showingVideoPicker,
                      allowedContentTypes: [.movie, .video],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.useCustomVideo(url: url)
            }
        }
    }

    private var statusText: String {
        switch model.status {
        case .preparing(let text): return text
        case .running:             return "运行中"
        case .failed(let text):    return text
        }
    }

    // MARK: - 顶部状态

    private var statusBar: some View {
        HStack(spacing: 10) {
            chip(statusText, systemImage: "video.fill")
            if !model.sourceDescription.isEmpty {
                chip(model.sourceDescription, systemImage: "doc.media")
            }
            if model.fps > 0 {
                chip(String(format: "%.1f fps", model.fps), systemImage: "speedometer")
            }
            if model.inferenceMillis > 0 {
                chip(String(format: "分割 %.0f ms", model.inferenceMillis),
                     systemImage: "person.crop.rectangle")
            }
            if model.foregroundRatio > 0 {
                chip(String(format: "人像 %.1f%%", model.foregroundRatio * 100),
                     systemImage: "figure.stand")
            }
            Spacer()
        }
    }

    // MARK: - 底部控制条

    private var controlBar: some View {
        HStack(spacing: 12) {
            // 主按钮：在离线视频与相机之间切换
            Button {
                model.toggleInput()
            } label: {
                Label(model.inputMode == .video ? "切换到相机" : "切换到视频测试",
                      systemImage: model.inputMode == .video ? "camera" : "film")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.inputMode == .video && !model.cameraAvailable)

            // 用自备视频测试
            Button {
                showingVideoPicker = true
            } label: {
                Label("选择视频…", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Spacer()

            Text(model.inputMode == .video ? "离线视频逐帧循环播放" : "实时相机")
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
