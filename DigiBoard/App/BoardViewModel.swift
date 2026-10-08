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
    enum InputMode: String {
        case video  = "视频"
        case camera = "相机"
    }

    @Published private(set) var status: Status = .preparing("准备中…")
    @Published private(set) var fps: Double = 0
    @Published private(set) var inferenceMillis: Double = 0
    @Published private(set) var frameMillis: Double = 0
    @Published private(set) var foregroundRatio: Double = 0
    @Published private(set) var inputMode: InputMode = .video
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
                      self.inputMode == .camera, self.currentSource == nil else { return }
                self.build(source: self.camera, size: size)
            }
            .store(in: &cancellables)

        camera.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .unauthorized:    if self.inputMode == .camera { self.status = .failed("未获得相机权限") }
                case .failed(let msg): if self.inputMode == .camera { self.status = .failed(msg) }
                default: break
                }
            }
            .store(in: &cancellables)

        // 调试用：DB_SOURCE=still 用静态图当输入（用于几何对齐验证，不受视频时间差干扰）
        if ProcessInfo.processInfo.environment["DB_SOURCE"] == "still",
           let still = StillImageFrameSource(device: device, resourceName: "still_sample") {
            inputMode = .video
            sourceDescription = "still_sample.jpg"
            build(source: still, size: still.resolution)
            return
        }

        // 默认输入：有相机用相机，没有（模拟器）直接用内置测试视频
        if cameraAvailable {
            inputMode = .camera
            camera.start()
            status = .preparing("启动相机…")
            // 相机可能不可用（权限被拒等），3 秒内没出画面就回退到视频
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.currentSource == nil else { return }
                self.switchToVideo()
            }
        } else {
            switchToVideo()
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

    /// 顶部按钮：在「离线视频」与「相机」之间切换
    func toggleInput() {
        switch inputMode {
        case .video:
            guard cameraAvailable else { return }
            switchToCamera()
        case .camera:
            switchToVideo()
        }
    }

    private func switchToVideo() {
        guard let url = customVideoURL ?? Self.bundledVideoURL else {
            status = .failed("找不到测试视频 sample_whiteboard.mp4")
            return
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let source = VideoFrameSource(url: url, device: device) else {
            status = .failed("视频解码器初始化失败")
            return
        }
        camera.stop()
        inputMode = .video
        videoSource = source
        sourceDescription = url.lastPathComponent
        build(source: source, size: source.resolution)
    }

    private func switchToCamera() {
        guard cameraAvailable else { return }
        inputMode = .camera
        videoSource = nil
        sourceDescription = "后置摄像头"
        currentSource = nil
        status = .preparing("启动相机…")
        camera.start()
        // 分辨率回调会触发 build
        if camera.resolution.width > 0 {
            build(source: camera, size: camera.resolution)
        }
    }

    /// 用户自选视频（文件 App / 相册导出的文件）
    func useCustomVideo(url: URL) {
        customVideoURL = url
        switchToVideo()
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

    private static func locateSegmentationModel() -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(forResource: "humansegv2portrait", withExtension: ext) {
                return url
            }
        }
        return nil
    }
}
