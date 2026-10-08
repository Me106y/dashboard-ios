# DigiBoard iOS — 产品与移植文档

> 版本 **0.1** · 状态：**方案已定稿，待开工 P0** · 更新：2026-10-08
>
> 本文档是 DigiBoard iOS 版的唯一事实来源：记录上游 Android 版盘点结论、14 项架构决策、
> 管线与着色器映射、分期验收标准、风险与工程结构。
> HTML 版见同目录 `PRD.html`。

---

## 1. 方案总览

**DigiBoard** 是一套移动端「数字无遮挡白板」系统：用实时人像分割找出演示者轮廓，再从历史帧缓冲里
取回被遮挡的白板像素做时序重建，最后经透视校正与图像增强，输出一张像电子文档一样干净的白板画面。

| 项 | 内容 |
| --- | --- |
| 上游 | Android 版 `Me106y/DigiBoard`（Kotlin + OpenGL ES + Paddle Lite/FastDeploy + OpenCV） |
| 本项目 | 从零新建的 **iOS 原生实现**，产物为可上真机的完整 App |
| 目标设备 | iPhone（开发验证机：iPhone 16 / iPhone17,3） |
| 技术栈 | Swift 6 · SwiftUI · Metal · AVFoundation · Core ML（**零第三方依赖**） |
| 工程路径 | `/Users/Zhuanz/Desktop/DigiBoard-iOS` |
| 命名 | 工程/Target `DigiBoard`，Bundle ID `com.zhuanz.digiboard`，Team `UW345FU9VD` |

**目标链路**：相机取景 → 人像分割 → 时序背景重建（去遮挡）→ 透视校正（自动/手动四角）→
图像增强（白平衡 · 自适应二值化 · 色彩还原）→ 全屏显示。

---

## 2. 总体技术判断

**这是一次「算法对等、实现重写」的移植，不是把 Kotlin 翻译成 Swift。**

上游那套代码把 30 多个渲染阶段用「构造顺序」隐式串起来，并对几乎每个阶段都分配一张全分辨率
纹理；同时带进了 6 个 OpenCV 平行实现和若干不可达的调试管线。iOS 版的价值在于用现代图形栈
（Metal + Core ML）重写同一条算法链，同时**不继承这些欠债**：

1. **渲染后端换 Metal**：上游 28 个着色器总共只有 727 行，且大多是简单采样与算术，逐字翻译成
   MSL 的成本有界，换来 Apple 唯一长期支持的实时渲染路径。
2. **分割模型转 Core ML**：线上跑的其实是 PaddleSeg 官方 `PP-HumanSegV2 portrait`
   （MobileNetV3 骨干），不是 README 宣传的自研模型——这意味着有成熟的 ONNX 转换路径，
   且能在 ANE 上硬件加速。
3. **OpenCV 完全移除**：OpenCV 在启用管线里只剩 3 处用途（霍夫直线、5×5 膨胀、单应求解），
   全部可用 Swift + Metal + `simd` 替代，不值得为此背一个几十 MB 的原生库。
4. **先跑通模型，再谈其它**：P0 的唯一目标是把 `PP-HumanSegV2 portrait` 在 Core ML 上跑出
   合理 mask，在此之前不写任何业务代码。

---

## 3. 上游 Android 版盘点

### 3.1 代码规模

| 维度 | 实测值 |
| --- | --- |
| Kotlin/Java 源文件 | 96 个 |
| GLSL 着色器 | 28 个，共 727 行（最长 `canny_shader` 153 行） |
| 入口 `MainActivity.kt` | 56 行（申请权限 → 挂一个 `GLSurfaceView`） |
| 分割模型 | `humansegv2portrait` 5.4 MB / `generallite` 14 MB / `generalmobile` 30 MB |
| 相机 | CameraX `Preview` → `SurfaceTexture`(OES) → 全屏 quad |
| 原生代码 | 仅 `GlesHelper.c` 一个函数（透传 `glReadPixels`） |

### 3.2 关键发现

> 以下 7 条都是阅读源码时实际确认的，直接决定了 iOS 版的设计取舍。

