import Metal
import simd

/// 把一个输入纹理绘制到 drawable 的指定区域（归一化坐标，原点左下）。
/// 对应上游把阶段输出送上屏幕的那一步；也用于逐级调试视图。
final class BlitStage: DrawableRenderStage {
    let name: String
    let inputs: [TextureHandle]
    /// nil = 直接绘制到 drawable

    private let source: TextureHandle
    /// 归一化目标区域（0..1，原点左下）
    var destinationRect: CGRect
    /// 单通道纹理需要转灰度显示，否则采样结果只有红通道有值
    var grayscale = false
    /// 是否在目标区域内保持源纹理宽高比
    var fitAspect = true

    init(name: String,
         source: TextureHandle,
         destinationRect: CGRect,
         grayscale: Bool = false) {
        self.name = name
        self.source = source
        self.inputs = [source]
        self.destinationRect = destinationRect
        self.grayscale = grayscale
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let fragment = grayscale ? "blit_fragment_gray" : "blit_fragment"
        let pipeline = try ctx.metal.renderPipelineState(vertex: "blit_vertex",
                                                        fragment: fragment)
        encoder.setRenderPipelineState(pipeline)

        let texture = try ctx.texture(source)
        let rect = resolvedRect(drawableSize: ctx.drawableSize, texture: texture)

        // 归一化坐标 -> NDC
        var rectNDC = SIMD4<Float>(
            Float(rect.minX * 2 - 1),
            Float(rect.minY * 2 - 1),
            Float(rect.width * 2),
            Float(rect.height * 2)
        )
        encoder.setVertexBytes(&rectNDC, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 在目标区域内按源纹理宽高比缩放并居中。
    private func resolvedRect(drawableSize: CGSize, texture: MTLTexture) -> CGRect {
        guard fitAspect, texture.width > 0, texture.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else {
            return destinationRect
        }
        let panelW = destinationRect.width * drawableSize.width
        let panelH = destinationRect.height * drawableSize.height
        let scale = min(panelW / CGFloat(texture.width), panelH / CGFloat(texture.height))
        let fittedW = CGFloat(texture.width) * scale / drawableSize.width
        let fittedH = CGFloat(texture.height) * scale / drawableSize.height
        return CGRect(x: destinationRect.midX - fittedW / 2,
                      y: destinationRect.midY - fittedH / 2,
                      width: fittedW,
                      height: fittedH)
    }
}
