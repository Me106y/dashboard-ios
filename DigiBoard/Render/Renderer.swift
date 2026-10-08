import Metal
import MetalKit
import QuartzCore

/// 管线调度器：按顺序执行节点、解析纹理、管理命令缓冲。
///
/// - 输入/输出由节点显式声明，调度器负责分配与依赖校验（决策 D13）
/// - 纹理经 `TexturePool` 复用，不再让纹理数随阶段线性增长
/// - 用信号量把 in-flight 命令缓冲限制在 3 以内
final class Renderer: NSObject, MTKViewDelegate {
    let metal: MetalContext
    private(set) var nodes: [PipelineNode] = []

    private let inFlight = DispatchSemaphore(value: 3)
    let stats = FrameStats()

    /// 跨帧保留的纹理（persistent 句柄 -> 纹理）。
    ///
    /// 必须由 Renderer 持有：`FrameContext` 每帧重建，若只靠池子分配，
    /// persistent 纹理每帧都会拿到一张新空纹理，画面从第 2 帧起就变黑。
    private var persistentTextures: [TextureHandle: MTLTexture] = [:]
    private var logFrames = 0

    /// 调试期抓帧：抓一帧指定句柄的纹理到指定路径后自动关闭
    struct CaptureRequest {
        let handle: TextureHandle
        let url: URL
    }
    var captureRequest: CaptureRequest?
    private var captureDone = false
    /// 抓帧暂存：帧内 blit 到这里，完成回调再异步回读，
    /// 这样即使目标纹理是「本帧用完就回收」的也可以抓。
    private var captureStaging: MTLTexture?
    private var captureURL: URL?

    init?(nodes: [PipelineNode]) {
        guard let metal = MetalContext() else { return nil }
        self.metal = metal
        self.nodes = nodes
        super.init()
        validate()
    }

    func setNodes(_ nodes: [PipelineNode]) {
        self.nodes = nodes
        persistentTextures.removeAll()
        validate()
    }

    /// 依赖校验：
    /// - 每个输入都必须有生产者
    /// - 生产者晚于消费者时，只允许出现在 `persistent` 纹理上（即合法的反馈边，
    ///   例如时序累积的「上一帧」缓冲）
    private func validate() {
        var producerIndex: [TextureHandle: Int] = [:]
        for (index, node) in nodes.enumerated() {
            guard let out = node.outputHandle else { continue }
            if producerIndex[out] == nil { producerIndex[out] = index }
        }

        for (index, node) in nodes.enumerated() {
            for input in node.inputs {
                guard let producer = producerIndex[input] else {
                    assertionFailure("阶段「\(node.name)」的输入「\(input.name)」没有任何生产者")
                    continue
                }
                if producer > index, !input.spec.persistent {
                    assertionFailure("阶段「\(node.name)」的输入「\(input.name)」由更晚的阶段产出，且不是持久纹理")
                }
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            return
        }

        if logFrames < 3 {
            logFrames += 1
            let detail = nodes.map { node -> String in
                let out = node.outputHandle.map { "\($0.name)(\($0.spec.width)x\($0.spec.height))" } ?? "drawable"
                return "\(node.name)->\(out)"
            }.joined(separator: ", ")
            print("[P1] frame \(stats.frameCount) drawable=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height)) | \(detail)")
        }

        let cpuStart = CACurrentMediaTime()
        let ctx = FrameContext(metal: metal,
                               commandBuffer: commandBuffer,
                               drawableSize: view.drawableSize)

        // 1) 解析纹理（producer 输出 + render stage 输出）
        for node in nodes {
            for handle in node.inputs { resolve(handle, into: ctx) }
            if let out = node.outputHandle { resolve(out, into: ctx) }
        }

        // 2) CPU 生产者先填内容
        for case let producer as TextureProducer in nodes {
            do {
                try producer.produce(ctx, texture: ctx.texture(producer.output))
            } catch {
                print("[Renderer] producer \(producer.name) 失败: \(error)")
            }
        }

        // 3) GPU 阶段按序编码；drawable 的第一次 pass 负责 clear，后续 pass 用 load
        var drawableCleared = false
        for case let stage as RenderStage in nodes {
            let descriptor: MTLRenderPassDescriptor
            if let output = (stage as? OffscreenRenderStage)?.output {
                descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = try? ctx.texture(output)
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].storeAction = .store
                descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            } else {
                descriptor = passDescriptor.copy() as! MTLRenderPassDescriptor
                descriptor.colorAttachments[0].loadAction = drawableCleared ? .load : .clear
                descriptor.colorAttachments[0].storeAction = .store
                descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.06, 0.07, 0.09, 1)
                drawableCleared = true
            }

            stage.prepare(ctx)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { continue }
            encoder.label = stage.name
            do {
                try stage.encode(ctx, encoder: encoder)
            } catch {
                print("[Renderer] stage \(stage.name) 失败: \(error)")
            }
            encoder.endEncoding()
        }

