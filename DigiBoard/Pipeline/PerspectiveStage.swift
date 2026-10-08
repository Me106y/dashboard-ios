import Metal
import simd

/// 透视校正（决策 D5：用 `simd` 自解单应，不依赖 OpenCV）。
///
/// 每帧按当前四角解出「目标 uv → 源 uv」的单应矩阵，片元着色器逐像素查表；
/// 同时按白板包围盒的宽高比设置 viewport，并居中，避免拉伸。
final class PerspectiveStage: OffscreenRenderStage {
    let name = "PerspectiveCorrection"
    let inputs: [TextureHandle]
    let output: TextureHandle

    private let tracker: CornerTracker
    private let sourceSize: SIMD2<Float>

    private var homography = matrix_identity_float3x3
    private var viewport = MTLViewport()

    init(input: TextureHandle, output: TextureHandle, tracker: CornerTracker) {
        self.inputs = [input]
        self.output = output
        self.tracker = tracker
        self.sourceSize = SIMD2<Float>(Float(input.spec.width), Float(input.spec.height))
    }

    private var prepareLogCount = 0

    func prepare(_ ctx: FrameContext) {
        let corners = tracker.corners
        guard corners.count == 4 else { return }
        if prepareLogCount < 3 {
            prepareLogCount += 1
            let text = corners.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ")
            print("[P3] Perspective 使用角点 \(text)  模式=\(tracker.mode.rawValue)")
        }

        // 角点（图像像素，y 向下）-> 源 uv
        let sourceUV = corners.map { SIMD2<Float>($0.x / sourceSize.x, $0.y / sourceSize.y) }

        // 目标 uv 的四角顺序：左上 / 右上 / 右下 / 左下
        let destination: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(1, 1), SIMD2<Float>(0, 1),
        ]
        // tracker 顺序是 [TL, BL, BR, TR]，按目标顺序重排
        let source = [sourceUV[0], sourceUV[3], sourceUV[2], sourceUV[1]]

        if let matrix = Homography.solve(destination: destination, source: source) {
            homography = matrix
        }

        // viewport：按白板包围盒宽高比，居中铺满目标纹理
        let xs = corners.map { $0.x }
        let ys = corners.map { $0.y }
        let boxWidth = max(xs.max()! - xs.min()!, 1)
        let boxHeight = max(ys.max()! - ys.min()!, 1)
        let targetWidth = Float(output.spec.width)
        let targetHeight = Float(output.spec.height)
        let scale = min(targetWidth / boxWidth, targetHeight / boxHeight)
        let width = Double(boxWidth * scale)
        let height = Double(boxHeight * scale)
        viewport = MTLViewport(originX: (Double(targetWidth) - width) / 2,
                               originY: (Double(targetHeight) - height) / 2,
                               width: width,
                               height: height,
                               znear: 0, zfar: 1)
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad",
                                                        fragment: "fs_perspective_lookup")
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        var h = homography
        withUnsafeBytes(of: &h) { raw in
            encoder.setFragmentBytes(raw.baseAddress!,
                                     length: MemoryLayout<simd_float3x3>.stride,
                                     index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
