import AVFoundation
import Combine
import CoreGraphics
import CoreML
import Foundation
import Metal
import SwiftUI

/// 装配整条管线、管理输入源切换。
///
/// 需求变更：
/// - 不再做角点检测与透视校正
/// - 增加「离线视频」输入，可在没有相机的模拟器上直接跑通整条管线
final class BoardViewModel: ObservableObject {
    enum Status: Equatable {
        case preparing(String)
        case running
        case failed(String)
    }

    /// 当前输入源
    enum InputMode: String, CaseIterable, Identifiable {
        case live    = "实时视频"
        case offline = "离线视频"
        case debug   = "调试模式"

        var id: String { rawValue }
        var isCamera: Bool { self == .live }
        /// 后两者都用本地视频文件
        var usesVideo: Bool { self != .live }
        /// 调试模式：不循环播放 → 放完出资源报告 → 可把处理后的视频存进相册
        var isDebug: Bool { self == .debug }
    }

    /// 调试模式的运行阶段
    enum DebugPhase: Equatable {
        case idle
        case running
        case finished
    }

    @Published private(set) var status: Status = .preparing("准备中…")
    @Published private(set) var fps: Double = 0
    @Published private(set) var inferenceMillis: Double = 0
    @Published private(set) var frameMillis: Double = 0
    @Published private(set) var foregroundRatio: Double = 0
    // 运行时资源（与 fps 同一轮轮询采样）：内存 / 可用内存 / CPU / 热状态 / 电量
    @Published private(set) var residentMemoryMB: Double = 0
    @Published private(set) var availableMemoryMB: Double = -1
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var thermalStateText: String = "正常"
    @Published private(set) var batteryLevel: Float = -1
    /// 整机耗电速率（%/小时），样本不足时为 -1
    @Published private(set) var batteryDrainPerHour: Double = -1
    @Published private(set) var inputMode: InputMode = .live
    /// 当前离线视频的文件名（用于界面展示）
    @Published private(set) var videoFileName: String = ""
    /// 正在导入 / 打开离线视频（期间界面显示进度，避免"卡住"的错觉）
    @Published private(set) var isImporting = false
    @Published private(set) var sourceDescription: String = ""
    @Published private(set) var cameraAvailable: Bool = false

    /// 必须是 @Published：切换输入源时会重建 Renderer，
    /// 不发布的话 SwiftUI 不会刷新画布，MTKView 会一直指着被释放的旧 Renderer。
    @Published private(set) var renderer: Renderer?

    // MARK: - 调试模式状态

    @Published private(set) var debugPhase: DebugPhase = .idle
    /// 播放进度 0…1
    @Published private(set) var debugProgress: Double = 0
    /// 放完一遍后的运行报告（nil = 还没有）
    @Published private(set) var report: RunReport?
    /// 是否弹出报告卡片（可写，供 sheet 关闭）
    @Published var isReportPresented = false
    /// 本次跑测是否顺带录制「处理后的视频」
    @Published var isRecordingProcessedVideo = true
    /// 录制产物（本地临时文件），可直接存进相册
    @Published private(set) var processedVideoURL: URL?
    /// 报告明细 CSV（落在沙盒 Documents，可用 devicectl 拉回本机分析）
    @Published private(set) var reportCSVURL: URL?
    @Published private(set) var isSavingVideo = false
    @Published private(set) var saveVideoMessage: String?
    /// 画布是否暂停（放完后停在终帧）
    @Published private(set) var canvasPaused = false

