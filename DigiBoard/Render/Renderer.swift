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
    private let stats = FrameStats()

    /// 跨帧保留的纹理（persistent 句柄 -> 纹理）。
    ///
    /// 必须由 Renderer 持有：`FrameContext` 每帧重建，若只靠池子分配，
    /// persistent 纹理每帧都会拿到一张新空纹理，画面从第 2 帧起就变黑。
    private var persistentTextures: [TextureHandle: MTLTexture] = [:]
    private var logFrames = 0

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

    /// 依赖校验：每个节点声明的输入必须由更早的节点输出。
    private func validate() {
        var available = Set<TextureHandle>()
        for node in nodes {
            for input in node.inputs where !available.contains(input) {
                assertionFailure("阶段「\(node.name)」的输入「\(input.name)」没有任何更早的阶段产出")
            }
            if let out = node.outputHandle { available.insert(out) }
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
            if let output = stage.output {
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

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { continue }
            encoder.label = stage.name
            do {
                try stage.encode(ctx, encoder: encoder)
            } catch {
                print("[Renderer] stage \(stage.name) 失败: \(error)")
            }
            encoder.endEncoding()
        }

        // 4) 非 persistent 纹理在 GPU 用完之后才归还池中，
        //    否则会和仍在 in-flight 的命令缓冲抢同一张纹理。
        let recyclables: [(TextureSpec, MTLTexture)] = nodes.compactMap { node in
            guard let out = node.outputHandle, !out.spec.persistent,
                  let texture = try? ctx.texture(out) else { return nil }
            return (out.spec, texture)
        }

        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            for (spec, texture) in recyclables {
                self.metal.texturePool.recycle(spec, texture)
            }
            self.stats.record(gpuSeconds: buffer.gpuEndTime - buffer.gpuStartTime)
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
    private var windowStart = CACurrentMediaTime()
    private var windowFrames = 0
    private(set) var fps: Double = 0

    func record(gpuSeconds: CFTimeInterval) {
        frameCount += 1
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
