import CoreGraphics
import Metal

/// 整条管线的句柄集合。所有阶段都通过这些句柄显式连边（决策 D13）。
struct PipelineHandles {
    let camera: TextureHandle
    let segmentInput: TextureHandle
    let mask: TextureHandle
    let maskDilated: TextureHandle
    let accumulatorA: TextureHandle
    let accumulatorB: TextureHandle
    let maskPost: TextureHandle
    let cleaned: TextureHandle
    let stored: TextureHandle
    let wbBackground: TextureHandle
    let whitebalanced: TextureHandle
    let binSmall: TextureHandle
    let binSmallGray: TextureHandle
    let grayFull: TextureHandle
    let binarized: TextureHandle
    let saturated: TextureHandle
    let final: TextureHandle

    /// 逐级调试视图可选的所有中间结果（顺序即切换顺序）
    var debugSequence: [TextureHandle] {
        [final, cleaned, maskPost, mask, maskDilated, segmentInput, camera,
         whitebalanced, binarized, saturated, binSmallGray]
    }
}

struct FullPipeline {
    let nodes: [PipelineNode]
    let handles: PipelineHandles
    let present: PresentStage
    let segmentation: SegmentationStage
}

enum PipelineBuilder {
    /// 输入 —— 分割 → 时序累积去遮挡 → 图像增强 —— 输出。
    ///
    /// 需求变更：不再做角点检测与透视校正（那部分代码已删除），
    /// 管线在「去遮挡后的画面」上直接做增强。
    static func build(source: FrameSource,
                      sourceSize: CGSize,
                      provider: SegmentationProvider) -> FullPipeline {
        let width = Int(sourceSize.width)
        let height = Int(sourceSize.height)
        let segWidth = provider.inputWidth
        let segHeight = provider.inputHeight

        func rgba(_ w: Int, _ h: Int, persistent: Bool = false, cpu: Bool = false) -> TextureSpec {
            TextureSpec(width: w, height: h, pixelFormat: .rgba8Unorm,
                        persistent: persistent, renderTarget: !cpu, cpuWritable: cpu)
        }

        // 句柄
        let camera = TextureHandle("source.frame", rgba(width, height, persistent: true))
        let segmentInput = TextureHandle("segment.input",
                                         rgba(segWidth, segHeight, persistent: true, cpu: true))
        let mask = TextureHandle("segment.mask",
                                 TextureSpec(width: segWidth, height: segHeight,
                                             pixelFormat: .r8Unorm, persistent: true,
                                             renderTarget: false, cpuWritable: true))
        let maskDilated = TextureHandle("segment.maskDilated",
                                        TextureSpec(width: segWidth, height: segHeight,
                                                    pixelFormat: .r8Unorm, persistent: false,
                                                    renderTarget: true, cpuWritable: false))
        let accA = TextureHandle("segment.accA", rgba(segWidth, segHeight, persistent: true))
        let accB = TextureHandle("segment.accB", rgba(segWidth, segHeight, persistent: true))
        let maskPost = TextureHandle("segment.post", rgba(width, height))
        let cleaned = TextureHandle("segmentation.cleaned", rgba(width, height))
        let stored = TextureHandle("segmentation.stored", rgba(width, height, persistent: true))

        let wbBackground = TextureHandle("enhance.wbBackground",
                                         rgba(max(width / 32, 8), max(height / 32, 8)))
        let whitebalanced = TextureHandle("enhance.whitebalanced", rgba(width, height))
        let binSmall = TextureHandle("enhance.binSmall", rgba(max(width / 8, 16), max(height / 8, 8)))
        let binSmallGray = TextureHandle("enhance.binSmallGray",
                                         rgba(max(width / 8, 16), max(height / 8, 8)))
        let grayFull = TextureHandle("enhance.grayFull", rgba(width, height))
        let binarized = TextureHandle("enhance.binarized", rgba(width, height))
        let saturated = TextureHandle("enhance.saturated", rgba(width, height))
        let final = TextureHandle("enhance.final", rgba(width, height, persistent: true))

        var nodes: [PipelineNode] = []

        // ── 输入
        nodes.append(SourceStage(source: source, output: camera))

        // ── 分割 → 时序累积 → 去遮挡
        nodes.append(SegmentationPreprocessStage(input: camera, output: segmentInput))
        let segmentation = SegmentationStage(provider: provider, input: segmentInput, output: mask)
        nodes.append(segmentation)
        // 掩膜膨胀（上游 OpenCVDilateStage 的 5×5 矩形核）。
        //
        // 注意：上游的膨胀只用来抹掉分割模型的边界误差——因为它是**同步推理、
        // mask 零帧滞后**。而本移植的分割走后台队列，mask 实测滞后 1 帧，
        // 人一帧移动 1.5~3.2px（256 尺度），仅 2px 的膨胀盖不住，
        // 前缘像素会被当成"背景稳定"而把人的边缘写进历史，叠出梳齿状残影。
        // 因此半径按「滞后 1 帧 × 帧间位移」放大到 5px。
        nodes.append(DilateStage(input: mask, output: maskDilated, radius: 5))
        nodes.append(AccumulationStage(mask: maskDilated, previous: accA, output: accB, factor: 0.2))
        nodes.append(CopyStage(name: "AccumulationStore", input: accB, output: accA))
        nodes.append(SegmentationPostprocessStage(input: accB, output: maskPost))
        // 核心一步：mask（背景已稳定）处用当前帧，人所在处用历史帧
        nodes.append(MaskingStage(name: "OcclusionRemoval",
                                  sampler1: stored, sampler2: camera,
                                  mask: maskPost, output: cleaned))
        nodes.append(CopyStage(name: "StoredStore", input: cleaned, output: stored))

        // ── 图像增强
        nodes.append(ScaleStage(name: "WBDownscale", input: cleaned, output: wbBackground))
        nodes.append(WhitebalanceStage(raw: cleaned, background: wbBackground, output: whitebalanced))
        nodes.append(ScaleStage(name: "BinarizeDownscale", input: cleaned, output: binSmall))
        nodes.append(GrayscaleStage(name: "BinarizeGraySmall", input: binSmall, output: binSmallGray))
        nodes.append(GrayscaleStage(name: "BinarizeGrayFull", input: cleaned, output: grayFull))
        nodes.append(BinarizationFastStage(gray: grayFull, downscaled: binSmallGray,
                                           output: binarized, threshold: 7.5))
        nodes.append(SaturateStage(input: whitebalanced, output: saturated, gain: 4.5))
        nodes.append(makeColorAddStage(colours: saturated, binarized: binarized, output: final))

        // ── 输出
        let handles = PipelineHandles(camera: camera, segmentInput: segmentInput, mask: mask,
                                      maskDilated: maskDilated, accumulatorA: accA, accumulatorB: accB, maskPost: maskPost,
                                      cleaned: cleaned, stored: stored,
                                      wbBackground: wbBackground, whitebalanced: whitebalanced,
                                      binSmall: binSmall, binSmallGray: binSmallGray,
                                      grayFull: grayFull, binarized: binarized,
                                      saturated: saturated, final: final)

        let present = PresentStage(selectable: handles.debugSequence, sourceSize: sourceSize)
        nodes.append(present)

        return FullPipeline(nodes: nodes, handles: handles, present: present,
                            segmentation: segmentation)
    }
}
