//  公共顶点 / 片元着色器
//  对应上游 res/raw/{vertex_shader, texture, passthrough_shader, letterboxing_shader,
//                     camera_shader}.glsl
#include <metal_stdlib>
using namespace metal;

// MARK: - 全屏 quad
//
// 上游每个阶段都是「全屏 quad + gl_FragCoord/resolution 求 uv」。
// Metal 里顶点 id 就能推出 uv，不需要额外顶点缓冲。
// uv 约定：原点在渲染目标左上角，与 Metal 纹理坐标一致。

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

static inline QuadOut makeQuad(uint vid) {
    // vid: 0=(0,0) 1=(1,0) 2=(0,1) 3=(1,1)，triangle strip
    float2 c = float2(float(vid & 1u), float(vid >> 1u));
    QuadOut o;
    o.position = float4(c * 2.0 - 1.0, 0.0, 1.0);
    // 注意：NDC 的 y 轴朝上，纹理 v 轴朝下，这里必须翻转一次。
    // 少了这次翻转，全屏 pass 会把画面上下颠倒——
    // 后果是管线内部纹理与 Core ML 输出的 mask 垂直错位（人像遮罩永远圈不到人），
    // 而且只有经过奇数个 pass 的分支才会显现，极难排查。
    o.uv = float2(c.x, 1.0 - c.y);
    return o;
}

vertex QuadOut vs_quad(uint vid [[vertex_id]]) {
    return makeQuad(vid);
}

constexpr sampler kLinearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// MARK: - 带目标矩形的 blit（上屏 / 调试视图）
// rect = (minX, minY, width, height)，NDC 坐标

struct BlitVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitVertexOut vs_blit(uint vid [[vertex_id]],
                             constant float4 &rect [[buffer(0)]]) {
    float2 c = float2(float(vid & 1u), float(vid >> 1u));
    BlitVertexOut o;
    o.position = float4(rect.x + c.x * rect.z, rect.y + c.y * rect.w, 0.0, 1.0);
    o.uv = float2(c.x, 1.0 - c.y);   // 目标左上角对应源左上角
    return o;
}

fragment float4 fs_blit(BlitVertexOut in [[stage_in]],
                        texture2d<float> source [[texture(0)]]) {
    return source.sample(kLinearSampler, in.uv);
}

// 单通道（r8Unorm）转灰度：对应上游 segment_postprocess_shader 的 `.xxx`
fragment float4 fs_blit_gray(BlitVertexOut in [[stage_in]],
                             texture2d<float> source [[texture(0)]]) {
    float v = source.sample(kLinearSampler, in.uv).r;
    return float4(v, v, v, 1.0);
}

// MARK: - texture.glsl：纯采样（缩放 / 存储透传）
fragment float4 fs_texture(QuadOut in [[stage_in]],
                           texture2d<float> source [[texture(0)]]) {
    return source.sample(kLinearSampler, in.uv);
}

// MARK: - camera_shader.glsl
// iOS 侧用 CVMetalTextureCache 拿到的是 BGRA 纹理，且已按视频旋转角出图，
// 所以这里只保留一次可选的纵向翻转。
fragment float4 fs_camera(QuadOut in [[stage_in]],
                          texture2d<float> camera [[texture(0)]],
                          constant float &flipY [[buffer(0)]]) {
    float2 uv = in.uv;
    if (flipY > 0.5) { uv.y = 1.0 - uv.y; }
    return camera.sample(kLinearSampler, uv);
}

