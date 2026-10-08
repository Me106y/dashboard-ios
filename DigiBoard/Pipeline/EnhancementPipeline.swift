import Metal
import simd

// MARK: - 缩放到指定分辨率（替代上游 ScaleToResolutionStage / GenerateMipmapStage）

/// 上游用 `glGenerateMipmap` + 双线性降采样保证质量；iOS 侧直接用线性采样的
/// 全屏 pass 完成降采样，画质差异在后续二值化里不可见，但少了一层 mipmap 维护。
final class ScaleStage: ShaderPass {
    init(name: String, input: TextureHandle, output: TextureHandle) {
        super.init(name: name, fragment: "fs_texture", input: input, output: output)
    }
}

// MARK: - whitebalance_shader.glsl

final class WhitebalanceStage: OffscreenRenderStage {
    let name = "Whitebalance"
    let inputs: [TextureHandle]
    let output: TextureHandle

    init(raw: TextureHandle, background: TextureHandle, output: TextureHandle) {
        self.inputs = [raw, background]
        self.output = output
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad",
                                                        fragment: "fs_whitebalance")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentTexture(try ctx.texture(inputs[1]), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - binarization_fast_shader.glsl

final class BinarizationFastStage: OffscreenRenderStage {
    let name = "BinarizationFast"
    let inputs: [TextureHandle]
    let output: TextureHandle

    private var threshold: Float

    /// 阈值与上游 FullImageEnhancement 一致（7.5）
    init(gray: TextureHandle, downscaled: TextureHandle, output: TextureHandle, threshold: Float = 7.5) {
        self.inputs = [gray, downscaled]
        self.output = output
        self.threshold = threshold
    }

    func encode(_ ctx: FrameContext, encoder: MTLRenderCommandEncoder) throws {
        let pipeline = try ctx.metal.renderPipelineState(vertex: "vs_quad",
                                                        fragment: "fs_binarize_fast")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(try ctx.texture(inputs[0]), index: 0)
        encoder.setFragmentTexture(try ctx.texture(inputs[1]), index: 1)
        encoder.setFragmentBytes(&threshold, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

// MARK: - saturate_shader.glsl（HSVAdjustmentsStage）

final class SaturateStage: ShaderPass {
    /// 上游把饱和度放大写死为 4.5
    init(input: TextureHandle, output: TextureHandle, gain: Float = 4.5) {
        var gain = gain
        super.init(name: "Saturate", fragment: "fs_saturate", input: input, output: output) { encoder, _ in
            encoder.setFragmentBytes(&gain, length: MemoryLayout<Float>.stride, index: 0)
        }
    }
}

// MARK: - addColour：把二值化结果与上色结果合成

/// 对应上游 `stage_combinations/AddColour.kt`：
/// `MaskingStage(colours = HSVAdjustmentsStage(白平衡结果), mask = 二值化结果)`，
/// 即笔画处保留二值化、其余保留颜色。
func makeColorAddStage(colours: TextureHandle,
                       binarized: TextureHandle,
                       output: TextureHandle) -> RenderStage {
    MaskingStage(name: "AddColour", sampler1: colours, sampler2: binarized,
                 mask: binarized, output: output)
}
