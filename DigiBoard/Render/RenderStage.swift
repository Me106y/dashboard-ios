import Metal

/// 一帧的上下文：命令缓冲 + 纹理解析结果。
final class FrameContext {
    let metal: MetalContext
    let commandBuffer: MTLCommandBuffer
    let drawableSize: CGSize
    private var resolved: [TextureHandle: MTLTexture] = [:]

    init(metal: MetalContext, commandBuffer: MTLCommandBuffer, drawableSize: CGSize) {
        self.metal = metal
        self.commandBuffer = commandBuffer
        self.drawableSize = drawableSize
    }

    func bind(_ texture: MTLTexture, to handle: TextureHandle) {
        resolved[handle] = texture
    }

    func texture(_ handle: TextureHandle) throws -> MTLTexture {
        guard let tex = resolved[handle] else { throw MetalError.noTexture(handle.name) }
        return tex
    }
}

/// 管线节点：显式声明输入（决策 D13：依赖靠声明，不靠构造顺序）。
protocol PipelineNode: AnyObject {
    var name: String { get }
    var inputs: [TextureHandle] { get }

    /// 阶段编码前的准备工作（例如计算单应矩阵、首帧清零持久纹理）。
    /// 由 Renderer 在创建该阶段的 encoder 之前调用，此时没有未关闭的 encoder。
    ///
    /// 注意：这里必须是**协议要求**而不是只有扩展里的默认实现。
    /// 若只写在扩展里，`stage.prepare(ctx)` 会走静态派发，
    /// 子类的具体实现永远不会被调用（透视矩阵会一直是单位矩阵）。
    func prepare(_ ctx: FrameContext)
}

extension PipelineNode {
    func prepare(_ ctx: FrameContext) {}
}

/// GPU 渲染阶段：每个阶段 = 一个着色器（与上游「一个 Stage 一个 program」一一对应）。
protocol RenderStage: PipelineNode {
    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws
}

/// 渲染到一张离屏纹理的阶段。
protocol OffscreenRenderStage: RenderStage {
    var output: TextureHandle { get }
}

/// 直接绘制到 drawable 的阶段（上屏、角点手柄叠加）。
protocol DrawableRenderStage: RenderStage {}

/// CPU 侧纹理生产者：图像上传、Core ML 推理结果回填等。必定产出纹理。
protocol TextureProducer: PipelineNode {
    var output: TextureHandle { get }
    func produce(_ ctx: FrameContext, texture: MTLTexture) throws
}

/// 需要在 GPU 完成后读取纹理内容做 CPU 处理的节点。
/// 输入纹理必须是 `cpuWritable`（.shared 存储），否则无法回读。
protocol TextureConsumer: PipelineNode {
    /// 被读取的纹理句柄
    var consumed: TextureHandle { get }
    func consume(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int)
}

extension PipelineNode {
    /// 本节点产出的纹理句柄：producer 必定有；render stage 可能是 nil（= drawable）。
    var outputHandle: TextureHandle? {
        if let producer = self as? TextureProducer { return producer.output }
        if let stage = self as? OffscreenRenderStage { return stage.output }
        return nil
    }
}