1. **线上模型与宣传不符**：`model/` 目录里是自研的 `MobileSegV2 + RepViT + EASPP`，
   但 App 打包并实际加载的是 PaddleSeg 官方 humansegv2 系列。证据：
   `model.pdiparams.info` 中的参数名为
   `net.backbone.blocks.N.{expand_conv,bottleneck_conv,linear_conv}`（MobileNetV3 倒残差）
   与 `net.ppseg_head.last_conv.depthwise_conv / piontwise_conv`（PPHumanSegHead/ASPP）。
   README 里的「1.97M 参数 / EASPP / mIoU 0.9096」属于训练代码口径。
2. **管线依赖是隐式的**：`Pipeline.draw()` 就是 `stages.forEach { it.performUpdate() }`，
   数据依赖全靠「谁先被 new」。移植 30 多个阶段时这是 bug 温床。
3. **纹理开销高**：几乎每个阶段各分配一张全分辨率纹理（1080p RGBA ≈ 8 MB/张）。
4. **手动拖角点是盲拖**：`DraggablePointsStage` 只持有 4 个点，不绘制任何手柄；
   `corner_shader` / `line_shader` 存在，但只用在未接入主流程的调试组合里。
5. **手势有副作用**：`ACTION_DOWN` 会触发 `DrawPipelineStage.next()` 切换显示阶段，
   而拖动角点必然先经过 `ACTION_DOWN`——所以每次伸手拖角点，画面都会跳到下一个中间阶段。
6. **OpenCV 大材小用 + 存在死代码**：主路径的 OpenCV 调用只有
   `Imgproc.HoughLines`、`Imgproc.dilate`、`getPerspectiveTransform` 三处；
   另有 6 个 OpenCV 平行实现（binarization/canny/grayscale/gaussian/sobel/cornerDetection）
   与 GLSL 版本重复且不可达。
7. **朝向写死**：`segment_preprocess_shader.glsl` 用 `vec2(1.0 - uv.y, uv.x)` 把画面转向分割网络，
   注释明确写着「hardcoded for right handed landscape orientation，TODO 处理手机方向」。

---

## 4. 移植架构决策

| # | 决策点 | 结论 | 理由摘要 |
| --- | --- | --- | --- |
| D1 | 移植范围 | **全流程对等**（五模块全做） | 卖点就是「去遮挡 + 高保真输出」，砍掉透视与增强后演示价值大打折扣 |
| D2 | 图形后端 | **Metal**（`MTKView` + `CVMetalTextureCache`） | OpenGL ES 自 iOS 12 起废弃 8 年；28 个着色器共 727 行，翻译成本有界 |
| D3 | 分割推理 | **Core ML**（pdmodel → ONNX → `.mlpackage`），**先跑通 `PP-HumanSegV2 portrait`** | ANE 硬件加速、零额外运行时；模型是官方结构，转换路径成熟 |
| D4 | 转换验收 | **视觉验收**（阈值数值比对降级为备用诊断） | 先看效果，不先花成本搭数值比对链路 |
| D5 | CV 方案 | **不用 OpenCV**：霍夫/四边形/单应用 Swift + `simd` 实现 | 主路径只剩 3 处用途，不值得引入几十 MB 原生库 |
| D6 | 相机管线 | `AVCaptureSession` + `AVCaptureVideoDataOutput`，像素格式 **`32BGRA`** | `CVPixelBuffer` 经 `CVMetalTextureCache` 零拷贝成 `MTLTexture`，无需色彩转换着色器 |
| D7 | 采集规格 | **1920×1080 @ 30fps**，**不做预先降分辨率**，如实实测 | 分割网络输入仅 256×144；分辨率不足时再谈降级 |
| D8 | 朝向策略 | v1 **锁横屏**，朝向作为 uniform 传入着色器 | 避开「传感器方向/预览方向/分割输入/显示」四者互相打架 |
| D9 | 帧源抽象 | 所有输入藏在 **`FrameSource` 协议**后（`CameraFrameSource` / `StillImageFrameSource`） | 静态图验证不需要改管线代码 |
| D10 | App 外壳 | **SwiftUI 做壳 + UIKit `MTKView` 做画布**（`UIViewRepresentable` 桥接） | 触摸处理留在 UIKit，`touchesBegan/Moved` 与 Android `onTouchEvent` 一对一映射 |
| D11 | 最低系统 | **iOS 17.0** | 覆盖 A12+（均有 ANE），可用现代 SwiftUI，无需老系统分支 |
| D12 | 工程生成 | **手写 `.xcodeproj` + Xcode 16 同步文件夹**（`PBXFileSystemSynchronizedRootGroup`） | 零额外工具；新增 `.swift`/`.metal` 无需改工程文件 |
| D13 | 管线架构 | **混合式**：保留 `RenderStage` 顺序列表，但**强制显式声明输入/输出纹理句柄** + 纹理池引用计数复用 + 推理与渲染解耦 | 兼顾移植速度（一个着色器=一个阶段）与长期可维护性 |
| D14 | 交互模型 | **显式控制条 + 修正手势语义**：单击（位移小于阈值）切调试视图，拖动只拖角点，控件里切自动/手动 | 消除 D-发现 5 的副作用，把隐藏状态变成可见状态 |

