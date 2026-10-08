import Combine
import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Metal
import SwiftUI

/// 装配整条管线、处理交互、对外发布会变状态。
final class BoardViewModel: ObservableObject {
    enum Status: Equatable {
        case preparing(String)
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .preparing("启动相机…")
    @Published private(set) var fps: Double = 0
    @Published private(set) var inferenceMillis: Double = 0
    @Published private(set) var detectionMillis: Double = 0
    @Published private(set) var frameMillis: Double = 0
    @Published private(set) var detectionCount: Int = 0
    @Published private(set) var cameraResolution: CGSize = .zero

    private(set) var renderer: Renderer?

    private let camera: CameraFrameSource
    /// 实际喂给管线的帧源（模拟器回退到静态图）
    private var frameSource: FrameSource?
    private var tracker: CornerTracker?
    private var pipeline: FullPipeline?
    private var cancellables = Set<AnyCancellable>()
    private var statsTimer: Timer?

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            status = .failed("本机没有可用的 Metal 设备")
            camera = CameraFrameSource(device: MTLCreateSystemDefaultDevice()!)
            return
        }
        camera = CameraFrameSource(device: device)

        // 模拟器没有相机：直接用打包的静态图跑通整条管线
        #if targetEnvironment(simulator)
        if let still = StillImageFrameSource(device: device, resourceName: "still_sample") {
            frameSource = still
            cameraResolution = still.resolution
            build(cameraSize: still.resolution, source: still)
        } else {
            status = .failed("模拟器静态图加载失败")
        }
        #else
        camera.$resolution
            .receive(on: RunLoop.main)
            .sink { [weak self] size in
                guard let self, size.width > 0, size.height > 0, self.renderer == nil else { return }
                self.cameraResolution = size
                self.frameSource = self.camera
                self.build(cameraSize: size, source: self.camera)
            }
            .store(in: &cancellables)
        #endif

        camera.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle:            self.status = .preparing("相机未启动")
                case .configuring:     self.status = .preparing("正在配置相机…")
                case .running:         if self.renderer != nil { self.status = .running }
                case .unauthorized:    self.status = .failed("未获得相机权限，请到系统设置里开启")
                case .failed(let msg): self.status = .failed(msg)
                }
            }
            .store(in: &cancellables)

        camera.start()
    }

    deinit {
        statsTimer?.invalidate()
        camera.stop()
    }

    // MARK: - 构建

    private func build(cameraSize: CGSize, source: FrameSource) {
        guard let modelURL = Self.locateSegmentationModel() else {
            status = .failed("找不到模型资源 humansegv2portrait")
            return
        }

        do {
            let provider = try CoreMLSegmentationProvider(modelURL: modelURL)
            let tracker = CornerTracker(width: Float(cameraSize.width),
                                        height: Float(cameraSize.height))
            let pipeline = PipelineBuilder.build(source: source,
                                                 cameraSize: cameraSize,
                                                 tracker: tracker,
                                                 provider: provider)
            guard let renderer = Renderer(nodes: pipeline.nodes) else {
                status = .failed("Metal 初始化失败")
                return
            }

            self.tracker = tracker
            self.pipeline = pipeline
            self.renderer = renderer
            // 开发期调试用：DB_DEBUG_VIEW=<index> 可直接跳到某一级中间结果
            if let raw = ProcessInfo.processInfo.environment["DB_DEBUG_VIEW"],
               let index = Int(raw) {
                pipeline.present.select(index: index)
                print("[P5] 调试视图 index=\(index) -> \(pipeline.present.current.name)")
            }
            self.status = .running

            let names = pipeline.handles.debugSequence.enumerated()
                .map { "\($0.offset):\($0.element.name)" }
                .joined(separator: " ")
            // 调试期抓帧：DB_CAPTURE=<文件名>，默认在第 90 帧抓
            if let fileName = ProcessInfo.processInfo.environment["DB_CAPTURE"],
               let url = FrameCapture.makeURL(fileName: fileName) {
                let delay = Int(ProcessInfo.processInfo.environment["DB_CAPTURE_FRAME"] ?? "") ?? 90
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 30.0) {
                    // 抓帧目标跟随当前调试视图，便于逐级比对
                    renderer.captureRequest = Renderer.CaptureRequest(handle: pipeline.present.current,
                                                                      url: url)
                    print("[CAPTURE] 抓帧请求已下发：目标=\(pipeline.present.current.name) index=\(pipeline.present.selectedIndex)")
                }
                print("[CAPTURE] 将在第 \(delay) 帧抓取到 \(url.path)")
            }

            print("[P2] 管线就绪：相机 \(Int(cameraSize.width))x\(Int(cameraSize.height))，"
                  + "分割输入 \(provider.inputWidth)x\(provider.inputHeight)，"
                  + "节点 \(pipeline.nodes.count)")
            print("[P5] 调试视图索引 -> \(names)")

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
            // 真机上没有可见控制台，定期把关键指标打到日志里
            if tick % 4 == 0 {
                let seg = self.pipeline?.segmentation
                let corner = self.pipeline?.cornerDetection
                print(String(format: "[STAT] %.1ffps 帧%.1fms 分割%.0fms 前景%.1f%% 角点%.0fms %d条 %d次",
                             self.fps, self.frameMillis,
                             seg?.lastInferenceMillis ?? 0, (seg?.lastForegroundRatio ?? 0) * 100,
                             corner?.lastDetectionMillis ?? 0,
                             corner?.lastLineCount ?? 0,
                             corner?.detectionCount ?? 0))
            }
            self.fps = self.renderer?.stats.fps ?? 0
            self.frameMillis = self.renderer?.stats.lastFrameMillis ?? 0
            self.inferenceMillis = self.pipeline?.segmentation.lastInferenceMillis ?? 0
            self.detectionMillis = self.pipeline?.cornerDetection.lastDetectionMillis ?? 0
            self.detectionCount = self.pipeline?.cornerDetection.detectionCount ?? 0
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
