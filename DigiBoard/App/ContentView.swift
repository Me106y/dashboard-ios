import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = BoardViewModel()
    @State private var showingVideoPicker = false
    /// 控制面板是否展开：下滑收起、上滑展开
    @State private var controlsExpanded = true

    init() {
        // 调试用：DB_CONTROLS=collapsed 启动即收起，便于截图核对两种状态
        let collapsed = ProcessInfo.processInfo.environment["DB_CONTROLS"] == "collapsed"
        _controlsExpanded = State(initialValue: !collapsed)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                MetalCanvasView(renderer: renderer, preferredFPS: 30, isPaused: model.canvasPaused)
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
        .sheet(isPresented: $model.isReportPresented) {
            if let report = model.report {
                RunReportView(report: report,
                              processedVideoURL: model.processedVideoURL,
                              reportCSVURL: model.reportCSVURL,
                              isSaving: model.isSavingVideo,
                              saveMessage: model.saveVideoMessage,
                              onSaveToPhotos: { model.saveProcessedVideoToPhotos() },
                              onReplay: { model.replayDebugRun() },
                              onClose: { model.isReportPresented = false })
            }
        }
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
        // 指标变多后在窄屏会溢出，改为横向可滚动，保证每一项都能看到
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                chip(statusText, systemImage: "video.fill")
                if model.fps > 0 {
                    // 一帧一算：读数是实测帧率，不是写死的 30
                    chip(String(format: "%.1f fps", model.fps), systemImage: "speedometer")
                }
                if model.inferenceMillis > 0 {
                    chip(String(format: "分割 %.0f ms", model.inferenceMillis),
                         systemImage: "person.crop.rectangle")
                }
                if model.foregroundRatio > 0 {
                    chip(String(format: "人像 %.0f%%", model.foregroundRatio * 100),
                         systemImage: "figure.stand")
                }
                // 移动端部署指标：内存 / CPU / 热状态 / 电量
                if model.residentMemoryMB > 0 {
                    chip(String(format: "内存 %.0f MB", model.residentMemoryMB),
                         systemImage: "memorychip")
                }
                if model.cpuPercent > 0 {
                    chip(String(format: "CPU %.0f%%", model.cpuPercent), systemImage: "cpu")
                }
                chip("热 \(model.thermalStateText)", systemImage: "thermometer.medium")
                if model.batteryLevel >= 0 {
                    chip(String(format: "电量 %.0f%%", model.batteryLevel * 100),
                         systemImage: "battery.75")
                }
            }
        }
    }

    // MARK: - 底部控制面板

    private var controlPanel: some View {
        VStack(spacing: controlsExpanded ? 10 : 0) {
            // 抓手：既是收起的可视提示，也是上滑展开的落点
            HStack(spacing: 6) {
                if !controlsExpanded {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 42, height: 5)
                if !controlsExpanded {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())

            if controlsExpanded {
                Picker("输入源", selection: modeBinding) {
                    ForEach(BoardViewModel.InputMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isImporting)

                if model.inputMode == .debug {
                    debugCard
                } else if model.inputMode == .offline {
                    videoCard
                } else {
                    Label("实时相机画面", systemImage: "camera.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
        }
        .tint(.white)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        // 下滑收起 / 上滑展开。最小位移 12pt，避免抢掉分段控件与按钮的点击
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    let dy = value.translation.height
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        if dy > 28 {
                            controlsExpanded = false
                        } else if dy < -28 {
                            controlsExpanded = true
                        }
                    }
                }
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: controlsExpanded)
    }

    /// 分段控件的绑定：没有相机时拒绝切到「实时视频」，并给出提示
    private var modeBinding: Binding<BoardViewModel.InputMode> {
        Binding(get: { model.inputMode },
                set: { model.selectMode($0) })
    }

    /// 离线视频卡片：图标 + 文件名 + 更换按钮（导入中显示进度）
    private var videoCard: some View {
        HStack(spacing: 12) {
            ZStack {
                if model.isImporting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 38, height: 38)
            .background(
                LinearGradient(colors: [.blue.opacity(0.85), .indigo.opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isImporting ? "正在导入…" : "当前素材")
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
                Label(model.isImporting ? "导入中" : "更换",
                      systemImage: model.isImporting ? "hourglass" : "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(model.isImporting ? 0.08 : 0.16), in: Capsule())
            .disabled(model.isImporting)
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

    // MARK: - 调试模式卡片

    /// 调试模式：同一段离线视频，但只跑一遍，放完出资源报告，并可导出处理后的视频。
    private var debugCard: some View {
        VStack(spacing: 10) {
            videoCard

            if model.debugPhase == .running {
                VStack(spacing: 6) {
                    ProgressView(value: model.debugProgress)
                        .tint(.white)
                    HStack {
                        Text("正在跑测一遍（不循环）")
                        Spacer()
                        Text(String(format: "%.0f%%", model.debugProgress * 100))
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Text(model.debugPhase == .finished
                     ? "跑完了：可查看报告，或重新播放再跑一遍"
                     : "调试模式：播放一遍后给出资源报告（fps / 内存 / 热 / 电量），并支持把处理后的视频存到相册")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle(isOn: $model.isRecordingProcessedVideo) {
                Text("保存处理后的视频")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(SwitchToggleStyle(tint: .blue))
            .disabled(model.debugPhase == .running || model.isImporting)

            HStack(spacing: 10) {
                Button {
                    model.isReportPresented = true
                } label: {
                    Label("查看报告", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.white.opacity(model.report == nil ? 0.08 : 0.18), in: Capsule())
                .disabled(model.report == nil)

                Button {
                    model.replayDebugRun()
                } label: {
                    Label("重新播放", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.white.opacity(0.18), in: Capsule())
                .disabled(model.debugPhase == .running || model.isImporting)
            }
        }
    }
}

#Preview {
    ContentView()
}
