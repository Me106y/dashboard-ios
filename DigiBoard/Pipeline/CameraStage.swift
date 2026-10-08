import Metal

/// 把相机帧搬进管线纹理。
/// 对应上游 `CameraXStage`（CameraX + OES 外部纹理）；iOS 侧用的是
/// `CVMetalTextureCache` 的 BGRA 纹理，因此这里只做一次可选翻转。
final class CameraStage: OffscreenRenderStage {
    let name = "Camera"
    let inputs: [TextureHandle] = []
    let output: TextureHandle

    private let source: FrameSource
    private var flipY: Float = 0

    /// 必须复用管线里已经建好的句柄，否则下游阶段引用的句柄没有任何生产者
    init(source: FrameSource, output: TextureHandle) {
        self.source = source
        self.output = output
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        guard let cameraTexture = source.currentTexture else { return }

        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad", fragment: "fs_camera")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(cameraTexture, index: 0)
        encoder.setFragmentBytes(&flipY, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
