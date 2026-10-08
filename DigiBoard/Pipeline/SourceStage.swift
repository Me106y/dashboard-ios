import Metal

/// 把帧源（相机或离线视频）搬进管线纹理。
///
/// 需求变更后管线不再区分两者：它们都实现 `FrameSource`，
/// 视频源在 `advance()` 里解码下一帧，相机源是实时的、推进为空操作。
final class SourceStage: OffscreenRenderStage {
    let name = "Source"
    let inputs: [TextureHandle] = []
    let output: TextureHandle

    private let source: FrameSource
    private var flipY: Float = 0

    init(source: FrameSource, output: TextureHandle) {
        self.source = source
        self.output = output
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        source.advance()
        guard let sourceTexture = source.currentTexture else { return }

        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad", fragment: "fs_camera")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentBytes(&flipY, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
