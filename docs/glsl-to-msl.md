# GLSL → MSL 着色器移植对照

上游 Android 版共有 **28 个 GLSL 着色器**（`app/src/main/res/raw/*.glsl`，合计 727 行）。
本文逐条记录哪些移植、哪些未移植、以及翻译时遵循的规则。**移植 21 个，不移植 7 个。**

- 上游着色器目录：`WhiteboardApp-main/app/src/main/res/raw/`
- iOS 着色器目录：`DigiBoard/Shaders/`（`Blit.metal` · `Filters.metal` · `Segmentation.metal` ·
  `Enhance.metal` · `Perspective.metal`）
- 文中「上游」均指 Android 版实现。

---

## 1. 通用翻译规则

| GLSL / OpenGL ES | MSL / Metal | 说明 |
| --- | --- | --- |
| `gl_FragCoord.xy / resolution` | 顶点阶段算好的 `uv` | Metal 的 `[[position]]` 原点在左上；统一改用 quad 传入的归一化 uv，避免两套坐标系混用 |
| `texture2D(sampler, uv)` | `tex.sample(sampler, uv)` | 采样器必须显式声明 |
| `precision mediump float` | 无需 | Metal 默认 32 位；`compute_precision` 只作用于 Core ML |
| `uniform float x` | `constant float &x [[buffer(0)]]` | 用 `setFragmentBytes` 传 |
| `uniform sampler2D s` | `texture2d<float> s [[texture(0)]]` | 用 `setFragmentTexture(_:index:)` 传 |
| `uniform float a[3]` | struct 里的 `float a[3]` | 注意与 Swift 结构体的**逐字节对齐**（见第 3 节） |
| `gl_FragColor` | `return float4(...)` | |
| `fract / mix / clamp / step` | 同名函数 | 语义一致 |
| `discard` | `discard_fragment()` | 名称不同，语义一致 |
| `mat2(c, s, -s, c) * v` | 手写 `float2(c*v.x - s*v.y, s*v.x + c*v.y)` | 避免矩阵构造顺序歧义 |
| `samplerExternalOES`（相机外部纹理） | 普通 `texture2d<float>` | iOS 用 `CVMetalTextureCache` 直接把 BGRA 的 `CVPixelBuffer` 变成纹理，**没有外部纹理概念** |
| `#extension GL_OES_EGL_image_external` | 删除 | 同上 |

另外两条属于**有意的架构差异**：

1. **朝向不再写死在着色器里。** 上游 `segment_preprocess_shader` 用 `vec2(1.0 - uv.y, uv.x)`
   硬编码右横屏；iOS 版把朝向做成 `rotation` 参数（`rotateUV` / `inverseRotateUV`），
   相机侧则直接用 `AVCaptureConnection.videoRotationAngle` 把缓冲区旋正，默认 rotation = 0。
2. **透视校正换了解法。** 见第 2 节对应的两条。

---

## 2. 逐条对照

### 2.1 必需移植（18）

| # | 上游 GLSL | iOS MSL | 备注 |
| --- | --- | --- | --- |
| 1 | `vertex_shader.glsl` | `vs_quad`（Blit.metal） | 公共全屏 quad。上游 29 处阶段共用它；iOS 侧用顶点 id 直接推出 uv，无需顶点缓冲 |
| 2 | `camera_shader.glsl` | `fs_camera`（Blit.metal） | 上游是 `samplerExternalOES` + `1.0 - gl_FragCoord.yx/camera_resolution` 的翻转换轴；iOS 侧朝向由 `videoRotationAngle` 解决，只保留可选纵向翻转 |
| 3 | `segment_preprocess_shader.glsl` | `fs_seg_preprocess`（Segmentation.metal） | 朝向改为 `rotation` 参数 |
| 4 | `segment_postprocess_shader.glsl` | `fs_seg_postprocess`（Segmentation.metal） | 朝向还原 + 把值铺满 RGB（上游的 `.xxx`） |
| 5 | `grayscale_shader.glsl` | `fs_grayscale`（Filters.metal） | 系数 `0.3/0.59/0.11` 原样保留 |
| 6 | `gaussian_shader.glsl` | `fs_gaussian`（Filters.metal） | 5×5 可分离，offsets `[0, 1.3846153846, 3.2307692308]`、weights `[0.2270270270, 0.3162162162, 0.0702702703]` 与上游一致 |
| 7 | `sobel_shader.glsl` | `fs_sobel`（Filters.metal） | 梯度从 -1..1 映射到 0..1 后放在 r/g 通道 |
| 8 | `canny_shader.glsl` | `fs_canny`（Filters.metal） | 最长的一个（153 行）。保持上游结构：方向量化到 8 个方向 → 非极大值抑制 → 双阈值 → 滞后连接。上游阈值 0.1 / 0.2 保留 |
| 9 | `segmentation_accumulation_shader.glsl` | `fs_accumulate`（Segmentation.metal） | 上游读 `segInput.z`（因为 postprocess 把值铺满 RGB）；iOS 的 mask 是单通道 `r8Unorm`，改读 `.r`，语义相同 |
| 10 | `masking_shader.glsl` | `fs_masking`（Segmentation.metal） | `step(1.0, m.x+m.y+m.z)` 判据与上游一致 |
| 11 | `texture.glsl` | `fs_texture`（Blit.metal） | 缩放 / 存储透传 |
| 12 | `whitebalance_shader.glsl` | `fs_whitebalance`（Enhance.metal） | `1.0 - (background - raw)` 原样 |
| 13 | `binarization_fast_shader.glsl` | `fs_binarize_fast`（Enhance.metal） | 阈值 7.5 与上游一致 |
| 14 | `saturate_shader.glsl` | `fs_saturate`（Enhance.metal） | `rgb2hsv` / `hsv2rgb` 逐行翻译（展开 swizzle），饱和度增益 4.5 保留 |
| 15 | `vertex_perspective_correction_shader.glsl` | `vs_perspective`（Perspective.metal） | 保留顶点着色器供"按顶点做透视"的路径使用 |
| 16 | `texture_distortable.glsl` | `fs_distortable`（Perspective.metal） | 除以 z 抵消顶点阶段乘的伪深度 |
| 17 | `letterboxing_shader.glsl` | `vs_blit` + `fs_blit`（Blit.metal） | 上游用 `offset` uniform 做信箱；iOS 侧改用「等比适配矩形 + 清屏色」，效果等价 |
| 18 | `passthrough_shader.glsl` | `fs_passthrough`（Blit.metal） | 上屏 / 调试视图 |

