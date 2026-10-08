import Metal

// MARK: - 分割前处理（segment_preprocess_shader.glsl）

/// 把相机帧缩到分割网络输入尺寸并摆正朝向。
/// 上游把朝向写死在着色器里，这里改为参数（决策 D8）。
final class SegmentationPreprocessStage: OffscreenRenderStage {
    let name = "SegmentationPreprocess"
    let inputs: [TextureHandle]
    let output: TextureHandle

    private var rotation: Float

    init(input: TextureHandle, output: TextureHandle, rotation: Float = 0) {
        self.inputs = [input]
        self.output = output
        self.rotation = rotation
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad",
                                                        fragment: "fs_seg_preprocess")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentBytes(&rotation, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - 分割后处理（segment_postprocess_shader.glsl）

/// 把 mask 转回相机朝向，并把值铺满 RGB 三个通道。
final class SegmentationPostprocessStage: OffscreenRenderStage {
    let name = "SegmentationPostprocess"
    let inputs: [TextureHandle]
    let output: TextureHandle

    private var rotation: Float

    init(input: TextureHandle, output: TextureHandle, rotation: Float = 0) {
        self.inputs = [input]
        self.output = output
        self.rotation = rotation
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad",
                                                        fragment: "fs_seg_postprocess")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentBytes(&rotation, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - 时序累积（segmentation_accumulation_shader.glsl）

/// 「背景稳定度」累积：被遮挡处清零、未遮挡处每帧 +factor。
///
/// 用 A/B 两张持久纹理做乒乓（本次读 A 写 B，紧接着由 `CopyStage` 把 B 写回 A），
/// 避免同一张纹理既读又写。
final class AccumulationStage: OffscreenRenderStage {
    let name = "SegmentationAccumulation"
    let inputs: [TextureHandle]
    let output: TextureHandle

    private var factor: Float
    private var didInitialize = false

    init(mask: TextureHandle, previous: TextureHandle, output: TextureHandle, factor: Float = 0.2) {
        self.inputs = [mask, previous]
        self.output = output
        self.factor = factor
    }

    /// 首帧把「上一帧」纹理清零，否则会采到未初始化内容。
    func prepare(_ ctx: FrameContext) {
        guard !didInitialize, let texture = try? ctx.texture(inputs[1]) else { return }
        didInitialize = true

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        ctx.commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad",
                                                        fragment: "fs_accumulate")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentTexture(try ctx.texture(inputs[1]), index: 1)
        encoder.setFragmentBytes(&factor, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - 遮罩合成（masking_shader.glsl）

/// mask 处取 sampler2，否则取 sampler1。
/// 去遮挡的核心：mask（= 背景已稳定）处用当前帧，人所在处用历史帧。
final class MaskingStage: OffscreenRenderStage {
    let name: String
    let inputs: [TextureHandle]
    let output: TextureHandle

    init(name: String = "Masking",
         sampler1: TextureHandle,
         sampler2: TextureHandle,
         mask: TextureHandle,
         output: TextureHandle) {
        self.name = name
        self.inputs = [sampler1, sampler2, mask]
        self.output = output
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad", fragment: "fs_masking")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentTexture(try ctx.texture(inputs[1]), index: 1)
        encoder.setFragmentTexture(try ctx.texture(inputs[2]), index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - 存储透传（texture.glsl）

/// 把输入写进指定的（持久）输出纹理。
final class CopyStage: OffscreenRenderStage {
    let name: String
    let inputs: [TextureHandle]
    let output: TextureHandle

    init(name: String, input: TextureHandle, output: TextureHandle) {
        self.name = name
        self.inputs = [input]
        self.output = output
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad", fragment: "fs_texture")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
