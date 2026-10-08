//  图像增强：白平衡 / 自适应二值化 / 饱和度
//  对应上游 res/raw/{whitebalance_shader, binarization_fast_shader, saturate_shader}.glsl
#include <metal_stdlib>
using namespace metal;

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler kEnhanceSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// MARK: - whitebalance_shader.glsl
// 「1.0 - (背景色 - 原色)」：用低分辨率背景色做通道偏移校正
fragment float4 fs_whitebalance(QuadOut in [[stage_in]],
                                texture2d<float> rawInput [[texture(0)]],
                                texture2d<float> backgroundColor [[texture(1)]]) {
    float4 raw = rawInput.sample(kEnhanceSampler, in.uv);
    float4 background = backgroundColor.sample(kEnhanceSampler, in.uv);
    float3 corrected = float3(1.0) - (background.xyz - raw.xyz);
    return float4(corrected, 1.0);
}

// MARK: - binarization_fast_shader.glsl
// 自适应阈值：用降采样图的均值 ×(100-threshold)/100 作为阈值
fragment float4 fs_binarize_fast(QuadOut in [[stage_in]],
                                 texture2d<float> framebuffer [[texture(0)]],
                                 texture2d<float> downscaled [[texture(1)]],
                                 constant float &threshold [[buffer(0)]]) {
    float grey = framebuffer.sample(kEnhanceSampler, in.uv).r;
    float avg = downscaled.sample(kEnhanceSampler, in.uv).r;
    float thresholdedAvg = avg * (100.0 - threshold) / 100.0;
    float value = step(thresholdedAvg, grey);
    return float4(value, value, value, 1.0);
}

// MARK: - saturate_shader.glsl
// RGB <-> HSV 取自 lolengine 的经典实现，饱和度放大 4.5 倍（上游硬编码）

static inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.b, c.g, K.w, K.z), float4(c.g, c.b, K.x, K.y), step(c.b, c.g));
    float4 q = mix(float4(p.x, p.y, p.w, c.r), float4(c.r, p.y, p.z, p.x), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

fragment float4 fs_saturate(QuadOut in [[stage_in]],
                            texture2d<float> framebuffer [[texture(0)]],
                            constant float &saturationGain [[buffer(0)]]) {
    float4 color = framebuffer.sample(kEnhanceSampler, in.uv);
    float3 hsv = rgb2hsv(color.xyz);
    hsv.y *= saturationGain;
    return float4(hsv2rgb(hsv), color.a);
}
