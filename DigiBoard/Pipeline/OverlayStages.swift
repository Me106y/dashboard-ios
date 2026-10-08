import Metal
import simd

/// 角点手柄可视化 + 四边形边框。
///
/// **这是相对上游的一处有意改进**：上游 `DraggablePointsStage` 只持有四个点、
/// 完全不绘制，手动模式属于"盲拖"。iOS 版复用 `corner_shader` / `line_shader`
/// 的思路把手柄画出来。
final class CornerOverlayStage: DrawableRenderStage {
    let name = "CornerOverlay"
    let inputs: [TextureHandle] = []

    private let tracker: CornerTracker
    private let sourceSize: CGSize
    private var handles = true
    private var outline = true
    private var handleSizePixels: Float = 48

    init(tracker: CornerTracker, sourceSize: CGSize) {
        self.tracker = tracker
        self.sourceSize = sourceSize
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let corners = tracker.corners
        guard corners.count == 4 else { return }

        let rect = DisplayGeometry.fitRect(sourceSize: sourceSize,
                                           drawableSize: ctx.drawableSize,
                                           inset: 0.02)
        let ndc = corners.map {
            DisplayGeometry.toNDC(point: $0, sourceSize: sourceSize, in: rect)
        }

        // 边框
        if outline {
            let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_segment",
                                                            fragment: "fs_color")
            encoder.setRenderPipelineState(pipeline)
            var color = SIMD4<Float>(1, 1, 1, 0.85)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

            for i in 0..<4 {
                var params = SegmentParams(a: ndc[i],
                                           b: ndc[(i + 1) % 4],
                                           resolution: SIMD2<Float>(Float(ctx.drawableSize.width),
                                                                    Float(ctx.drawableSize.height)),
                                           thickness: 2)
                encoder.setVertexBytes(&params, length: MemoryLayout<SegmentParams>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        // 手柄
        if handles {
            let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_corner",
                                                            fragment: "fs_corner")
            encoder.setRenderPipelineState(pipeline)
            let half = handleSizePixels / 2
            for point in ndc {
                let cx = (point.x + 1) / 2 * Float(ctx.drawableSize.width)
                let cy = (point.y + 1) / 2 * Float(ctx.drawableSize.height)
                var params = SIMD4<Float>(
                    (cx - half) / Float(ctx.drawableSize.width) * 2 - 1,
                    (cy - half) / Float(ctx.drawableSize.height) * 2 - 1,
                    handleSizePixels / Float(ctx.drawableSize.width) * 2,
                    handleSizePixels / Float(ctx.drawableSize.height) * 2
                )
                encoder.setVertexBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
    }
}

/// 与 Blit.metal 的 `SegmentParams` 对应
struct SegmentParams {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var resolution: SIMD2<Float>
    var thickness: Float
}
