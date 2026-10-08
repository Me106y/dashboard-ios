import CoreGraphics
import Metal

/// 整条管线的句柄集合。所有阶段都通过这些句柄显式连边（决策 D13）。
struct PipelineHandles {
    let camera: TextureHandle
    let segmentInput: TextureHandle
    let mask: TextureHandle
    let accumulatorA: TextureHandle
    let accumulatorB: TextureHandle
    let maskPost: TextureHandle
    let cleaned: TextureHandle
    let stored: TextureHandle
    let edgeSmall: TextureHandle
    let grayscale: TextureHandle
    let blurX: TextureHandle
    let blurY: TextureHandle
    let sobel: TextureHandle
    let canny: TextureHandle
    let rectified: TextureHandle
    let wbBackground: TextureHandle
    let whitebalanced: TextureHandle
    let binSmall: TextureHandle
    let binSmallGray: TextureHandle
    let grayFull: TextureHandle
    let binarized: TextureHandle
    let saturated: TextureHandle
    let final: TextureHandle

    /// 逐级调试视图可选的所有中间结果（顺序即点击切换顺序）
    var debugSequence: [TextureHandle] {
        [final, cleaned, maskPost, mask, segmentInput, camera,
         canny, rectified, whitebalanced, binarized, saturated, grayscale]
    }
}

struct FullPipeline {
    let nodes: [PipelineNode]
    let handles: PipelineHandles
    let present: PresentStage
    let overlay: CornerOverlayStage
    let segmentation: SegmentationStage
    let cornerDetection: CornerDetectionStage
}

enum PipelineBuilder {
    /// 相机帧尺寸 / edgeScale = 边缘检测所用分辨率。
    /// 霍夫变换是纯 Swift 的 CPU 实现，必须在降采样图上跑（这是相对上游的性能性偏离）。
    static let edgeScale = 4

