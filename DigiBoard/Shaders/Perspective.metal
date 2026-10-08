//  透视校正
//  对应上游 res/raw/{vertex_perspective_correction_shader, texture_distortable}.glsl
//
//  原理与上游一致（见 https://www.reedbeta.com/blog/quadrilateral-interpolation-part-1/）：
//  把四个顶点的纹理坐标乘以一个「伪深度」z，光栅化插值后再除以 z，
//  即可得到四边形上的正确透视纹理映射。
#include <metal_stdlib>
using namespace metal;

// vs_quad 在 Blit.metal 中定义，这里重复声明其输出结构
struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

struct PerspectiveOut {
    float4 position [[position]];
    float3 tex;
};

vertex PerspectiveOut vs_perspective(uint vid [[vertex_id]],
                                     const device float4 *positions [[buffer(0)]],
                                     const device float3 *texCoords [[buffer(1)]]) {
    PerspectiveOut o;
    o.position = positions[vid];
    o.tex = texCoords[vid];
    return o;
}

constexpr sampler kPerspectiveSampler(coord::normalized, address::clamp_to_edge, filter::linear);

fragment float4 fs_distortable(PerspectiveOut in [[stage_in]],
                               texture2d<float> source [[texture(0)]]) {
    // 除以 z，抵消顶点阶段对 z 的乘法
    float2 uv = in.tex.xy / in.tex.z;
    return source.sample(kPerspectiveSampler, uv);
}

// MARK: - 逐像素单应查表
//
// 我们的做法：一次性解出「目标 uv -> 源 uv」的单应矩阵，片元里直接查表。
// 相比上游用伪深度顶点插值，这样更容易验证，也避免了顶点插值带来的误差累积。

fragment float4 fs_perspective_lookup(QuadOut in [[stage_in]],
                                      texture2d<float> source [[texture(0)]],
                                      constant float3x3 &homography [[buffer(0)]]) {
    float3 p = float3(in.uv, 1.0);
    float3 q = homography * p;
    float2 uv = q.xy / max(q.z, 1e-6);
    return source.sample(kPerspectiveSampler, uv);
}
