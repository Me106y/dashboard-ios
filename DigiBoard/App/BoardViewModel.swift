import CoreGraphics
import CoreML
import Foundation
import ImageIO

/// 装配整条管线并把状态暴露给界面。
/// P1 阶段：静态图 → Metal 上屏 → Core ML 分割 → 同屏显示原图与 mask。
final class BoardViewModel: ObservableObject {
    @Published var status: String = "初始化…"
    @Published var fps: Double = 0
    @Published var inferenceMillis: Double = 0
    @Published var foregroundRatio: Double = 0

    private(set) var renderer: Renderer?

    private var stillStage: StillImageStage?
    private var segmentationStage: SegmentationStage?
    private var refreshTimer: Timer?

    init() {
        do {
            try build()
        } catch {
            status = "初始化失败：\(error.localizedDescription)"
            print("[BoardViewModel] \(error)")
        }
    }

    private func build() throws {
        guard let stillImage = Self.loadStillImage() else {
            throw SegmentationError.imageResizeFailed
        }
        guard let modelURL = Self.locateSegmentationModel() else {
            throw SegmentationError.missingModel("humansegv2portrait")
        }

        let provider = try CoreMLSegmentationProvider(modelURL: modelURL)
        print("[P1] 模型=\(modelURL.lastPathComponent) 输入=\(provider.inputWidth)x\(provider.inputHeight)")
        print("[P1] 静态图=\(stillImage.width)x\(stillImage.height)")

        // 输入图缩到模型要求的尺寸，供分割使用
        guard let modelInput = Self.resize(stillImage,
                                           width: provider.inputWidth,
                                           height: provider.inputHeight) else {
            throw SegmentationError.imageResizeFailed
        }

        // 源图纹理：保持原图比例，宽度 1280
        let sourceWidth = stillImage.width
        let sourceHeight = stillImage.height
        let sourceSpec = TextureSpec(width: sourceWidth, height: sourceHeight,
                                     pixelFormat: .bgra8Unorm,
                                     persistent: true, renderTarget: false, cpuWritable: true)
        let still = StillImageStage(image: stillImage, spec: sourceSpec)

        let maskSpec = TextureSpec(width: provider.inputWidth, height: provider.inputHeight,
                                   pixelFormat: .r8Unorm,
                                   persistent: true, renderTarget: false, cpuWritable: true)
        let segmentation = SegmentationStage(provider: provider, spec: maskSpec)

        // 左半屏：原图；右半屏：mask
        let sourceBlit = BlitStage(name: "Present.Source",
                                   source: still.output,
                                   destinationRect: CGRect(x: 0.02, y: 0.10, width: 0.46, height: 0.80))
        let maskBlit = BlitStage(name: "Present.Mask",
                                 source: segmentation.output,
                                 destinationRect: CGRect(x: 0.52, y: 0.10, width: 0.46, height: 0.80),
                                 grayscale: true)

        guard let renderer = Renderer(nodes: [still, segmentation, sourceBlit, maskBlit]) else {
            throw MetalError.commandBufferFailed
        }

        self.renderer = renderer
        self.stillStage = still
        self.segmentationStage = segmentation

        // P1 是静态图：启动时请求一次分割即可
        segmentation.request(modelInput)
        print("[P1] 已请求分割，节点数=\(renderer.nodes.count)")

        status = "P1 · 静态图 → Core ML 分割（左：原图 / 右：mask）"
        startStatsPolling(renderer: renderer, provider: provider)
    }

    private func startStatsPolling(renderer: Renderer, provider: SegmentationProvider) {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.inferenceMillis = self.segmentationStage?.lastInferenceMillis ?? 0
        }
    }

    // MARK: - 资源

    private static func locateSegmentationModel() -> URL? {
        let candidates: [(String?, String)] = [
            ("humansegv2portrait", "mlmodelc"),
            ("humansegv2portrait", "mlpackage"),
        ]
        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private static func loadStillImage() -> CGImage? {
        guard let url = Bundle.main.url(forResource: "still_sample", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                     width: width,
                                     height: height,
                                     bitsPerComponent: 8,
                                     bytesPerRow: width * 4,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