    static func build(source: FrameSource,
                      cameraSize: CGSize,
                      tracker: CornerTracker,
                      provider: SegmentationProvider) -> FullPipeline {
        let width = Int(cameraSize.width)
        let height = Int(cameraSize.height)
        let segWidth = provider.inputWidth
        let segHeight = provider.inputHeight
        let edgeWidth = max(width / edgeScale, 64)
        let edgeHeight = max(height / edgeScale, 36)

        func rgba(_ w: Int, _ h: Int, persistent: Bool = false, cpu: Bool = false) -> TextureSpec {
            TextureSpec(width: w, height: h, pixelFormat: .rgba8Unorm,
                        persistent: persistent, renderTarget: !cpu, cpuWritable: cpu)
        }

        // 句柄
        let camera = TextureHandle("camera", rgba(width, height, persistent: true))
        let segmentInput = TextureHandle("segment.input", rgba(segWidth, segHeight, persistent: true, cpu: true))
        let mask = TextureHandle("segment.mask", TextureSpec(width: segWidth, height: segHeight,
                                                             pixelFormat: .r8Unorm, persistent: true,
                                                             renderTarget: false, cpuWritable: true))
        let accA = TextureHandle("segment.accA", rgba(segWidth, segHeight, persistent: true))
        let accB = TextureHandle("segment.accB", rgba(segWidth, segHeight, persistent: true))
        let maskPost = TextureHandle("segment.post", rgba(width, height))
        let cleaned = TextureHandle("segmentation.cleaned", rgba(width, height))
        let stored = TextureHandle("segmentation.stored", rgba(width, height, persistent: true))

        let edgeSmall = TextureHandle("edge.small", rgba(edgeWidth, edgeHeight))
        let grayscale = TextureHandle("edge.gray", rgba(edgeWidth, edgeHeight))
        let blurX = TextureHandle("edge.blurX", rgba(edgeWidth, edgeHeight))
        let blurY = TextureHandle("edge.blurY", rgba(edgeWidth, edgeHeight))
        let sobel = TextureHandle("edge.sobel", rgba(edgeWidth, edgeHeight))
        let canny = TextureHandle("edge.canny", rgba(edgeWidth, edgeHeight, persistent: true, cpu: true))

        let rectified = TextureHandle("perspective.rectified", rgba(width, height))
        let wbBackground = TextureHandle("enhance.wbBackground", rgba(max(width / 32, 8), max(height / 32, 8)))
        let whitebalanced = TextureHandle("enhance.whitebalanced", rgba(width, height))
        let binSmall = TextureHandle("enhance.binSmall", rgba(max(width / 8, 16), max(height / 8, 8)))
        let binSmallGray = TextureHandle("enhance.binSmallGray", rgba(max(width / 8, 16), max(height / 8, 8)))
        let grayFull = TextureHandle("enhance.grayFull", rgba(width, height))
        let binarized = TextureHandle("enhance.binarized", rgba(width, height))
        let saturated = TextureHandle("enhance.saturated", rgba(width, height))
        let final = TextureHandle("enhance.final", rgba(width, height))

        var nodes: [PipelineNode] = []

        // ── 输入
        nodes.append(CameraStage(source: source, output: camera))

        // ── P2：分割 → 时序累积 → 去遮挡
        nodes.append(SegmentationPreprocessStage(input: camera, output: segmentInput))
        let segmentation = SegmentationStage(provider: provider, input: segmentInput, output: mask)
        nodes.append(segmentation)
        nodes.append(AccumulationStage(mask: mask, previous: accA, output: accB, factor: 0.2))
        nodes.append(CopyStage(name: "AccumulationStore", input: accB, output: accA))
        nodes.append(SegmentationPostprocessStage(input: accB, output: maskPost))
        // 核心一步：mask（背景已稳定）处用当前帧，人所在处用历史帧
        nodes.append(MaskingStage(name: "OcclusionRemoval",
                                  sampler1: stored, sampler2: camera,
                                  mask: maskPost, output: cleaned))
        nodes.append(CopyStage(name: "StoredStore", input: cleaned, output: stored))

        // ── P3：自动角点检测（跑在降采样的边缘图上）
        nodes.append(ScaleStage(name: "EdgeDownscale", input: cleaned, output: edgeSmall))
        nodes.append(GrayscaleStage(input: edgeSmall, output: grayscale))
        nodes.append(GaussianStage(name: "GaussianX", input: grayscale, output: blurX, horizontal: true))
        nodes.append(GaussianStage(name: "GaussianY", input: blurX, output: blurY, horizontal: false))
        nodes.append(SobelStage(input: blurY, output: sobel))
        nodes.append(CannyStage(input: sobel, output: canny))
        let cornerDetection = CornerDetectionStage(input: canny,
                                                   tracker: tracker,
                                                   scaleToSource: Float(edgeScale))
        nodes.append(cornerDetection)

        // ── P3：透视校正
        nodes.append(PerspectiveStage(input: cleaned, output: rectified, tracker: tracker))

        // ── P4：图像增强
        nodes.append(ScaleStage(name: "WBDownscale", input: rectified, output: wbBackground))
        nodes.append(WhitebalanceStage(raw: rectified, background: wbBackground, output: whitebalanced))
        nodes.append(ScaleStage(name: "BinarizeDownscale", input: rectified, output: binSmall))
        nodes.append(GrayscaleStage(name: "BinarizeGraySmall", input: binSmall, output: binSmallGray))
        nodes.append(GrayscaleStage(name: "BinarizeGrayFull", input: rectified, output: grayFull))
        nodes.append(BinarizationFastStage(gray: grayFull, downscaled: binSmallGray,
                                           output: binarized, threshold: 7.5))
        nodes.append(SaturateStage(input: whitebalanced, output: saturated, gain: 4.5))
        nodes.append(makeColorAddStage(colours: saturated, binarized: binarized, output: final))

        // ── 输出：上屏 + 角点手柄
        let handles = PipelineHandles(camera: camera, segmentInput: segmentInput, mask: mask,
                                      accumulatorA: accA, accumulatorB: accB, maskPost: maskPost,
                                      cleaned: cleaned, stored: stored,
                                      edgeSmall: edgeSmall, grayscale: grayscale,
                                      blurX: blurX, blurY: blurY, sobel: sobel, canny: canny,
                                      rectified: rectified, wbBackground: wbBackground,
                                      whitebalanced: whitebalanced, binSmall: binSmall,
                                      binSmallGray: binSmallGray, grayFull: grayFull,
                                      binarized: binarized, saturated: saturated, final: final)

        let present = PresentStage(selectable: handles.debugSequence, sourceSize: cameraSize)
        nodes.append(present)

        let overlay = CornerOverlayStage(tracker: tracker, sourceSize: cameraSize)
        nodes.append(overlay)

        return FullPipeline(nodes: nodes, handles: handles, present: present,
                            overlay: overlay, segmentation: segmentation,
                            cornerDetection: cornerDetection)
    }
}