---

## 5. 管线映射（Android → iOS）

| 阶段 | Android 实现 | iOS 实现 | 备注 |
| --- | --- | --- | --- |
| 相机输入 | `CameraXStage`（CameraX + OES 纹理） | `CameraStage`（AVFoundation + `CVMetalTextureCache`） | 零拷贝，BGRA |
| 静态图输入 | `TextureStage`（已注释） | `StillImageStage` | 服务于 P1 静态图验收 |
| 分割前处理 | `SegmentationPreProcessingStage` | 同名 Metal pass | 朝向改为动态 uniform |
| 分割推理 | `SegmentationStage`（FastDeploy `PaddleSegModel`） | `SegmentationStage`（Core ML） | 后台队列 + 每 N 帧节流 |
| mask 膨胀 | `OpenCVDilateStage`（5×5 矩形核） | Metal compute 形态学膨胀 | 3.7 万像素，也可 CPU |
| 帧缓冲↔位图 | `FramebufferToBitmap(PBO)` / `BitmapToFramebuffer` | `MTLTexture` ↔ `MTLBuffer` blit | 不再需要 PBO 技巧 |
| 时序累积 | `SegmentationAccumulationStage` | 同名 Metal pass | 权重 0.2，跨帧持久纹理 |
| mask 后处理 | `SegmentationPostProcessingStage` | 同名 Metal pass | 灰度化 + 朝向还原 |
| 遮罩与存储 | `MaskingStage` / `StoreStage` | 同名 Metal pass | 去遮挡核心 |
| 边缘检测链 | `Grayscale → Gaussian×2 → Sobel → Canny` | 同名四个 Metal pass | 全部有现成 GLSL 可翻译 |
| 直线检测 | `OpenCVLineDetectionStage`（`HoughLines`） | `HoughLineDetector`（Swift） | 降采样后统计累加器 |
| 直线角度判别 | `LinesAngleDiscriminatorStage`×2 | 同名 Swift 纯函数 | 分横/竖两组 |
| 最大四边形 | `BiggestQuadStage` | 同名 Swift 纯函数 | 四重循环 + 60°~130° 角校验 + `fixupQuad` |
| 角点平滑 | `WeightedMovingAveragePointsStage` | 同名 Swift 纯函数 | 20 帧加权 |
| 手动角点 | `DraggablePointsStage`（不可见） | `DraggableCornersStage` + **可视手柄** | 修正上游盲拖缺陷 |
| 透视点变换 | `PerspectiveTransformPointsStage`（OpenCV 单应） | `PerspectiveTransform`（`simd`） | 纯数学 |
| 透视校正 | `PerspectiveCorrectionStage` | 同名 Metal pass | 顶点着色器做投影 |
| 缩放/分辨率 | `ScaleToResolutionStage` / `GenerateMipmapStage` | 同名 Metal pass | 白平衡降 1/32、二值化降 1/8 |
| 白平衡 | `WhitebalanceStage` | 同名 Metal pass | 以低分辨率背景色校正 |
| 自适应二值化 | `BinarizationFastStage` | 同名 Metal pass | 阈值 7.5 |
| 色彩还原 | `HSVAdjustmentsStage` + `MaskingStage` | 同名 Metal pass | 加色回填 |
| 信箱适配 | `LetterboxingStage` | 同名 Metal pass | 输出到屏幕比例 |
| 屏幕输出 | `DrawFramebufferStage` | 同名 Metal pass | 另含逐级调试视图 |
| 角点/直线绘制 | `DrawCornersStage` / `DrawLinesStage`（未接入） | 复用，用于手柄可视化 | 新增用途 |

---

## 6. 着色器移植清单

**总计 28 个，移植 21 个，不移植 7 个。**

