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
    @Published private(set) var mode: CornerTracker.Mode = .auto
    @Published private(set) var debugViewIndex: Int = 0
    @Published private(set) var debugViewCount: Int = 1
    @Published private(set) var cameraResolution: CGSize = .zero
    @Published var showsOverlay: Bool = true

    private(set) var renderer: Renderer?

    private let camera: CameraFrameSource
    /// 实际喂给管线的帧源（模拟器回退到静态图）
    private var frameSource: FrameSource?
    private var tracker: CornerTracker?
    private var pipeline: FullPipeline?
    private var cancellables = Set<AnyCancellable>()
    private var statsTimer: Timer?

    private var touchStart: CGPoint?
    private var lastTouchPoint: CGPoint?

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
            self.debugViewCount = pipeline.handles.debugSequence.count
            // 调试用：DB_DEBUG_VIEW=<index> 可直接跳到某一级中间结果
            if let raw = ProcessInfo.processInfo.environment["DB_DEBUG_VIEW"],
               let index = Int(raw) {
                pipeline.present.select(index: index)
                self.debugViewIndex = pipeline.present.selectedIndex
            }
            self.status = .running

            let names = pipeline.handles.debugSequence.enumerated()
                .map { "\($0.offset):\($0.element.name)" }
                .joined(separator: " ")
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
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = self.renderer?.stats.fps ?? 0
            self.frameMillis = self.renderer?.stats.lastFrameMillis ?? 0
            self.inferenceMillis = self.pipeline?.segmentation.lastInferenceMillis ?? 0
            self.detectionMillis = self.pipeline?.cornerDetection.lastDetectionMillis ?? 0
            self.detectionCount = self.pipeline?.cornerDetection.detectionCount ?? 0
            self.debugViewIndex = self.pipeline?.present.selectedIndex ?? 0
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

    // MARK: - 交互（决策 D14）

    func handleTouch(_ point: CGPoint, phase: CanvasTouchPhase, viewSize: CGSize) {
        guard let tracker, cameraResolution.width > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }

        switch phase {
        case .began:
            touchStart = point
            lastTouchPoint = point
            if let cameraPoint = cameraPoint(for: point, viewSize: viewSize) {
                tracker.dragCorner(near: cameraPoint)
            }
        case .moved:
            lastTouchPoint = point
            if let cameraPoint = cameraPoint(for: point, viewSize: viewSize) {
                tracker.dragCorner(near: cameraPoint)
            }
        case .ended:
            defer { touchStart = nil; lastTouchPoint = nil }
            guard let start = touchStart, let end = lastTouchPoint ?? Optional(point) else { break }
            let moved = hypot(end.x - start.x, end.y - start.y)
            if moved < 10 {
                // 单击（位移小于阈值）才切换调试视图，避免上游"一碰就切换"的问题
                cycleDebugView()
            }
        case .cancelled:
            touchStart = nil
            lastTouchPoint = nil
        }

        syncMode()
    }

    private func cameraPoint(for viewPoint: CGPoint, viewSize: CGSize) -> SIMD2<Float>? {
        let rect = DisplayGeometry.fitRect(sourceSize: cameraResolution,
                                           drawableSize: viewSize,
                                           inset: 0.02)
        let nx = viewPoint.x / viewSize.width
        let ny = 1 - viewPoint.y / viewSize.height
        let u = (nx - rect.minX) / rect.width
        let v = (ny - rect.minY) / rect.height
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return SIMD2<Float>(Float(u) * Float(cameraResolution.width),
                            Float(v) * Float(cameraResolution.height))
    }

    private func syncMode() {
        if let tracker { mode = tracker.mode }
    }

    // MARK: - 控件

    func toggleMode() {
        guard let tracker else { return }
        tracker.setMode(tracker.mode == .auto ? .manual : .auto)
        syncMode()
    }

    func setMode(_ newMode: CornerTracker.Mode) {
        tracker?.setMode(newMode)
        syncMode()
    }

    func cycleDebugView() {
        pipeline?.present.next()
        debugViewIndex = pipeline?.present.selectedIndex ?? 0
    }

    func resetCorners() {
        tracker?.resetManual(width: Float(cameraResolution.width),
                             height: Float(cameraResolution.height))
        print("[P5] 角点已重置")
    }
}
