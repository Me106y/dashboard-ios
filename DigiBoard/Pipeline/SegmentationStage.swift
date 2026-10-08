import CoreGraphics
import CoreML
import Metal
import QuartzCore

/// 分割推理阶段（决策 D3 / D13）：
/// - 作为 `TextureConsumer` 读取预处理后的 256×144 纹理（GPU 完成后回读）
/// - 在后台队列跑 Core ML，按「每 N 帧一次」节流
/// - 作为 `TextureProducer` 把最新 mask 回填成纹理，渲染线程不阻塞等推理
final class SegmentationStage: TextureProducer, TextureConsumer {
    let name = "Segmentation"

    /// [0] = 预处理后的输入纹理
    let inputs: [TextureHandle]
    let output: TextureHandle
    var consumed: TextureHandle { inputs[0] }

    private let provider: SegmentationProvider
    private let queue = DispatchQueue(label: "com.zhuanz.digiboard.segmentation", qos: .userInitiated)

    /// 每 N 帧推理一次（对应上游的 UpdateEveryXFrames 节流）。
    ///
    /// 这里从 5 调到 2：5 帧意味着 mask 最多滞后 5 帧，人像快速移动时
    /// 遮罩会明显落后于人（实测 IoU 只有 0.77），没被盖住的人像像素会被
    /// 当成「背景稳定」而烤进历史缓冲，导致去遮挡留下残影。
    /// 现在设成 1：配合 `isBusy` 自我节流，等于「跑满 ANE 能跟上的最快速度」，
    /// 人像移动越快、遮罩越不该落后。
    var frameInterval = 1

    private let lock = NSLock()
    private var latestMask: SegmentationMask?
    private var isInferring = false
    private var pendingImage: CGImage?
    private var frameCounter = 0

    private(set) var lastInferenceMillis: Double = 0
    private(set) var lastForegroundRatio: Double = 0
    private(set) var inferenceCount = 0

    init(provider: SegmentationProvider, input: TextureHandle, output: TextureHandle) {
        self.provider = provider
        self.inputs = [input]
        self.output = output
    }

    // MARK: - 回读（渲染完成回调，非渲染线程）

    func consume(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) {
        frameCounter += 1
        guard frameCounter % max(frameInterval, 1) == 0 else { return }

        lock.lock()
        let busy = isInferring
        lock.unlock()
        guard !busy else { return }

        guard let image = Self.makeImage(from: bytes, width: width, height: height, bytesPerRow: bytesPerRow) else {
            return
        }
        enqueue(image)
    }

    private func enqueue(_ image: CGImage) {
        lock.lock()
        pendingImage = image
        let shouldStart = !isInferring
        if shouldStart { isInferring = true }
        lock.unlock()
        if shouldStart { pump() }
    }

    private func pump() {
        lock.lock()
        let image = pendingImage
        pendingImage = nil
        lock.unlock()

        guard let image else {
            lock.lock(); isInferring = false; lock.unlock()
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            do {
                let mask = try self.provider.segment(image)
                self.lastInferenceMillis = (CACurrentMediaTime() - start) * 1000
                self.lastForegroundRatio = mask.foregroundRatio
                self.inferenceCount += 1
                self.lock.lock(); self.latestMask = mask; self.lock.unlock()
            } catch {
                print("[Segmentation] 推理失败: \(error)")
            }
            self.pump()
        }
    }

    // MARK: - 回填（渲染线程）

    func produce(_ ctx: FrameContext, texture: MTLTexture) throws {
        lock.lock()
        let mask = latestMask
        latestMask = nil
        lock.unlock()

        guard let mask else { return }
        upload(mask, into: texture)
    }

    private func upload(_ mask: SegmentationMask, into texture: MTLTexture) {
        let width = min(mask.width, texture.width)
        let height = min(mask.height, texture.height)
        guard width == texture.width, height == texture.height else {
            print("[Segmentation] mask \(mask.width)x\(mask.height) 与纹理 \(texture.width)x\(texture.height) 不一致")
            return
        }
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

    /// RGBA8 字节 -> CGImage（Core ML 的图像输入）
    private static func makeImage(from bytes: UnsafeRawBufferPointer,
                                  width: Int,
                                  height: Int,
                                  bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        // 拷贝一份：回读缓冲区随帧复用，不能持有其指针
        var copy = [UInt8](repeating: 0, count: bytesPerRow * height)
        let byteCount = min(bytes.count, bytesPerRow * height)
        copy.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress,
                  let sourceBase = bytes.baseAddress else { return }
            memcpy(destinationBase, sourceBase, byteCount)
        }
        let data = Data(copy) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
