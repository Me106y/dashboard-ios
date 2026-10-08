import Metal

/// 上屏：把当前选中的纹理等比铺满 drawable。
/// 通过切换 `selectedIndex` 实现上游 `DrawPipelineStage` 的「逐级查看中间结果」调试能力。
final class PresentStage: DrawableRenderStage {
    let name = "Present"
    let inputs: [TextureHandle]

    /// 可逐级查看的阶段输出（第一个是最终结果）
    private(set) var selectable: [TextureHandle]
    private var index = 0

    private let sourceSize: CGSize
    private let inset: CGFloat

    var current: TextureHandle { selectable[index] }

    init(selectable: [TextureHandle], sourceSize: CGSize, inset: CGFloat = 0.02) {
        self.selectable = selectable
        self.inputs = selectable
        self.sourceSize = sourceSize
        self.inset = inset
    }

    func select(index newIndex: Int) {
        guard !selectable.isEmpty else { return }
        index = ((newIndex % selectable.count) + selectable.count) % selectable.count
    }

    func next() { select(index: index + 1) }

    var selectedIndex: Int { index }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let texture = try ctx.texture(current)
        let rect = DisplayGeometry.fitRect(sourceSize: sourceSize,
                                           drawableSize: ctx.drawableSize,
                                           inset: inset)
        // 单通道纹理（分割 mask / 边缘图）需要走灰度片元，否则只会显示红通道
        let fragment = texture.pixelFormat == .r8Unorm ? "fs_blit_gray" : "fs_blit"
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_blit", fragment: fragment)
        encoder.setRenderPipelineState(pipeline)

        var ndc = SIMD4<Float>(Float(rect.minX * 2 - 1),
                               Float(rect.minY * 2 - 1),
                               Float(rect.width * 2),
                               Float(rect.height * 2))
        encoder.setVertexBytes(&ndc, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
