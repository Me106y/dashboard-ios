//  分割相关阶段
//  对应上游 res/raw/{segment_preprocess_shader, segment_postprocess_shader,
//                     segmentation_accumulation_shader, masking_shader}.glsl
#include <metal_stdlib>
using namespace metal;

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler kSegSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// 与 K 一致的旋转辅助：rotation ∈ {0, 90, 180, 270}
static inline float2 rotateUV(float2 uv, float rotation) {
    if (rotation < 45.0)        { return uv; }                                  // 0°
    if (rotation < 135.0)       { return float2(1.0 - uv.y, uv.x); }            // 90°
    if (rotation < 225.0)       { return float2(1.0 - uv.x, 1.0 - uv.y); }      // 180°
    return float2(uv.y, 1.0 - uv.x);                                            // 270°
}

static inline float2 inverseRotateUV(float2 uv, float rotation) {
    if (rotation < 45.0)  { return uv; }
    if (rotation < 135.0) { return float2(uv.y, 1.0 - uv.x); }
    if (rotation < 225.0) { return float2(1.0 - uv.x, 1.0 - uv.y); }
    return float2(1.0 - uv.y, uv.x);
}

// MARK: - segment_preprocess_shader.glsl
// 上游这里写死了右横屏的朝向（注释里挂着 TODO），iOS 版改为动态旋转参数。
fragment float4 fs_seg_preprocess(QuadOut in [[stage_in]],
                                  texture2d<float> framebuffer [[texture(0)]],
                                  constant float &rotation [[buffer(0)]]) {
    return framebuffer.sample(kSegSampler, rotateUV(in.uv, rotation));
}

// MARK: - segment_postprocess_shader.glsl
// 朝向转回，并把结果放进 RGB 三个通道（上游的 `.xxx`）
fragment float4 fs_seg_postprocess(QuadOut in [[stage_in]],
                                   texture2d<float> framebuffer [[texture(0)]],
                                   constant float &rotation [[buffer(0)]]) {
    float v = framebuffer.sample(kSegSampler, inverseRotateUV(in.uv, rotation)).r;
    return float4(v, v, v, 1.0);
}

// MARK: - segmentation_accumulation_shader.glsl
// 「背景稳定度」累积：被遮挡处清零，未遮挡处每帧 +factor。
// 上游读的是 segInput.z（因为 postprocess 把值铺满 RGB）；这里 mask 是单通道 r8Unorm，
// 因此改读 .r，语义完全一致。
fragment float4 fs_accumulate(QuadOut in [[stage_in]],
                              texture2d<float> segmentation [[texture(0)]],
                              texture2d<float> oldAccumulator [[texture(1)]],
                              constant float &factor [[buffer(0)]]) {
    float seg = segmentation.sample(kSegSampler, in.uv).r;
    float old = oldAccumulator.sample(kSegSampler, in.uv).r;

    float inverseSegmentMap = 1.0 - step(0.05, seg);
    float add = (old + factor) * inverseSegmentMap;
    return float4(add, 0.0, 0.0, add);
}

// MARK: - masking_shader.glsl
// mask 处取 framebuffer2，否则取 framebuffer1
fragment float4 fs_masking(QuadOut in [[stage_in]],
                           texture2d<float> sampler1 [[texture(0)]],
                           texture2d<float> sampler2 [[texture(1)]],
                           texture2d<float> mask [[texture(2)]]) {
    float4 col1 = sampler1.sample(kSegSampler, in.uv);
    float4 col2 = sampler2.sample(kSegSampler, in.uv);
    float4 m = mask.sample(kSegSampler, in.uv);

    // 三个通道相加：兼容只写单通道的分割输出
    float actual = step(1.0, m.x + m.y + m.z);
    return col2 * actual + (1.0 - actual) * col1;
}

// MARK: - 掩膜膨胀（5×5 最大值滤波）
//
// 对应上游 `OpenCVDilateStage`（`Imgproc.dilate`，kernel = 2*2+1 = 5×5 矩形，
// `getStructuringElement(CV_SHAPE_RECT)`）。
// 作用：把分割 mask 向外扩一圈，覆盖人像边缘，否则边缘像素不会被历史帧替换，
// 去遮挡后的画面会留下一圈"人形轮廓"。

fragment float4 fs_dilate_mask(QuadOut in [[stage_in]],
                               texture2d<float> mask [[texture(0)]],
                               constant float2 &resolution [[buffer(0)]],
                               constant float &radius [[buffer(1)]]) {
    float2 texel = 1.0 / resolution;
    float maxValue = 0.0;
    int r = int(radius);
    for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
            float2 offset = float2(float(dx), float(dy)) * texel;
            maxValue = max(maxValue, mask.sample(kSegSampler, in.uv + offset).r);
        }
    }
    return float4(maxValue, maxValue, maxValue, 1.0);
}
