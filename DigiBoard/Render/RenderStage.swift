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
}

/// GPU 渲染阶段：每个阶段 = 一个着色器（与上游「一个 Stage 一个 program」一一对应）。
protocol RenderStage: PipelineNode {
    /// nil 表示直接绘制到 drawable。
    var output: TextureHandle? { get }
    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws
}

/// CPU 侧纹理生产者：图像上传、Core ML 推理结果回填等。必定产出纹理。
protocol TextureProducer: PipelineNode {
    var output: TextureHandle { get }
    func produce(_ ctx: FrameContext, texture: MTLTexture) throws
}

extension PipelineNode {
    /// 本节点产出的纹理句柄：producer 必定有；render stage 可能是 nil（= drawable）。
    var outputHandle: TextureHandle? {
        if let producer = self as? TextureProducer { return producer.output }
        if let stage = self as? RenderStage { return stage.output }
        return nil
    }
}