### 6.1 必需移植（18）

| 着色器 | 用途 |
| --- | --- |
| `vertex_shader` | 公共顶点着色器（29 处阶段共用） |
| `camera_shader` | 相机 OES/外部纹理 → 全屏 quad |
| `segment_preprocess_shader` | 缩放 + 朝向 → 分割网络输入 |
| `segment_postprocess_shader` | 朝向还原 + 取红通道输出灰度 mask |
| `grayscale_shader` | 灰度化 |
| `gaussian_shader` | 5×5 高斯（x/y 两趟） |
| `sobel_shader` | 梯度 |
| `canny_shader` | Canny 边缘（153 行，最长） |
| `segmentation_accumulation_shader` | 时序累积（权重 0.2） |
| `masking_shader` | 遮罩合成 |
| `texture` | 采样缩放 / 存储透传 |
| `whitebalance_shader` | 白平衡 |
| `binarization_fast_shader` | 自适应二值化 |
| `saturate_shader` | HSV/饱和度调整 |
| `vertex_perspective_correction_shader` | 透视投影（顶点） |
| `texture_distortable` | 透视扭曲采样（片元） |
| `letterboxing_shader` | 信箱适配 |
| `passthrough_shader` | 屏幕输出 / 调试视图 |

### 6.2 新增用途复用（3）

| 着色器 | 原本用途 | iOS 用途 |
| --- | --- | --- |
| `corner_shader` | 调试画角点 | **手动模式的手柄可视化**（修正盲拖） |
| `line_shader` | 调试画直线 | 手柄连线 / 检测结果可视化 |
| `image_shader` | 静态图输入（上游已注释） | **`StillImageStage`**，P1 静态图验收 |

### 6.3 不移植（7）

`shaderfun`（随 `NoiseDistortion`）、`opengl_to_bitmap_shader`、`binarization_shader`
（非 fast 版）、`accumulation_shader`、`masked_accumulation_shader`、`step_shader`、`overlay_shader`
—— 均属于不可达阶段或已被更优实现取代。

---

## 7. 分期计划与验收标准

> 每期结束**部署到 iPhone 16 真机**一次。P0 是唯一有硬性「交通规则」的阶段：模型不通过就不写业务代码。

### P0 · 模型闸门

| 项 | 内容 |
| --- | --- |
| 交付 | 工程骨架（`DigiBoard.xcodeproj` + 同步文件夹 + `git init`）、`scripts/` 转换与诊断脚本、Core ML 模型产物 |
| 动作 | `pdmodel → ONNX(paddle2onnx) → .mlpackage(coremltools)`；macOS 上跑通推理出 mask |
| 验收 | **视觉验收**：喂测试图，Core ML 输出的 mask 能合理抠出人像轮廓 |
| 备用诊断 | 若视觉异常，再启用 `paddlepaddle` 全精度参考链路，逐像素比对定位算子问题 |
| 硬性指标 | 无阈值门槛（原 1% 不一致 / IoU 0.98 阈值已降级为诊断参考） |

### P1 · 渲染骨架

| 项 | 内容 |
| --- | --- |
| 交付 | `RenderStage` 协议、纹理池、命令缓冲与 in-flight 信号量、`StillImageFrameSource` |
| 动作 | 静态图 → Metal 上屏 → 接入 Core ML 分割 → 显示 mask |
| 验收 | 真机上喂静态图，**屏幕同时显示原图与 mask** |

### P2 · 去遮挡闭环

| 项 | 内容 |
| --- | --- |
| 交付 | `AVCaptureSession` + 零拷贝纹理、分割节流与双缓冲发布、时序累积 + Masking + Store |
| 动作 | 打通 `相机 → 分割 → 累积 → 显示` |
| 验收 | 真机对着白板，**人走过时遮挡区被历史帧填上**；1080p 下如实记录实测帧率 |
| 说明 | 帧率**不预设降分辨率**；先测出真实数字，再谈优化 |

### P3 · 透视校正

| 项 | 内容 |
| --- | --- |
| 交付 | 手动模式（可拖角点 + 手柄可视化）、自动模式（Canny→Hough→角度判别→BiggestQuad→WMA）、`simd` 单应 |
| 验收 | 白板被摆正；自动/手动两种模式可切换且互不干扰 |

### P4 · 图像增强

