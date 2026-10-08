import Metal
import QuartzCore
import simd

// MARK: - 着色器参数（内存布局必须与 .metal 中的 struct 一致）

/// 对应 Filters.metal 的 `GaussianParams`（size == 40）
struct GaussianParams {
    var offsets: (Float, Float, Float)
    var weights: (Float, Float, Float)
    var direction: SIMD2<Float>
    var resolution: SIMD2<Float>

    /// Rastergrid 的线性采样优化系数，与上游 GaussianBlurStage 一致
    static let kernelOffsets: (Float, Float, Float) = (0.0, 1.3846153846, 3.2307692308)
    static let kernelWeights: (Float, Float, Float) = (0.2270270270, 0.3162162162, 0.0702702703)
}

/// 对应 Filters.metal 的 `CannyParams`（size == 16）
struct CannyParams {
    var weakThreshold: Float
    var hardThreshold: Float
    var resolution: SIMD2<Float>
}

// MARK: - grayscale_shader.glsl

final class GrayscaleStage: ShaderPass {
    init(name: String = "Grayscale", input: TextureHandle, output: TextureHandle) {
        super.init(name: name, fragment: "fs_grayscale", input: input, output: output)
    }
}

// MARK: - gaussian_shader.glsl（x / y 两趟，对应上游 fullGaussian）

final class GaussianStage: OffscreenRenderStage {
    let name: String
    let inputs: [TextureHandle]
    let output: TextureHandle

    private var params: GaussianParams

    init(name: String, input: TextureHandle, output: TextureHandle, horizontal: Bool) {
        self.name = name
        self.inputs = [input]
        self.output = output
        self.params = GaussianParams(offsets: GaussianParams.kernelOffsets,
                                     weights: GaussianParams.kernelWeights,
                                     direction: horizontal ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1),
                                     resolution: SIMD2<Float>(Float(output.spec.width),
                                                              Float(output.spec.height)))
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad", fragment: "fs_gaussian")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<GaussianParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - sobel_shader.glsl

final class SobelStage: OffscreenRenderStage {
    let name = "Sobel"
    let inputs: [TextureHandle]
    let output: TextureHandle

    private var resolution: SIMD2<Float>

    init(input: TextureHandle, output: TextureHandle) {
        self.inputs = [input]
        self.output = output
        self.resolution = SIMD2<Float>(Float(output.spec.width), Float(output.spec.height))
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad", fragment: "fs_sobel")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - canny_shader.glsl

final class CannyStage: OffscreenRenderStage {
    let name = "Canny"
    let inputs: [TextureHandle]
    let output: TextureHandle

    private var params: CannyParams

    /// 阈值与上游 FullCannyEdgeDetection 一致（0.1 / 0.2）
    init(input: TextureHandle, output: TextureHandle, weak: Float = 0.1, hard: Float = 0.2) {
        self.inputs = [input]
        self.output = output
        self.params = CannyParams(weakThreshold: weak,
                                  hardThreshold: hard,
                                  resolution: SIMD2<Float>(Float(output.spec.width),
                                                           Float(output.spec.height)))
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad", fragment: "fs_canny")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<CannyParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - 角点检测（替代 OpenCVLineDetection + LinesAngleDiscriminator + BiggestQuad + WMA）

/// 读取 Canny 边缘图，在 CPU 侧做霍夫直线 → 角度分组 → 最大四边形 → 平滑，
/// 把结果写进 `CornerTracker`。对应上游 `fullCornerDetection` 那一整条支线。
///
/// 边缘图跑在降采样分辨率上（相机尺寸 / edgeScale），否则纯 Swift 的霍夫变换太慢。
final class CornerDetectionStage: TextureConsumer {
    let name = "CornerDetection"
    let inputs: [TextureHandle]
    var consumed: TextureHandle { inputs[0] }

    private let tracker: CornerTracker
    /// 边缘图尺寸 → 相机尺寸的换算系数
    private let scaleToSource: Float
    private let detectorParams: HoughLineDetector.Parameters

    /// 每 N 帧检测一次（霍夫 + 四边形搜索是 CPU 活）
    var frameInterval = 10
    private var frameCounter = 0

    private let workQueue = DispatchQueue(label: "com.zhuanz.digiboard.corner", qos: .userInitiated)
    private var isBusy = false

    private(set) var lastDetectionMillis: Double = 0
    private(set) var lastLineCount = 0
    private(set) var detectionCount = 0

    init(input: TextureHandle,
         tracker: CornerTracker,
         scaleToSource: Float,
         parameters: HoughLineDetector.Parameters? = nil) {
        self.inputs = [input]
        self.tracker = tracker
        self.scaleToSource = scaleToSource

        // 上游的票数阈值 150 是在全分辨率边缘图上定的；我们在 1/scaleToSource 的
        // 降采样图上跑霍夫，同一条边的像素数按比例变少，阈值必须同步折算，
        // 否则一条直线都投不出来。
        var adjusted = parameters ?? .upstreamDefault
        adjusted.threshold = max(Int(150.0 / Double(max(scaleToSource, 1))), 25)
        // 上游 maxLines = 50，但最大四边形是 n²m² 的四重循环：
        // 50 条直线分成两组后约 39 万次迭代（真机实测 300ms+）。
        // 压到 20 条（约 1 万次迭代）后仍在毫秒级，且霍夫本身按票数排序，
        // 保留的就是最强的那些直线。
        adjusted.maxLines = 20
        self.detectorParams = adjusted
    }

    func consume(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) {
        frameCounter += 1
        guard frameCounter % max(frameInterval, 1) == 0 else { return }
        guard bytesPerRow == width * 4 else { return }
        guard !isBusy else { return }

        // 这份缓冲区随帧复用，必须立刻拷走；重活放到后台队列，
        // 否则霍夫 + 四边形搜索会堵住渲染线程的完成回调（真机实测掉到 17fps）。
        let pixels = [UInt8](bytes)
        isBusy = true
        workQueue.async { [weak self] in
            guard let self else { return }
            self.detect(pixels: pixels, width: width, height: height)
            self.isBusy = false
        }
    }

    private func detect(pixels: [UInt8], width: Int, height: Int) {
        let start = CACurrentMediaTime()

        let lines = HoughLineDetector.detect(edges: pixels,
                                             width: width,
                                             height: height,
                                             parameters: detectorParams)
        lastLineCount = lines.count
        let edgePixels = stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 0 ? 1 : 0) }
        if detectionCount < 3 && frameCounter <= frameInterval {
            print("[P3] 边缘像素 \(edgePixels)/\(width * height)  霍夫直线 \(lines.count) 条")
        }
        guard lines.count >= 2 else { return }

        // 与上游 LinesAngleDiscriminatorStage 相同的两个角度区间
        let groupA = lines.filter { $0.matchesAngleRange(min: -.pi / 4, max: .pi / 4) }
        let groupB = lines.filter { $0.matchesAngleRange(min: .pi / 4, max: 3 * .pi / 4) }

        if detectionCount < 3 && frameCounter <= frameInterval {
            print("[P3] 角度分组：A=\(groupA.count) B=\(groupB.count)")
        }

        if let quad = BiggestQuadFinder.find(horizontal: groupA, vertical: groupB, fallback: []) {
            let scaled = quad.map { $0 * scaleToSource }
            tracker.updateAuto(scaled)
            detectionCount += 1
            if detectionCount <= 3 {
                let text = scaled.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ")
                print("[P3] 检测到白板四角 \(text)")
            }
        }
        lastDetectionMillis = (CACurrentMediaTime() - start) * 1000
    }
}
