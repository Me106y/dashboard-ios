#include <metal_stdlib>
using namespace metal;

struct BlitVertexOut {
    float4 position [[position]];
    float2 uv;
};

/// 把一个纹理画到 NDC 矩形区域。
/// rect.xy = 左下角（NDC，-1..1），rect.zw = 宽高（NDC）
vertex BlitVertexOut blit_vertex(uint vid [[vertex_id]],
                                 constant float4 &rect [[buffer(0)]]) {
    // 全屏三角形条带：0=(0,0) 1=(1,0) 2=(0,1) 3=(1,1)
    float2 corner = float2(vid & 1, vid >> 1);
    BlitVertexOut out;
    out.position = float4(rect.x + corner.x * rect.z,
                          rect.y + corner.y * rect.w,
                          0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);   // Metal 纹理原点在左上，翻转 v
    return out;
}

fragment float4 blit_fragment(BlitVertexOut in [[stage_in]],
                              texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(coord::normalized,
                        address::clamp_to_edge,
                        filter::linear);
    return source.sample(s, in.uv);
}

/// 单通道（r8Unorm）纹理转灰度显示。
/// 对应上游 `segment_postprocess_shader.glsl` 的 `texture2D(...).xxx`：
/// 采样 r8Unorm 得到的是 (r,0,0,1)，直接输出会显示成红色。
fragment float4 blit_fragment_gray(BlitVertexOut in [[stage_in]],
                                   texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(coord::normalized,
                        address::clamp_to_edge,
                        filter::linear);
    float value = source.sample(s, in.uv).r;
    return float4(value, value, value, 1.0);
}
