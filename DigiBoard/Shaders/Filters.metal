//  边缘检测链：grayscale -> gaussian(x,y) -> sobel -> canny
//  对应上游 res/raw/{grayscale_shader, gaussian_shader, sobel_shader, canny_shader}.glsl
#include <metal_stdlib>
using namespace metal;

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler kEdgeSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// MARK: - grayscale_shader.glsl
// 系数来自上游注释引用的 VB6 灰度算法
fragment float4 fs_grayscale(QuadOut in [[stage_in]],
                             texture2d<float> framebuffer [[texture(0)]]) {
    float4 color = framebuffer.sample(kEdgeSampler, in.uv);
    float value = color.r * 0.3 + color.g * 0.59 + color.b * 0.11;
    return float4(value, value, value, color.a);
}

// MARK: - gaussian_shader.glsl
// 线性采样优化的 5x5 可分离高斯（Rastergrid 经典参数）

struct GaussianParams {
    float offsets[3];
    float weights[3];
    float2 direction;    // (1,0) 横向 / (0,1) 纵向
    float2 resolution;
};

fragment float4 fs_gaussian(QuadOut in [[stage_in]],
                            texture2d<float> framebuffer [[texture(0)]],
                            constant GaussianParams &p [[buffer(0)]]) {
    float2 d = float2(1.0 / p.resolution.x, 1.0 / p.resolution.y);

    float4 blurred = framebuffer.sample(kEdgeSampler, in.uv) * p.weights[0];
    for (int i = 1; i < 3; ++i) {
        float2 offset = float2(p.offsets[i]) * p.direction * d;
        blurred += framebuffer.sample(kEdgeSampler, in.uv + offset) * p.weights[i];
        blurred += framebuffer.sample(kEdgeSampler, in.uv - offset) * p.weights[i];
    }
    return blurred;
}

// MARK: - sobel_shader.glsl
// 把 -1..1 的梯度映射到 0..1，分别放在 r(x) 与 g(y) 通道

static inline float4 sobelKernel(texture2d<float> tex, float2 uv, float2 resolution) {
    float w = 1.0 / resolution.x;
    float h = 1.0 / resolution.y;
    float n[9];
    n[0] = tex.sample(kEdgeSampler, uv + float2(-w, -h)).r;
    n[1] = tex.sample(kEdgeSampler, uv + float2(0.0, -h)).r;
    n[2] = tex.sample(kEdgeSampler, uv + float2(w, -h)).r;
    n[3] = tex.sample(kEdgeSampler, uv + float2(-w, 0.0)).r;
    n[4] = tex.sample(kEdgeSampler, uv).r;
    n[5] = tex.sample(kEdgeSampler, uv + float2(w, 0.0)).r;
    n[6] = tex.sample(kEdgeSampler, uv + float2(-w, h)).r;
    n[7] = tex.sample(kEdgeSampler, uv + float2(0.0, h)).r;
    n[8] = tex.sample(kEdgeSampler, uv + float2(w, h)).r;

    float edgeH = n[2] + 2.0 * n[5] + n[8] - (n[0] + 2.0 * n[3] + n[6]);
    float edgeV = n[0] + 2.0 * n[1] + n[2] - (n[6] + 2.0 * n[7] + n[8]);
    return float4(edgeH * 0.5 + 0.5, edgeV * 0.5 + 0.5, 0.0, 1.0);
}

fragment float4 fs_sobel(QuadOut in [[stage_in]],
                         texture2d<float> framebuffer [[texture(0)]],
                         constant float2 &resolution [[buffer(0)]]) {
    return sobelKernel(framebuffer, in.uv, resolution);
}

// MARK: - canny_shader.glsl
// 移植自 Dylan James Cutler (DCtheTall) 的 GLSL 实现（MIT），保持原算法结构：
//   梯度方向量化到 8 个方向 -> 非极大值抑制 -> 双阈值 -> 滞后连接

struct CannyParams {
    float weakThreshold;
    float hardThreshold;
    float2 resolution;
};

static inline float2 intensityGradient(texture2d<float> tex, float2 coord) {
    float2 color = tex.sample(kEdgeSampler, coord).rg;
    return float2(color.x * 2.0 - 1.0, color.y * 2.0 - 1.0);
}

static inline float2 rotate2D(float2 v, float rad) {
    float s = sin(rad);
    float c = cos(rad);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// 方向量化到最近的 8 个基本方向，长度保持不变
static inline float2 round2DVectorAngle(float2 v) {
    float len = length(v);
    if (len < 1e-6) { return float2(0.0); }
    float2 n = v / len;
    float maximum = -1.0;
    float bestAngle = 0.0;
    for (int i = 0; i < 8; ++i) {
        float theta = float(i) * 2.0 * M_PI_F / 8.0;
        float2 u = rotate2D(float2(1.0, 0.0), theta);
        float scalar = dot(u, n);
        if (scalar > maximum) {
            maximum = scalar;
            bestAngle = theta;
        }
    }
    return len * rotate2D(float2(1.0, 0.0), bestAngle);
}

static inline float2 suppressedGradient(texture2d<float> tex, float2 coord, constant CannyParams &p) {
    float2 gradient = round2DVectorAngle(intensityGradient(tex, coord));
    float gradientLength = length(gradient);
    if (gradientLength < 1e-6) { return float2(0.0); }
    float2 step = gradient / gradientLength / p.resolution;
    if (length(intensityGradient(tex, coord + step)) >= gradientLength) { return float2(0.0); }
    if (length(intensityGradient(tex, coord - step)) >= gradientLength) { return float2(0.0); }
    return gradient;
}

static inline float doubleThreshold(float2 gradient, constant CannyParams &p) {
    float len = length(gradient);
    if (len < p.weakThreshold) { return 0.0; }
    if (len < p.hardThreshold) { return 0.5; }
    return 1.0;
}

static inline float hysteresis(texture2d<float> tex, float2 coord, constant CannyParams &p) {
    float2 d = 1.0 / p.resolution;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            float2 ds = float2(-d.x + float(i) * d.x, -d.y + float(j) * d.y);
            float2 gradient = suppressedGradient(tex, clamp(coord + ds, float2(0.0), float2(1.0)), p);
            if (doubleThreshold(gradient, p) == 1.0) { return 1.0; }
        }
    }
    return 0.0;
}

fragment float4 fs_canny(QuadOut in [[stage_in]],
                         texture2d<float> framebuffer [[texture(0)]],
                         constant CannyParams &p [[buffer(0)]]) {
    float2 gradient = suppressedGradient(framebuffer, in.uv, p);
    float edge = doubleThreshold(gradient, p);
    if (edge == 0.5) {
        edge = hysteresis(framebuffer, in.uv, p);
    }
    return float4(edge, edge, edge, 1.0);
}
