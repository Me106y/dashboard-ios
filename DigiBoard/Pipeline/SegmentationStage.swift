import CoreGraphics
import CoreML
import Metal
import QuartzCore

/// 分割阶段：调用 `SegmentationProvider` 推理，并把 mask 回填成纹理。
/// 对应上游 `SegmentationStage` + `OpenCVDilateStage` + `BitmapToFramebufferStage`
/// 这条链的入口部分。
///
/// 推理在后台队列执行，渲染线程不阻塞（决策 D13：推理与渲染解耦）。
final class SegmentationStage: TextureProducer {
    let name = "Segmentation"
    let inputs: [TextureHandle] = []
    let output: TextureHandle

    private let provider: SegmentationProvider
    private let queue = DispatchQueue(label: "com.zhuanz.digiboard.segmentation", qos: .userInitiated)

    private let lock = NSLock()
    private var latestResult: SegmentationMask?
    private var isRunning = false
    private var pendingImage: CGImage?

    /// 观测用
    private(set) var lastInferenceMillis: Double = 0

    init(provider: SegmentationProvider, spec: TextureSpec) {
        self.provider = provider
        self.output = TextureHandle("segmentation.mask", spec)
    }

    /// 请求对某张图做分割；同一时刻只跑一次，最新请求覆盖排队中的请求。
    func request(_ image: CGImage) {
        lock.lock()
        pendingImage = image
        let shouldStart = !isRunning
        if shouldStart { isRunning = true }
        lock.unlock()
        if shouldStart { pump() }
    }

    private func pump() {
        lock.lock()
        let image = pendingImage
        pendingImage = nil
        lock.unlock()

        guard let image else {
            lock.lock(); isRunning = false; lock.unlock()
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            do {
                let mask = try self.provider.segment(image)
                self.lastInferenceMillis = (CACurrentMediaTime() - start) * 1000
                print(String(format: "[P1] 分割完成 %.1fms mask=%dx%d 前景=%.1f%%",
                             self.lastInferenceMillis, mask.width, mask.height,
                             mask.foregroundRatio * 100))
                self.lock.lock(); self.latestResult = mask; self.lock.unlock()
            } catch {
                print("[Segmentation] 推理失败: \(error)")
            }
            self.pump()   // 继续消化排队的请求
        }
    }

    func produce(_ ctx: FrameContext, texture: MTLTexture) throws {
        lock.lock()
        let result = latestResult
        latestResult = nil
        lock.unlock()

        guard let result else { return }
        upload(result, into: texture)
    }

    private func upload(_ mask: SegmentationMask, into texture: MTLTexture) {
        // CPU 侧缩放不需要：模型输出就是纹理尺寸（256x144）
        let width = min(mask.width, texture.width)
        let height = min(mask.height, texture.height)
        guard width == texture.width, height == texture.height else {
            print("[Segmentation] mask \(mask.width)x\(mask.height) 与纹理 \(texture.width)x\(texture.height) 不一致")
            return
        }
        // 标签是 0/1，而 r8Unorm 需要 0-255 才有可见对比度
        // （对应上游 Visualize.visSegmentation 输出 0/255 的行为）
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            pixels[index] = mask.labels[index] == 0 ? 0 : 255
        }
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: width)
        }
    }
}
