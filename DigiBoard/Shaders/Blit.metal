//  公共顶点 / 片元着色器
//  对应上游 res/raw/{vertex_shader, texture, passthrough_shader, letterboxing_shader,
//                     corner_shader, line_shader, camera_shader}.glsl
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
    o.uv = float2(c.x, c.y);
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

// MARK: - passthrough_shader.glsl
fragment float4 fs_passthrough(QuadOut in [[stage_in]],
                               texture2d<float> framebuffer [[texture(0)]]) {
    return framebuffer.sample(kLinearSampler, in.uv);
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

// MARK: - line_shader.glsl：纯色（连线 / 边框）
fragment float4 fs_color(QuadOut in [[stage_in]],
                         constant float4 &color [[buffer(0)]]) {
    return color;
}

// MARK: - corner_shader.glsl：角点手柄（绿色圆点 + 边缘淡出）

struct HandleVertexOut {
    float4 position [[position]];
    float2 local;    // -0.5 .. 0.5
};

vertex HandleVertexOut vs_corner(uint vid [[vertex_id]],
                                 constant float4 &rect [[buffer(0)]]) {
    float2 c = float2(float(vid & 1u), float(vid >> 1u));
    HandleVertexOut o;
    o.position = float4(rect.x + c.x * rect.z, rect.y + c.y * rect.w, 0.0, 1.0);
    o.local = c - 0.5;
    return o;
}

fragment float4 fs_corner(HandleVertexOut in [[stage_in]]) {
    float d = dot(in.local, in.local);
    if (d > 0.25) { discard_fragment(); }
    if (d > 0.008) {
        float alpha = saturate((0.25 - d) / (0.25 - 0.008));
        return float4(0.0, 1.0, 0.0, alpha);
    }
    return float4(0.0, 1.0, 0.0, 1.0);
}