| 项 | 内容 |
| --- | --- |
| 交付 | Mipmap / 缩放 / 白平衡 / 自适应二值化 / HSV / 加色回填 / Letterbox |
| 验收 | 输出干净白板；**逐级对照 Android 版**视觉一致 |

### P5 · 交互与收尾

| 项 | 内容 |
| --- | --- |
| 交付 | SwiftUI 控制条（自动/手动、视图切换、重置角点）、逐级调试视图、单元测试、README、`docs/glsl-to-msl.md` |
| 验收 | 全部控件可用；单元测试通过；移植文档齐全 |

---

## 8. 非功能需求

| 维度 | 目标 | 验证方式 |
| --- | --- | --- |
| 帧率 | 1080p 下 ≥30fps（**目标值，不预先降分辨率**） | 真机 Instruments / 帧计时日志 |
| 采集规格 | 1920×1080 @ 30fps，像素格式 `32BGRA` | 运行时打印实际 `AVCaptureDevice.Format` |
| 延迟 | 端到端体感无卡顿，历史帧重建无闪烁 | 真机人眼观察 |
| 内存 | 纹理池复用，in-flight 命令缓冲 ≤3，避免纹理数量随阶段线性增长 | Xcode Memory Graph |
| 依赖 | **零第三方二进制**：仅 Swift / SwiftUI / Metal / AVFoundation / Core ML | 检查 Package 依赖为空 |
| 隐私 | 仅需相机权限；不联网、不上传、不落盘原图 | `Info.plist` + 代码审计 |
| 朝向 | v1 锁横屏 | `Info.plist` 方向配置 |

---

## 9. 工程结构

```
/Users/Zhuanz/Desktop/DigiBoard-iOS/
├── PRD.md / PRD.html / prd-styles.css   # 本文档
├── DigiBoard.xcodeproj                  # 手写工程 + 同步文件夹
├── DigiBoard/                           # App target
│   ├── App/                             # SwiftUI 外壳、权限、入口
│   ├── Camera/                          # AVCaptureSession + FrameSource 协议
│   ├── Render/                          # MTKView、命令缓冲、纹理池
│   ├── Pipeline/                        # RenderStage 协议与各阶段
│   ├── Segmentation/                    # Core ML 封装 + SegmentationProvider 协议
│   ├── Geometry/                        # 霍夫、最大四边形、单应（simd）
│   ├── Shaders/                         # .metal 文件
│   └── Resources/                       # .mlpackage、图标
├── DigiBoardTests/                      # 单元测试
├── docs/glsl-to-msl.md                  # 着色器逐条对照
└── scripts/                             # 模型转换与诊断脚本
```

**单元测试范围（决策 D14 延伸）**：只测纯逻辑三块——几何算法（霍夫去重 / 最大四边形 /
`fixupQuad` / 角度校验）、`simd` 单应矩阵往返验证、纹理池引用计数与阶段依赖校验。
**着色器不做黄金图比对**，改用「逐级调试视图」人眼对照 Android 版。

---

## 10. 风险与阻塞

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| Core ML 转换遇不支持算子 | P0 卡住 | 先转 fp16，不过换 fp32；再不行查 Resize 的 `align_corners`/插值；最后回退 MNN |
| 1080p 下打不满 30fps | P2 验收不达标 | 如实测；优化纹理池与 pass 合并；降级到 720p 是**最后手段** |
| 自动角点检测在弱纹理白板上不稳 | P3 体验下降 | 手动模式始终可用；调霍夫阈值/累加器分辨率 |
| Metal pass 数量多导致编码开销 | 帧率与功耗 | 纹理池 + 可合并阶段并入同一 render pass |
| 描述文件/签名 | 无法真机部署 | 已有有效 Apple Development 证书（Team `UW345FU9VD`），新 Bundle ID 用自动签名 |
| 上游模型与 README 不符 | 预期错位 | 已确认线上为 `PP-HumanSegV2 portrait`，以实际权重为准 |

---

## 11. 变更记录

| 版本 | 日期 | 说明 |
| --- | --- | --- |
| v0.1 | 2026-10-08 | 初始版本。完成上游 Android 版盘点（96 文件 / 28 着色器 / 模型归属确认 / 7 项缺陷发现），确定 D1–D14 架构决策、管线与着色器映射、P0–P5 分期与验收标准 |

---

**文档所有者**：单人开发　·　**审核状态**：方案已定稿，待开工 P0