        // 3.5) 调试期抓帧：在帧内把目标纹理拷到 shared 暂存纹理
        if let request = captureRequest, !captureDone,
           let source = try? ctx.texture(request.handle) {
            captureDone = true
            captureURL = request.url

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
                                                                      width: source.width,
                                                                      height: source.height,
                                                                      mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .renderTarget]
            captureStaging = metal.device.makeTexture(descriptor: descriptor)

            if let staging = captureStaging, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                          to: staging, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
        }

        // 4) 非 persistent 纹理在 GPU 用完之后才归还池中，
        //    否则会和仍在 in-flight 的命令缓冲抢同一张纹理。
        // 需要在 GPU 完成后回读的纹理（边缘图 / 分割输入）
        let consumers: [(TextureConsumer, TextureSpec, MTLTexture)] = nodes.compactMap { node in
            guard let consumer = node as? TextureConsumer,
                  let texture = try? ctx.texture(consumer.consumed) else { return nil }
            return (consumer, consumer.consumed.spec, texture)
        }

        let recyclables: [(TextureSpec, MTLTexture)] = nodes.compactMap { node in
            guard let out = node.outputHandle, !out.spec.persistent,
                  let texture = try? ctx.texture(out) else { return nil }
            return (out.spec, texture)
        }

        let cpuSeconds = CACurrentMediaTime() - cpuStart
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }

            // 先做 CPU 回读（纹理仍是 .shared，可直接 getBytes）
            for (consumer, _, texture) in consumers {
                let bytesPerRow = texture.width * 4
                var buffer = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
                buffer.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    texture.getBytes(base, bytesPerRow: bytesPerRow,
                                     from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                                     mipmapLevel: 0)
                    consumer.consume(UnsafeRawBufferPointer(raw),
                                     width: texture.width,
                                     height: texture.height,
                                     bytesPerRow: bytesPerRow)
                }
            }

            for (spec, texture) in recyclables {
                self.metal.texturePool.recycle(spec, texture)
            }

            // 调试期抓帧（只在指定帧做一次）
            if let staging = self.captureStaging, let url = self.captureURL {
                self.captureStaging = nil
                self.captureURL = nil
                // 绝不在这里同步等待：完成回调跑在 Metal 内部线程，
                // 再建命令缓冲 + waitUntilCompleted 会死锁。
                DispatchQueue.global(qos: .utility).async {
                    let ok = FrameCapture.write(staging: staging, to: url)
                    print("[CAPTURE] \(ok ? "已写出" : "写出失败") \(url.path)")
                }
            }
            self.stats.record(gpuSeconds: buffer.gpuEndTime - buffer.gpuStartTime,
                              cpuSeconds: cpuSeconds)
            self.inFlight.signal()
        }
        inFlight.wait()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func resolve(_ handle: TextureHandle, into ctx: FrameContext) {
        if (try? ctx.texture(handle)) != nil { return }

        // persistent：跨帧复用同一张纹理
        if handle.spec.persistent, let existing = persistentTextures[handle] {
            ctx.bind(existing, to: handle)
            return
        }

        guard let texture = metal.texturePool.obtain(handle.spec) else { return }
        if handle.spec.persistent {
            persistentTextures[handle] = texture
        }
        ctx.bind(texture, to: handle)
    }
}

private extension FrameContext {
    func bindIfPresent(_ handle: TextureHandle, _ body: (MTLTexture) -> Void) {
        if let texture = try? self.texture(handle) { body(texture) }
    }
}

/// 简单的帧计时统计，用于 P2 的 30fps 验收。
final class FrameStats {
    private(set) var frameCount = 0
    private(set) var lastGPUMillis: Double = 0
    /// 最近一帧的 CPU 侧耗时（阶段编码 + 提交）
    private(set) var lastFrameMillis: Double = 0
    private var windowStart = CACurrentMediaTime()
    private var windowFrames = 0
    private(set) var fps: Double = 0

    func record(gpuSeconds: CFTimeInterval, cpuSeconds: CFTimeInterval = 0) {
        frameCount += 1
        if cpuSeconds > 0 { lastFrameMillis = cpuSeconds * 1000 }
        windowFrames += 1
        if gpuSeconds > 0 { lastGPUMillis = gpuSeconds * 1000 }
        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        if elapsed >= 1.0 {
            fps = Double(windowFrames) / elapsed
            windowFrames = 0
            windowStart = now
        }
    }
}
