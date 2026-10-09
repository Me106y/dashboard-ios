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

                VStack(spacing: 0) {
                    statusBar
                    Spacer(minLength: 8)
                    controlPanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showingVideoPicker,
                      allowedContentTypes: [.movie, .video],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.useCustomVideo(url: url) }
            case .failure(let error):
                model.reportPickerFailure(error.localizedDescription)
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

    // MARK: - 顶部状态条

    private var statusBar: some View {
        HStack(spacing: 9) {
            chip(statusText, systemImage: "video.fill")
            if model.fps > 0 {
                chip(String(format: "%.0f fps", model.fps), systemImage: "speedometer")
            }
            if model.inferenceMillis > 0 {
                chip(String(format: "分割 %.0f ms", model.inferenceMillis),
                     systemImage: "person.crop.rectangle")
            }
            if model.foregroundRatio > 0 {
                chip(String(format: "人像 %.0f%%", model.foregroundRatio * 100),
                     systemImage: "figure.stand")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 底部控制面板

    private var controlPanel: some View {
        VStack(spacing: 10) {
            Picker("输入源", selection: modeBinding) {
                ForEach(BoardViewModel.InputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.inputMode == .offline {
                videoCard
            } else {
                Label("实时相机画面", systemImage: "camera.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .tint(.white)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    /// 分段控件的绑定：没有相机时拒绝切到「实时视频」，并给出提示
    private var modeBinding: Binding<BoardViewModel.InputMode> {
        Binding(get: { model.inputMode },
                set: { model.selectMode($0) })
    }

    /// 离线视频卡片：图标 + 文件名 + 更换按钮
    private var videoCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    LinearGradient(colors: [.blue.opacity(0.85), .indigo.opacity(0.85)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("当前素材")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(model.videoFileName.isEmpty ? "未选择" : model.videoFileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                showingVideoPicker = true
            } label: {
                Label("更换", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Capsule())
        }
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

#Preview {
    ContentView()
}