> **第 15/16 条的重要说明**：我们最终**没有走**上游的"伪深度顶点插值"路线。
> 上游那套实现要把 `getPerspectiveTransform(src, dst)` 再作用到 dst 上，语义绕。
> iOS 版改成：解一次「目标 uv → 源 uv」的单应矩阵（`Geometry/Homography.swift`），
> 由 `fs_perspective_lookup` 逐像素查表。`vs_perspective` / `fs_distortable` 保留下来，
> 是因为它们对理解上游算法仍有参考价值。

### 2.2 新增用途复用（3）

| # | 上游 GLSL | iOS MSL | 上游用途 | iOS 用途 |
| --- | --- | --- | --- | --- |
| 19 | `corner_shader.glsl` | `vs_corner` + `fs_corner`（Blit.metal） | 调试画角点 | **手动模式的角点手柄可视化**（修正上游"盲拖"缺陷） |
| 20 | `line_shader.glsl` | `fs_color`（Blit.metal）+ `vs_segment` | 调试画直线 | 四边形边框 + 手柄连线 |
| 21 | `image_shader.glsl` | `fs_texture`（复用） | 静态图输入（上游已注释） | `StillImageStage` / `StillImageFrameSource`，模拟器与静态图回归 |

### 2.3 不移植（7）

| # | 上游 GLSL | 原因 |
| --- | --- | --- |
| 22 | `shaderfun.glsl` | 只被 `NoiseDistortionStage` 使用，该阶段不在启用管线内 |
| 23 | `opengl_to_bitmap_shader.glsl` | 只被 `OpenGLToBitmapCoordinate` 使用；iOS 用 `MTLTexture.getBytes` 直接回读 |
| 24 | `binarization_shader.glsl` | `BinarizationStage`（非 fast 版）不在启用管线内，主路径用的是 `binarization_fast` |
| 25 | `accumulation_shader.glsl` | `AccumulationStage` 不在启用管线内；实际用的是 `segmentation_accumulation` |
| 26 | `masked_accumulation_shader.glsl` | 同上，`MaskedAccumulationStage` 不可达 |
| 27 | `step_shader.glsl` | 只被 `StepStage` 使用，不在启用管线内 |
| 28 | `overlay_shader.glsl` | 只被调试用的 overlay 组合使用；手柄可视化已由 `corner`/`line` 覆盖 |

---

## 3. 结构体对齐（易错点）

Metal 的 `constant` buffer 按 **16 字节**对齐结构体起点，成员按各自类型对齐。
Swift 侧必须构造出逐字节一致的结构体，否则 uniform 会静默错位。当前已验证：

| Swift 类型 | MSL 对应 | size | 布局 |
| --- | --- | --- | --- |
| `GaussianParams` | `Filters.metal` 的同名 struct | **40** | `float[3]`(12) + `float[3]`(12) + `float2`(8) + `float2`(8) |
| `CannyParams` | `Filters.metal` 的同名 struct | **16** | `float`(4) + `float`(4) + `float2`(8) |
| `SegmentParams` | `Blit.metal` 的同名 struct | **28** | `float2`(8) + `float2`(8) + `float2`(8) + `float`(4) |

这三个尺寸由 `DigiBoardTests/GeometryTests.swift` 的
`testShaderParamsLayoutMatchesMetal` 守住——**改任何一个结构体都会让单测失败**。

另外 `fs_gaussian` 里的 `float2 direction` 若写成两个独立 `float`，Swift 侧的
对齐就会错开 4 字节，请保持 `SIMD2<Float>`。

---

## 4. 单通道纹理的坑

`r8Unorm` 纹理采样得到的是 `(r, 0, 0, 1)`，直接输出会**显示成红色**（而不是灰度）。
上游 `segment_postprocess_shader` 用 `.xxx` 把红通道铺满三个通道来规避，iOS 侧对应：

- `fs_blit_gray`（Blit.metal）：`float4(v, v, v, 1)`
- `PresentStage` 会按当前纹理的 `pixelFormat` 自动选择 `fs_blit_gray`

---

## 5. 移植后的着色器清单

```
DigiBoard/Shaders/
├── Blit.metal          vs_quad · vs_blit · fs_blit · fs_blit_gray · fs_texture
│                       fs_passthrough · fs_camera · fs_color · vs_corner · fs_corner
│                       vs_segment
├── Filters.metal       fs_grayscale · fs_gaussian · fs_sobel · fs_canny
├── Segmentation.metal  fs_seg_preprocess · fs_seg_postprocess · fs_accumulate · fs_masking
├── Enhance.metal       fs_whitebalance · fs_binarize_fast · fs_saturate
└── Perspective.metal   vs_perspective · fs_distortable · fs_perspective_lookup
```

合计 **21 个 GLSL 的对应实现 + 1 个新增的 `fs_perspective_lookup`**。