    private let camera: CameraFrameSource
    private var videoSource: VideoFrameSource?
    private var customVideoURL: URL?
    private var pipeline: FullPipeline?
    private var cancellables = Set<AnyCancellable>()
    private var statsTimer: Timer?
    /// 移动端部署指标：内存 / 热状态 / 耗电 / CPU
    private let deviceStats = DeviceStats()
    /// 调试模式的采样记录
    private let recorder = RunRecorder()
    private var exportWriter: ProcessedVideoWriter?
    private var currentSource: FrameSource?
    private var isBuilding = false

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            status = .failed("本机没有可用的 Metal 设备")
            camera = CameraFrameSource(device: MTLCreateSystemDefaultDevice()!)
            return
        }
        camera = CameraFrameSource(device: device)

        // 打印沙盒路径：真机上便于用 devicectl 传文件 / 取产物
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            print("[App] Documents = \(documents.path)")
        }

        #if targetEnvironment(simulator)
        cameraAvailable = false
        #else
        cameraAvailable = true
        #endif

        camera.$resolution
            .receive(on: RunLoop.main)
            .sink { [weak self] size in
                guard let self, size.width > 0, size.height > 0,
                      self.inputMode.isCamera, self.currentSource == nil else { return }
                self.build(source: self.camera, size: size)
            }
            .store(in: &cancellables)

        camera.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .unauthorized:
                    guard self.inputMode.isCamera, self.currentSource == nil else { return }
                    self.status = .failed("未获得相机权限，改用离线视频")
                    self.switchToOfflineVideo()          // 明确被拒 → 回退
                case .failed(let msg):
                    guard self.inputMode.isCamera, self.currentSource == nil else { return }
                    self.status = .failed(msg)
                    self.switchToOfflineVideo()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // 调试用：DB_PICK=<绝对路径> 模拟「文件选择器选了一个视频」，
        // 走的是与 useCustomVideo 完全相同的导入链路，便于自动化验证。
        if let path = ProcessInfo.processInfo.environment["DB_PICK"] {
            // DB_PICK_DELAY>0 时先正常启动，N 秒后再触发导入，
            // 便于观察「导入大文件期间渲染循环是否仍在跑」
            let delay = Double(ProcessInfo.processInfo.environment["DB_PICK_DELAY"] ?? "") ?? 0
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    print("[Video] 触发延迟导入（\(Int(delay))s）")
                    self?.useCustomVideo(url: URL(fileURLWithPath: path))
                }
            } else {
                useCustomVideo(url: URL(fileURLWithPath: path))
                return
            }
        }

        // 调试用：DB_SOURCE=video 强制走离线视频（真机默认是相机）
        if ProcessInfo.processInfo.environment["DB_SOURCE"] == "video" {
            switchToOfflineVideo()
            return
        }

        // 调试用：DB_SOURCE=still 用静态图当输入（用于几何对齐验证，不受视频时间差干扰）
        if ProcessInfo.processInfo.environment["DB_SOURCE"] == "still",
           let still = StillImageFrameSource(device: device, resourceName: "still_sample") {
            inputMode = .offline
            sourceDescription = "still_sample.jpg"
            build(source: still, size: still.resolution)
            return
        }

        // 默认输入：有相机用实时视频，没有（模拟器）直接用内置测试视频
        if cameraAvailable {
            inputMode = .live
            camera.start()
            status = .preparing("启动相机…")
            // 兜底：只有相机长时间仍无画面（例如被其它 App 占用）才回退到离线视频。
            // 不能用短计时器——首次安装时权限弹窗还开着，抢跑会让用户以为"默认就是视频"。
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.currentSource == nil, self.inputMode.isCamera else { return }
                print("[App] 相机 10s 内未出画面，回退到离线视频")
                self.switchToOfflineVideo()
            }
        } else {
            switchToOfflineVideo()
        }
    }

    deinit {
        statsTimer?.invalidate()
        camera.stop()
    }

    // MARK: - 输入源

    /// 内置测试视频（bundle 里的 sample_whiteboard.mp4）
    private static var bundledVideoURL: URL? {
        Bundle.main.url(forResource: "sample_whiteboard", withExtension: "mp4")
    }

    /// 界面上的「实时视频 / 离线视频」切换
    func selectMode(_ mode: InputMode) {
        guard mode != inputMode else { return }
        if mode == .live && !cameraAvailable {
            status = .failed("模拟器没有相机，请使用离线视频或调试模式")
            return
        }
        // 离开调试模式时把报告、录制器等一并收掉，避免残留状态影响下一种输入
        if !mode.isDebug { resetDebugState() }
        switch mode {
        case .live:    switchToLiveCamera()
        case .offline: switchToOfflineVideo()
        case .debug:   switchToDebugVideo()
        }
    }

    private func switchToOfflineVideo() {
        guard let url = customVideoURL ?? Self.bundledVideoURL else {
            status = .failed("找不到内置测试视频 sample_whiteboard.mp4")
            return
        }
        prepareOfflineVideo(url: url, isUserImport: false, debug: false)
    }

    /// 调试模式：同一段离线视频，但跑完一遍就停（不循环），随后出报告。
    private func switchToDebugVideo() {
        guard let url = customVideoURL ?? Self.bundledVideoURL else {
            status = .failed("找不到内置测试视频 sample_whiteboard.mp4")
            return
        }
        prepareOfflineVideo(url: url, isUserImport: false, debug: true)
    }

    private func switchToLiveCamera() {
        guard cameraAvailable, !isImporting else { return }
        inputMode = .live
        videoSource = nil
        videoFileName = ""
        sourceDescription = "后置摄像头"
        currentSource = nil
        status = .preparing("启动相机…")
        camera.start()
        // 分辨率回调会触发 build
        if camera.resolution.width > 0 {
            build(source: camera, size: camera.resolution)
        }
    }

    /// 统一的离线视频装载。
    ///
    /// **全部放到后台**：用户选的 raw 录像可能有几百 MB ~ 几 GB，若还在 iCloud Drive
    /// 里没下载，`copyItem` 会先同步触发整个下载——在主线程做这件事就是几十秒的假死
    /// （用户报的"卡住"）。解码器初始化（`AVURLAsset.loadTracks`）同理。
    private func prepareOfflineVideo(url: URL, isUserImport: Bool, debug: Bool) {
        guard !isImporting else { return }
        isImporting = true
        status = .preparing(isUserImport ? "正在导入 \(url.lastPathComponent)…"
                                         : (debug ? "正在准备调试素材…" : "正在打开测试视频…"))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var videoURL = url
                if isUserImport {
                    // 安全作用域必须在访问文件之前开启，且覆盖整个拷贝过程
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    videoURL = try Self.importVideo(from: url)
                }

                guard let device = MTLCreateSystemDefaultDevice() else {
                    throw VideoSourceError.textureCacheFailed
                }
                // 调试模式：不循环，放完停在最后一帧
                let source = try VideoFrameSource(url: videoURL, device: device, loops: !debug)

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImporting = false
                    if isUserImport { self.customVideoURL = videoURL }
                    self.inputMode = debug ? .debug : .offline
                    self.videoSource = source
                    self.videoFileName = videoURL.lastPathComponent
                    self.sourceDescription = videoURL.lastPathComponent
                    self.camera.stop()
                    if debug {
                        source.onFinished = { [weak self] in self?.debugRunDidFinish() }
                    }
                    self.build(source: source, size: source.resolution)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImporting = false
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.status = .failed(isUserImport ? "导入视频失败：\(reason)" : "离线视频打开失败：\(reason)")
                    print("[Video] 失败: \(error)")
                }
            }
        }
    }

    /// 文件选择器失败时给出提示
    func reportPickerFailure(_ message: String) {
        status = .failed("选择视频失败：\(message)")
    }

    /// 用户自选视频。真正的导入放在后台，界面立刻响应并显示进度。
    func useCustomVideo(url: URL) {
        prepareOfflineVideo(url: url, isUserImport: true, debug: inputMode.isDebug)
    }

    /// 把外部视频拷贝到 Documents/Videos。
    ///
    /// 为什么不直接用选择器给的 URL：
    /// 1. 那是**安全作用域 URL**，不开作用域连 `fileExists` 都会失败；
    /// 2. 文件位于临时收件箱，系统随时可能清掉；
    /// 3. iCloud 上的文件可能还没下载到本地，AVAssetReader 读不了。
    /// 拷贝这一步同时解决了这三件事（拷贝会强制触发下载/物化）。
    ///
    /// 设为 internal 以便单元测试覆盖。
    static func importVideo(from url: URL, into directory: URL? = nil) throws -> URL {
        let fileManager = FileManager.default
        let target = try directory ?? {
            guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw VideoImportError.noDocumentsDirectory
            }
            return documents.appendingPathComponent("Videos", isDirectory: true)
        }()

        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

        // 名字：文件选择器偶尔给出没有扩展名的 URL，这里补一个。
        // mp4/mov 同属 ISO-BMFF 容器，AVFoundation 靠内容嗅探，扩展名只作提示，
        // 因此统一兜底成 .mov 即可（不要去用 AVURLAsset 的 fileType，那个属性不存在）。
        var name = url.lastPathComponent
        if name.isEmpty { name = "imported.mov" }
        if (name as NSString).pathExtension.isEmpty {
            name += ".mov"
        }

        let destination = target.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            throw VideoImportError.copyFailed(error.localizedDescription)
        }
        return destination
    }

    // MARK: - 构建

    private func build(source: FrameSource, size: CGSize) {
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }

        guard let modelURL = Self.locateSegmentationModel() else {
            status = .failed("找不到模型资源 humansegv2portrait")
            return
        }

        do {
            let provider = try CoreMLSegmentationProvider(modelURL: modelURL)
            // 兜底：超大素材（8K raw 等）按比例缩到长边 ≤ 3840，
            // 否则纹理与每帧开销会随分辨率线性膨胀
            let pipelineSize = Self.capped(size, maxLongEdge: 3840)
            let pipeline = PipelineBuilder.build(source: source,
                                                 sourceSize: pipelineSize,
                                                 provider: provider)
            guard let renderer = Renderer(nodes: pipeline.nodes) else {
                status = .failed("Metal 初始化失败")
                return
            }

            self.pipeline = pipeline
            self.renderer = renderer
            self.currentSource = source
            self.status = .running

            // 开发期调试用：DB_DEBUG_VIEW=<index> 直接跳到某一级中间结果
            if let raw = ProcessInfo.processInfo.environment["DB_DEBUG_VIEW"],
               let index = Int(raw) {
                pipeline.present.select(index: index)
            }

            // 调试期抓帧：DB_CAPTURE=<文件名>，默认第 90 帧抓
            if let fileName = ProcessInfo.processInfo.environment["DB_CAPTURE"],
               let url = FrameCapture.makeURL(fileName: fileName) {
                let delay = Int(ProcessInfo.processInfo.environment["DB_CAPTURE_FRAME"] ?? "") ?? 90
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 30.0) {
                    var targets = [Renderer.CaptureTarget(handle: pipeline.present.current, url: url)]
                    // 同帧附带源帧与 mask，便于对齐比对
                    let stem = url.deletingPathExtension().lastPathComponent
                    let dir = url.deletingLastPathComponent()
                    for (handle, suffix) in [(pipeline.handles.camera, "source"),
                                             (pipeline.handles.mask, "mask"),
                                             (pipeline.handles.maskPost, "maskpost"),
                                             (pipeline.handles.stored, "stored"),
                                             (pipeline.handles.cleaned, "cleaned")] {
                        let extra = dir.appendingPathComponent("\(stem)_\(suffix).png")
                        targets.append(Renderer.CaptureTarget(handle: handle, url: extra))
                    }
                    renderer.captureRequest = Renderer.CaptureRequest(targets: targets)
                    print("[CAPTURE] 抓帧请求已下发：\(targets.map { $0.handle.name })")
                }
            }

            print("[PIPE] 输入=\(inputMode.rawValue) 源\(Int(size.width))x\(Int(size.height)) "
                  + "管线\(Int(pipelineSize.width))x\(Int(pipelineSize.height))，"
                  + "分割输入 \(provider.inputWidth)x\(provider.inputHeight)，节点 \(pipeline.nodes.count)")

            if inputMode.isDebug {
                startDebugRun(pipeline: pipeline, size: pipelineSize)
            }
            startStatsPolling()
        } catch {
            status = .failed("初始化失败：\(error.localizedDescription)")
            print("[BoardViewModel] \(error)")
        }
    }

    private func startStatsPolling() {
        statsTimer?.invalidate()
        var tick = 0
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            tick += 1
            self.refreshStats()
            if tick % 4 == 0 { self.logStats() }
        }
    }

    /// 采样一次：刷新界面指标；调试模式下同时记进报告序列并推进进度条。
    ///
    /// 注意 `DeviceStats.sample()` 靠「距上次采样的时间差」算 CPU 占用，
    /// 因此一轮轮询里只能调用一次——多调会让间隔趋近于 0，CPU% 就失去意义了。
    private func refreshStats() {
        fps = renderer?.stats.fps ?? 0
        frameMillis = renderer?.stats.lastFrameMillis ?? 0
        inferenceMillis = pipeline?.segmentation.lastInferenceMillis ?? 0
        foregroundRatio = pipeline?.segmentation.lastForegroundRatio ?? 0

        let device = deviceStats.sample()
        residentMemoryMB = device.residentMB
        availableMemoryMB = device.availableMB
        cpuPercent = device.cpuPercent
        thermalStateText = deviceStats.thermalStateText
        batteryLevel = device.batteryLevel
        batteryDrainPerHour = device.batteryDrainPercentPerHour

        guard inputMode.isDebug, debugPhase == .running else { return }
        recorder.append(fps: fps,
                        frameMillis: frameMillis,
                        inferenceMillis: inferenceMillis,
                        residentMB: device.residentMB,
                        availableMB: device.availableMB,
                        cpuPercent: device.cpuPercent,
                        thermal: device.thermalState,
                        batteryLevel: Double(device.batteryLevel),
                        drainPercentPerHour: device.batteryDrainPercentPerHour)
        if let video = videoSource, video.estimatedFrames > 0 {
            debugProgress = min(1, Double(video.decodedFrames) / Double(video.estimatedFrames))
        }
    }

    private func logStats() {
        var extra = ""
        if let video = videoSource {
            extra = " 解码\(video.decodedFrames)帧 循环\(video.loopCount)次"
        }
        var power = String(format: "内存%.0fMB 可用%.0fMB CPU%.0f%% 热%@",
                           residentMemoryMB, availableMemoryMB, cpuPercent, deviceStats.thermalStateText)
        if batteryLevel >= 0 {
            power += String(format: " 电量%.0f%%", batteryLevel * 100)
            if batteryDrainPerHour > 0 {
                power += String(format: " 耗电%.1f%%/h", batteryDrainPerHour)
            }
        }
        print(String(format: "[STAT] %@ %.1ffps 帧%.1fms 分割%.0fms 前景%.1f%% mask滞后%.0f帧(峰值%.0f) %@%@",
                     inputMode.rawValue, fps, frameMillis,
                     inferenceMillis, foregroundRatio * 100,
                     Double(pipeline?.segmentation.lastMaskAgeFrames ?? 0),
                     Double(pipeline?.segmentation.maxMaskAgeFrames ?? 0), power, extra))
    }

    // MARK: - 调试模式

    /// 管线就绪后启动一次调试跑测。
    private func startDebugRun(pipeline: FullPipeline, size: CGSize) {
        tearDownExport()
        report = nil
        processedVideoURL = nil
        reportCSVURL = nil
        saveVideoMessage = nil
        debugProgress = 0
        isReportPresented = false
        canvasPaused = false
        debugPhase = .running
        recorder.start()
        // 先采一次：让 CPU% 有个基准点，并把耗电计时的起点定在这里
        _ = deviceStats.sample()
        print("[Debug] 开始跑测：\(videoFileName)，预计 \(videoSource?.estimatedFrames ?? 0) 帧")

        guard isRecordingProcessedVideo else { return }
        guard let writer = try? ProcessedVideoWriter(size: size) else {
            print("[Debug] 处理后视频写入器创建失败，本次只出报告")
            return
        }
        exportWriter = writer
        renderer?.recordHandle = pipeline.handles.final
        renderer?.recordSink = { [weak writer] texture in writer?.append(texture) }
        print("[Debug] 开始录制处理结果 \(Int(size.width))x\(Int(size.height))")
    }

    /// 视频放完一遍：收尾采样、停渲染循环、生成报告。
    private func debugRunDidFinish() {
        guard inputMode.isDebug, debugPhase == .running else { return }

        // 收尾再采一次（此时 debugPhase 还是 .running，会被记进序列）
        refreshStats()
        debugPhase = .finished
        statsTimer?.invalidate()
        statsTimer = nil
        recorder.stop()
        debugProgress = 1
        canvasPaused = true
        renderer?.recordHandle = nil
        renderer?.recordSink = nil

        finishExport()

        let finished = recorder.makeReport(title: videoFileName.isEmpty ? "离线素材" : videoFileName,
                                          resolution: videoSource?.resolution ?? .zero,
                                          frames: videoSource?.decodedFrames ?? 0)
        report = finished
        reportCSVURL = Self.writeReportCSV(finished)
        isReportPresented = true
        print("[Debug] 跑测结束：\(finished.frames) 帧，平均 "
              + String(format: "%.1ffps", finished.meanFPS))
    }

    /// 重新跑一遍：解码器归零 + 重建管线（清掉时序累积等持久纹理的残留）。
    func replayDebugRun() {
        guard inputMode.isDebug, let video = videoSource else { return }
        isReportPresented = false
        tearDownExport()
        report = nil
        processedVideoURL = nil
        reportCSVURL = nil
        saveVideoMessage = nil
        debugProgress = 0
        debugPhase = .idle
        video.rewindAndRestart()
        build(source: video, size: video.resolution)
    }

    /// 把处理后的视频存进系统相册。
    func saveProcessedVideoToPhotos() {
        guard let url = processedVideoURL else {
            saveVideoMessage = "还没有生成处理后的视频"
            return
        }
        guard !isSavingVideo else { return }
        isSavingVideo = true
        saveVideoMessage = nil
        PhotoLibrarySaver.saveVideo(at: url) { [weak self] result in
            guard let self else { return }
            self.isSavingVideo = false
            switch result {
            case .success:              self.saveVideoMessage = "已保存到相册"
            case .failure(let error):   self.saveVideoMessage = error.localizedDescription
            }
        }
    }

    private func finishExport() {
        guard let writer = exportWriter else { return }
        exportWriter = nil
        writer.finish { [weak self] result in
            switch result {
            case .success(let url):
                self?.processedVideoURL = url
                print("[Debug] 处理结果已写入 \(url.lastPathComponent)（"
                      + "\(writer.encodedFrames) 帧，丢弃 \(writer.droppedFrames) 帧）")
            case .failure(let error):
                self?.saveVideoMessage = "处理视频生成失败：\(error.localizedDescription)"
            }
        }
    }

    private func tearDownExport() {
        renderer?.recordHandle = nil
        renderer?.recordSink = nil
        exportWriter?.cancel()
        exportWriter = nil
    }

    private func resetDebugState() {
        tearDownExport()
        recorder.stop()
        report = nil
        processedVideoURL = nil
        reportCSVURL = nil
        saveVideoMessage = nil
        debugProgress = 0
        debugPhase = .idle
        canvasPaused = false
        isReportPresented = false
    }

    /// 把报告明细写进 Documents/，便于跑完用 devicectl 把原始数据拉回本机分析。
    private static func writeReportCSV(_ report: RunReport) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = documents.appendingPathComponent("digiboard-report-\(formatter.string(from: Date())).csv")
        do {
            try report.csv().write(to: url, atomically: true, encoding: .utf8)
            print("[Debug] 报告明细已写入 \(url.path)")
            return url
        } catch {
            print("[Debug] 报告 CSV 写入失败：\(error)")
            return nil
        }
    }

    enum VideoImportError: LocalizedError {
        case noDocumentsDirectory
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDocumentsDirectory:    return "找不到可写入的目录"
            case .copyFailed(let reason):  return "拷贝文件失败：\(reason)"
            }
        }
    }

    /// 按长边上限等比缩放
    private static func capped(_ size: CGSize, maxLongEdge: CGFloat) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return size }
        let scale = maxLongEdge / longEdge
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    private static func locateSegmentationModel() -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(forResource: "humansegv2portrait", withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
