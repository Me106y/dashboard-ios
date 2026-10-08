//  grayscale_shader.glsl
//  对应上游 res/raw/grayscale_shader.glsl
#include <metal_stdlib>
using namespace metal;

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler kGraySampler(coord::normalized, address::clamp_to_edge, filter::linear);

// 系数来自上游注释引用的 VB6 灰度算法
fragment float4 fs_grayscale(QuadOut in [[stage_in]],
                             texture2d<float> framebuffer [[texture(0)]]) {
    float4 color = framebuffer.sample(kGraySampler, in.uv);
    float value = color.r * 0.3 + color.g * 0.59 + color.b * 0.11;
    return float4(value, value, value, color.a);
}
