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

        var id: String { rawValue }
        var isCamera: Bool { self == .live }
    }

    @Published private(set) var status: Status = .preparing("准备中…")
    @Published private(set) var fps: Double = 0
    @Published private(set) var inferenceMillis: Double = 0
    @Published private(set) var frameMillis: Double = 0
    @Published private(set) var foregroundRatio: Double = 0
    @Published private(set) var inputMode: InputMode = .live
    /// 当前离线视频的文件名（用于界面展示）
    @Published private(set) var videoFileName: String = ""
    @Published private(set) var sourceDescription: String = ""
    @Published private(set) var cameraAvailable: Bool = false

    private(set) var renderer: Renderer?

    private let camera: CameraFrameSource
    private var videoSource: VideoFrameSource?
    private var customVideoURL: URL?
    private var pipeline: FullPipeline?
    private var cancellables = Set<AnyCancellable>()
    private var statsTimer: Timer?
    private var currentSource: FrameSource?
    private var isBuilding = false

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            status = .failed("本机没有可用的 Metal 设备")
            camera = CameraFrameSource(device: MTLCreateSystemDefaultDevice()!)
            return
        }
        camera = CameraFrameSource(device: device)

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
                case .unauthorized:    if self.inputMode.isCamera { self.status = .failed("未获得相机权限") }
                case .failed(let msg): if self.inputMode.isCamera { self.status = .failed(msg) }
                default: break
                }
            }
            .store(in: &cancellables)

        // 调试用：DB_PICK=<绝对路径> 模拟「文件选择器选了一个视频」，
        // 走的是与 useCustomVideo 完全相同的导入链路，便于自动化验证。
        if let path = ProcessInfo.processInfo.environment["DB_PICK"] {
            useCustomVideo(url: URL(fileURLWithPath: path))
            return
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
            // 相机可能不可用（权限被拒等），3 秒内没出画面就回退到离线视频
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.currentSource == nil else { return }
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
            status = .failed("模拟器没有相机，请使用离线视频")
            return
        }
        switch mode {
        case .live:    switchToLiveCamera()
        case .offline: switchToOfflineVideo()
        }
    }

    private func switchToOfflineVideo() {
        guard let url = customVideoURL ?? Self.bundledVideoURL else {
            status = .failed("找不到内置测试视频 sample_whiteboard.mp4")
            return
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            status = .failed("本机没有可用的 Metal 设备")
            return
        }
        do {
            let source = try VideoFrameSource(url: url, device: device)
            camera.stop()
            inputMode = .offline
            videoSource = source
            videoFileName = url.lastPathComponent
            sourceDescription = url.lastPathComponent
            build(source: source, size: source.resolution)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed("离线视频打开失败：\(reason)")
            print("[Video] 打开失败 url=\(url.path) error=\(error)")
        }
    }

    private func switchToLiveCamera() {
        guard cameraAvailable else { return }
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

    /// 文件选择器失败时给出提示
    func reportPickerFailure(_ message: String) {
        status = .failed("选择视频失败：\(message)")
    }

    /// 用户自选视频。
    ///
    /// 文件选择器给的是**安全作用域 URL**，且文件位于临时收件箱：
    /// 不开启安全作用域就 `fileExists`/读取会失败（表现为"解码器初始化失败"），
    /// 而且系统随时可能清掉它。所以这里开启作用域、把文件**拷贝进 App 沙盒**再使用。
    func useCustomVideo(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let localURL = try Self.importVideo(from: url)
            customVideoURL = localURL
            print("[Video] 已导入到沙盒: \(localURL.path)")
            switchToOfflineVideo()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed("导入视频失败：\(reason)")
            print("[Video] 导入失败: \(error)")
        }
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
            let pipeline = PipelineBuilder.build(source: source,
                                                 sourceSize: size,
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

            print("[PIPE] 输入=\(inputMode.rawValue) \(Int(size.width))x\(Int(size.height))，"
                  + "分割输入 \(provider.inputWidth)x\(provider.inputHeight)，节点 \(pipeline.nodes.count)")

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
            self.fps = self.renderer?.stats.fps ?? 0
            self.frameMillis = self.renderer?.stats.lastFrameMillis ?? 0
            self.inferenceMillis = self.pipeline?.segmentation.lastInferenceMillis ?? 0
            self.foregroundRatio = self.pipeline?.segmentation.lastForegroundRatio ?? 0
            if tick % 4 == 0 {
                var extra = ""
                if let video = self.videoSource {
                    extra = " 解码\(video.decodedFrames)帧 循环\(video.loopCount)次"
                }
                print(String(format: "[STAT] %@ %.1ffps 帧%.1fms 分割%.0fms 前景%.1f%%%@",
                             self.inputMode.rawValue, self.fps, self.frameMillis,
                             self.inferenceMillis, self.foregroundRatio * 100, extra))
            }
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

    private static func locateSegmentationModel() -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(forResource: "humansegv2portrait", withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
