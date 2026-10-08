import Metal

/// 通用「单输入 → 单输出」全屏着色器阶段（`vs_quad` + 指定片元函数）。
///
/// 上游每个 `GLOutputStage` 子类都是同一套骨架，这里收敛成一个类型；
/// 需要多纹理 / 自定义顶点 / viewport 的阶段（如透视校正、遮罩合成）单独实现。
class ShaderPass: OffscreenRenderStage {
    let name: String
    let inputs: [TextureHandle]
    let output: TextureHandle

    private let fragment: String
    private let configure: ((MTLRenderCommandEncoder, FrameContext) throws -> Void)?

    init(name: String,
         fragment: String,
         input: TextureHandle,
         output: TextureHandle,
         configure: ((MTLRenderCommandEncoder, FrameContext) throws -> Void)? = nil) {
        self.name = name
        self.fragment = fragment
        self.inputs = [input]
        self.output = output
        self.configure = configure
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad", fragment: fragment)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        try configure?(encoder, ctx)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
