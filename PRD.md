# DigiBoard iOS — 产品与移植文档

> 版本 **0.8** · 状态：**修复人像边缘叠影（mask 时效诊断 + 膨胀补偿）** · 更新：2026-10-09
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
| **结果** | ✅ **已完成**。Core ML 模型 1.9 MB；ONNX↔Core ML 不一致像素 **0.073%**、前景 **IoU 0.9926**（详见 §12） |

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

## 12. P0 转换实录

P0 是本次移植技术风险最高的一步，过程与结论记录在此，避免重复踩坑。

### 12.1 最终链路

```
model.pdmodel + model.pdiparams           (PaddleSeg PP-HumanSegV2 portrait)
      │  paddle2onnx 1.3.1 / paddlepaddle 2.6.2 + 图修复
      ▼
humansegv2portrait.onnx                   [1,3,144,256] f32 → [1,144,256] i32
      │  onnx2torch → torch.jit.trace
      ▼
TorchScript
      │  coremltools 8.1（mlProgram, iOS 17+, FLOAT16）
      ▼
humansegv2portrait.mlpackage              图像输入 256x144 RGB → mask [1,144,256] INT32，1.9 MB
```

### 12.2 六个实际卡点

| # | 卡点 | 根因 | 解法 |
| --- | --- | --- | --- |
| 1 | ONNX 加载失败 | ASPP 的 `AdaptiveAvgPool` 在动态输入下无法推导 kernel，导出 `kernel_shape=[-1,-1]` | 钉死输入形状，按 Paddle 语义换算成等价固定核 |
| 2 | Paddle 3.x 读不了模型 | `load_inference_model` 走 PIR 分支，`UnicodeDecodeError` | 锁定 paddlepaddle **2.6.2** |
| 3 | 没有 ONNX→Core ML 通道 | coremltools 自 **7.0** 移除 ONNX 前端；7.2 在本机原生库还加载失败 | 走官方路线：ONNX → PyTorch → TorchScript → Core ML |
| 4 | onnx2torch `KeyError` | paddle2onnx 把 414 个权重内联成 `Constant` 节点 | 常量提升：`Constant` → `initializer` |
| 5 | `SAME_UPPER` 不支持 | onnx2torch 未实现自动填充 | 形状已固定，把 19 个 `SAME_*` 展开成显式 `pads`；形状推导必须开 `data_prop=True` |
| 6 | Core ML 图像预处理报错 | `scale` 需标量、`bias` 需三元组（pass 内部会 reshape 成 `[1,3,1,1]`） | 按各自要求传参 |

### 12.3 验证结果

测试图 `infront.jpg`（4032×1908，人在白板前）：

| 指标 | ONNX | Core ML |
| --- | --- | --- |
| 前景占比 | 9.9% | 9.8% |
| 前景包围盒 | x[122,190] y[31,143] | x[122,190] y[31,143] |

**一致性：不一致像素 0.073%，前景 IoU 0.9926。**
—— 比原定的数值闸门（≤1% 不一致 / IoU ≥ 0.98）更严，且已满足；尽管 Q12 把闸门降级为视觉验收，
实测数据顺带把数值门槛也一并过了。

> 归一化 `x' = (x/255 - 0.5) / 0.5` 已编入 Core ML 的 `ImageType`（`scale=1/127.5`、`bias=-1.0`），
> **App 直接喂 0–255 的 RGB 图像即可，不要重复归一化。**
> 判据与产物细节见 `scripts/model-convert/README.md`。


---

## 13. P1 实施记录

### 13.1 已落地的结构

```
DigiBoard/
├── App/            DigiBoardApp / ContentView / MetalCanvasView / BoardViewModel
├── Render/         MetalContext · TexturePool · TextureHandle · RenderStage · Renderer
├── Pipeline/       StillImageStage · SegmentationStage · BlitStage
├── Segmentation/   SegmentationProvider 协议 · CoreMLSegmentationProvider
└── Shaders/        Blit.metal（blit_vertex / blit_fragment / blit_fragment_gray）
```

- 工程用**同步文件夹**（决策 D12）：新增源文件无需改 `project.pbxproj`，实测有效。
- `.mlpackage` 被 Xcode 自动编译为 `humansegv2portrait.mlmodelc` 并随包；代码同时兼容
  `mlmodelc` / `mlpackage` 两种形态。
- `RenderStage`（GPU 阶段，可输出到纹理或 drawable）与 `TextureProducer`（CPU 生产者）
  拆分；公共 `outputHandle` 统一取句柄。

### 13.2 实施中修掉的四个问题

| # | 问题 | 根因 | 解法 |
| --- | --- | --- | --- |
| 1 | Metal 编译报 `cannot execute tool 'metal'` | Xcode 26 起 Metal 工具链需单独下载 | `xcodebuild -downloadComponent MetalToolchain`（约 700 MB） |
| 2 | **画面从第 2 帧起全黑** | `FrameContext` 每帧新建，persistent 纹理每帧都从池里拿到**新空纹理**，而 producer 的 dirty 标志已清不再重传 | Renderer 持有 `persistentTextures[handle]`，跨帧复用同一张纹理 |
| 3 | 纹理回收与 in-flight 命令缓冲竞争 | 帧尾立刻把纹理还池，GPU 可能还在用 | 回收移入 `addCompletedHandler` |
| 4 | mask 显示成**红色** | `r8Unorm` 采样得到 `(r,0,0,1)`，直接输出只有红通道有值 | 新增 `blit_fragment_gray` 复制 r 通道（对齐上游 `segment_postprocess_shader.glsl` 的 `.xxx`） |

另有一处协议设计修正：`PipelineNode.output`（可选，nil=drawable）与
`TextureProducer.output`（非可选）类型冲突，改为在子协议中各声明、用 `outputHandle` 统一取用。

### 13.3 验证

| 项 | 结果 |
| --- | --- |
| 模拟器编译 / 运行 | ✅ |
| 真机 arm64 编译 | ✅（`-sdk iphoneos`，未签名） |
| Core ML 加载 | ✅ `humansegv2portrait.mlmodelc`，输入 256×144 |
| 分割耗时（模拟器 CPU） | 81.3 ms |
| mask 前景占比 | **9.9%**，与 Python 侧 ONNX/Core ML 完全一致 |
| 屏幕输出 | 左半原图（均值 165.9）、右半 mask（人像剪影，灰度三通道均值 22.3/23.1/24.7） |

> 真机（iPhone 16）部署时设备处于 unavailable 离线状态，待连线后补部署验证。
>
> 模拟器实测截图：`docs/p1-simulator.png`（App 锁横屏，截图为竖屏采集，内容旋转 90°；
> 上部为原图面板、下部为 mask 面板）。


---

## 14. P2–P5 实施记录

### 14.1 交付清单

| 层 | 文件 | 内容 |
| --- | --- | --- |
| 几何 | `Geometry/` | `Primitives`（LineSegment/Quad/面积）· `HoughLineDetector`（替代 `Imgproc.HoughLines`）· `BiggestQuad`（含 `fixupQuad`/`makeQuadConvex`/角度校验）· `PointSmoother`（20 帧加权）· `Homography`（simd 单应）· `CornerTracker`（自动/手动状态机） |
| 相机 | `Camera/` | `FrameSource` 协议 · `CameraFrameSource`（AVCaptureSession + CVMetalTextureCache 零拷贝）· `StillImageFrameSource`（模拟器/静态图） |
| 管线 | `Pipeline/` | 26 个节点：`CameraStage` · 分割 5 阶段 · 边缘链 6 阶段 · `PerspectiveStage` · 增强 7 阶段 · `PresentStage` · `CornerOverlayStage` |
| 着色器 | `Shaders/` | 5 个 `.metal` 文件，21 个 GLSL 的对应实现 + `fs_perspective_lookup` |
| 文档 | `docs/glsl-to-msl.md` | 28 个 GLSL 的逐条对照 + 通用翻译规则 + 结构体对齐表 |
| 测试 | `DigiBoardTests/` | 15 个用例（几何 10 + 渲染 5） |

### 14.2 实施中修掉的七个问题

| # | 问题 | 根因 | 解法 |
| --- | --- | --- | --- |
| 1 | **透视校正完全没生效、累积器从未清零** | `prepare` 只写成协议扩展里的默认实现，`stage.prepare(ctx)` 走**静态派发**，子类实现永远不被调用，单应矩阵一直是单位矩阵 | 把 `prepare` 提升为**协议要求**（见 §14.3） |
| 2 | 霍夫一条直线都投不出来 | 上游阈值 150 是按全分辨率定的；我们在 1/4 降采样边缘图上跑，同一条边像素数少 4 倍 | 阈值按 `150 / scaleToSource` 折算，下限 25 |
| 3 | 管线依赖校验崩溃 | `CameraStage` 内部 `new` 了一个同名新句柄，没复用管线里的句柄，导致下游句柄"无生产者" | 构造函数改为接收句柄，不再自造 |
| 4 | 合法的反馈边被误判为非法 | 时序累积的"上一帧"由排在后面的 `CopyStage` 产出 | 校验规则放宽：**只允许 persistent 纹理的反馈边**，并保留非持久反馈边的断言 |
| 5 | `ShaderPass` 无法被继承 | 声明成 `final class` | 去掉 `final`，让 `GrayscaleStage`/`ScaleStage`/`SaturateStage` 复用同一骨架 |
| 6 | `RenderStage.output` 可选性冲突 | 离屏阶段要非可选、上屏阶段要 nil | 拆成 `OffscreenRenderStage`（有 output）与 `DrawableRenderStage`（画到 drawable） |
| 7 | 调试视图里 mask 显示成红色 | `r8Unorm` 采样是 `(r,0,0,1)` | `PresentStage` 按 `pixelFormat` 自动切到 `fs_blit_gray` |

另有一处工程配置问题：手写工程默认 scheme 不含测试动作，且 `<TestPlans></TestPlans>` 空元素会让
xcodebuild 报 "not currently configured for the test action"。已改为手写共享 scheme 并移除该空元素。

### 14.3 最值得记的一条：Swift 协议扩展的静态派发

```swift
protocol PipelineNode: AnyObject { ... }
extension PipelineNode {
    func prepare(_ ctx: FrameContext) {}      // 只是默认实现
}
final class PerspectiveStage: OffscreenRenderStage {
    func prepare(_ ctx: FrameContext) { ... } // ❌ 永远不会被调用
}
// 调用点
stage.prepare(ctx)   // 静态派发 → 走扩展里的空实现
```

**后果是静默的**：编译通过、运行不报错，只是透视矩阵一直是单位矩阵、累积器一直是脏数据。
修法是把 `prepare` 写进协议体，使它成为**协议要求**，扩展只提供默认实现：

```swift
protocol PipelineNode: AnyObject {
    func prepare(_ ctx: FrameContext)   // ✅ 协议要求 → 动态派发
}
extension PipelineNode {
    func prepare(_ ctx: FrameContext) {}   // 默认实现
}
```

### 14.4 验证结果（模拟器）

模拟器没有相机，用 `StillImageFrameSource` 喂 `still_sample.jpg` 跑通整条管线。

| 项 | 结果 |
| --- | --- |
| 管线装配 | 26 个节点全部解析，依赖校验通过 |
| Core ML 加载 | `humansegv2portrait.mlmodelc`，输入 256×144 |
| 分割推理 | 首次约 81 ms（模拟器 CPU），前景占比 **9.9%**（与 Python 侧逐像素一致） |
| 边缘检测 | Canny 输出边缘像素 1444 / 48320（3.0%） |
| 霍夫直线 | 13 条 → 角度分组 A=5 / B=8 |
| 自动角点 | 检测到四边形 `(677,27) (689,355) (1183,71) (1181,-2)` |
| 透视校正 | 修复 `prepare` 前后输出平均差 **44.9**（证明矩阵确实生效） |
| 最终输出 | 提亮后的白板，显示区均值 209.6，高亮占比 86.5% |
| 单元测试 | **15 个全部通过** |
| 真机 arm64 编译 | ✅（`-sdk iphoneos`，未签名） |

> **待真机验证**：去遮挡效果（人走过时遮挡区被历史帧填上）、1080p 实测帧率、逐级视觉对照、
> 自动角点在真实白板场景下的稳定性。静态图测试里白板占满整个画面、没有外边框可供检测，
> 所以自动角点拾取到的是内部子区域——这在真实拍摄场景下会改善。


---

## 15. 真机联调记录

设备：iPhone 16（iOS 26），1920×1080 @30fps。

### 15.1 四个真机问题（均已修复）

| # | 现象 | 根因 | 解法 |
| --- | --- | --- | --- |
| 1 | 相机出的是 1080×1920 竖向缓冲区，与 2556×1179 横屏画布不匹配 | `videoRotationAngle = 90` 把原生 1920×1080 转成了竖向 | 改为 0°（旋转交给 `AVCaptureConnection`，不要在着色器里补） |
| 2 | 角点检测 **300ms**，且跑在命令缓冲完成回调里，把 30fps 拖到 **17.6fps** | 霍夫 + 四重循环四边形搜索是 CPU 重活，且堵在渲染线程 | 移到后台队列（渲染不再被堵）+ `maxLines` 50→20（约 39 万次迭代降到 1 万） |
| 3 | 自动角点**检出率 0**（找到 50 条直线却没有一个四边形通过） | 命中上游源码里注明的 LIMITATION：上游「先取面积最大、再判断是否合理」，不合理就整帧放弃；直线被延长到 2000px，大面积组合往往离谱，把合理的挤掉了 | 改为**只在角度合理的候选里取面积最大者** |
| 4 | 抓帧功能在模拟器上卡死 | 在 Metal 完成回调里新建命令缓冲并 `waitUntilCompleted()` → 死锁 | 改为帧内 blit 到 shared 暂存纹理，完成回调里异步回读 |

修复后的真机指标：

```
[STAT] 30.0fps 分割8ms   前景7.9%  角点148ms 20条  5次
[STAT] 30.0fps 分割16ms  前景5.9%  角点147ms 20条 47次
```

| 指标 | 结果 |
| --- | --- |
| 帧率 | **稳定 30fps**（修复前 17.6） |
| 分割推理 | **8–21 ms**（ANE 生效，模拟器 CPU 要 81ms） |
| 前景占比 | 5–8%（人像检测正常） |
| 角点检测 | 20 条直线，**检出率 100%**，约 150ms（后台线程，不影响帧率） |
| 检出示例 | `(205,147) (237,1056) (1704,1030) (1762,202)` |

### 15.2 白平衡「全白」的排查结论

抓帧显示最终输出 95.7% 为纯白，逐级抓帧定位到白平衡阶段（均值 248.6 / 97.9% > 200）。

用 Python 按同一公式复算并与 GPU 输出比对：

| 指标 | Python 复算 | GPU 实际 |
| --- | --- | --- |
| 均值 | 250.3 | 248.6 |
| >200 占比 | 97.8% | 97.9% |
| 平均差 | — | **9.1 / 255** |

**结论：白平衡是对上游公式的忠实移植，不是缺陷。** 公式 `out = 1 - 背景 + 原图` 本质是高通滤波：
只保留「比局部均值更暗」的内容。对测试图统计，只有 **2.7%** 的像素比局部均值暗 0.20 以上，
因此 97.8% 的像素必然输出为白。这套算法面向「白底 + 深色马克笔字」，
对「房间里的白板照片」这类大块低对比度内容，压成白色正是其设计行为。

> 因此判断增强效果的**唯一有效场景是真实白板 + 深色笔迹**；静态测试图不具代表性。
> 上游自带的测试图（`whiteboard.jpg` / `imageenhancementtest.png` 等）同样是房间照片，
> 并非白底黑字。

### 15.3 新增的开发期调试能力

真机上既没有可视控制台，`devicectl` 也不提供截图能力，因此新增：

| 环境变量 | 作用 |
| --- | --- |
| `DB_DEBUG_VIEW=<0..11>` | 直接显示指定中间结果（0 = 最终输出） |
| `DB_CAPTURE=<文件名>` | 把当前调试视图抓成 PNG 写入 App 的 Documents |
| `DB_CAPTURE_FRAME=<帧号>` | 指定第几帧抓取（默认 90） |

配合 `xcrun devicectl device copy from --domain-type appDataContainer` 可把真机渲染结果拉回本机分析。

### 15.4 待完成

- **白板场景验证**：把手机对准有深色笔迹的白板，确认最终输出保留笔迹、去遮挡生效
- 运行中掉线/锁屏后的恢复行为
- 角点检测仍有优化空间（150ms 虽不影响帧率，但占用后台 CPU）


---

## 16. 范围收敛：纯自动管线 + 离线视频测试（v0.6）

### 16.1 需求变更

| 变更 | 处置 |
| --- | --- |
| 不做角点检测与透视校正 | 删除 `Geometry/`（6 个文件）、`PerspectiveStage`、`Perspective.metal` 及对应单测；管线从 26 节点减到 17 |
| 不做拖动角点与点击切换 | 上一版已删除；本版继续清理无引用的 `BlitStage` / `StillImageStage` 与角点着色器函数 |
| 新增「离线视频测试」按钮 | `VideoFrameSource`（`AVAssetReader` + `CVMetalTextureCache` 零拷贝，循环播放）；UI 提供「切换到视频测试」与「选择视频…」；**模拟器无相机时默认走视频**，因此可直接在模拟器验证整条管线 |

### 16.2 测试素材

上游 README 的演示视频（`youtu.be/U0TRvTYuAUQ`）已不可访问，因此自制素材
`DigiBoard/Resources/sample_whiteboard.mp4`（1280×720 / 30fps / 6s）：

1. 用 P0 的 ONNX 分割模型把 `infront.jpg` 里的人抠出来（带 alpha）
2. 合成到静止的 `whiteboard.jpg` 背景上
3. 让人像从左到右横穿画面

**这是唯一能验证「时序去遮挡」的素材类型**——静态图里人永远不动，
历史缓冲里存的还是同一个人，原理上就抹不掉（实测 `cleaned ≡ source`，符合预期）。

### 16.3 三个隐藏 bug（都表现为"结果不对但看不出原因"）

| # | Bug | 现象 | 根因 |
| --- | --- | --- | --- |
| 1 | **`vs_quad` 的 uv 少了垂直翻转** | 遮罩永远圈不到人 | NDC 的 y 轴朝上、纹理 v 轴朝下。管线内每级全屏 pass 都翻转画面，经过**奇数级**的分支就与 Core ML 输出的 mask 垂直错位。`vs_blit` 里写对了，所以**上屏显示正常，掩盖了内部错位**——极难反推 |
| 2 | **`MLMultiArray` 用裸指针顺序读** | mask 只覆盖一条窄竖条，与源帧完全对不上 | Core ML 输出数组不保证连续存储，必须按 `strides` 索引；`dataPointer` + 线性下标会读到错位的行 |
| 3 | **抓帧回读 r8Unorm 按 4 字节/像素** | 诊断工具误导了一整轮 | 单通道纹理每行只有 `width` 字节；按 `width*4` 读会拿到错位数据，抓出来的 mask 与真实内容不符 |

> 第 3 条值得单独记：**诊断工具本身也会骗人**。当时日志显示分割前景 9.5%，
> 而抓帧图算出 2.4%，我一度怀疑模型，实际是抓帧回读的步长写错了。

### 16.4 去遮挡链路的两个改进

| 改进 | 原因 |
| --- | --- |
| 补上 mask 膨胀（上游 `OpenCVDilateStage` 的 5×5 矩形核） | 不膨胀的话人像边缘那一圈不会被历史帧替换，去遮挡后留下"人形轮廓" |
| 分割节流 5 帧 → **1 帧**（配合 `isBusy` 自我节流） | 5 帧意味着 mask 最多滞后 5 帧；人像快移时遮罩明显落后于人，**未被 mask 盖住的人像像素被当作"背景稳定"，从而把人烤进历史缓冲**，残影挥之不去 |

### 16.5 验证结果（模拟器 + 内置视频）

对照组是合成视频时使用的**干净白板背景真值**，因此在人像区域内
「`|cleaned − 背景|` 相对 `|source − 背景|` 的下降」就是去遮挡的去除率。

| 指标 | frameInterval=5 | =2 | **=1** |
| --- | --- | --- | --- |
| mask 与真实人像 IoU | 0.770 | 0.755 | **0.838** |
| 人像区 `|cleaned − 干净背景|` | 70.0 | 35.1 | **15.9** |
| 源帧同区域 `|source − 干净背景|` | 110.9 | 116.6 | 116.6 |
| **去除率** | 37% | 70% | **86%** |
| 非人像区 `|cleaned − source|` | — | — | **1.2**（背景正确使用当前帧） |
| 帧率 | 30fps | 30fps | **30fps** |
| 分割耗时 | 23ms | 25ms | 23–26ms |

### 16.6 工程规模变化

| | v0.5 | v0.6 |
| --- | --- | --- |
| Swift 文件 | 34 | 23 |
| Metal 文件 | 5 | 4 |
| 管线节点 | 26 | **17** |
| 单元测试 | 15 | 5（几何相关的随功能一并删除） |


---

## 17. 修复：选完视频后「解码器初始化失败」（v0.7）

### 17.1 两个叠加的根因

| # | 根因 | 说明 |
| --- | --- | --- |
| 1 | **安全作用域 URL + 临时收件箱** | 文件选择器给回的是 security-scoped URL，文件位于临时收件箱。不调用 `startAccessingSecurityScopedResource()` 时连 `FileManager.fileExists` 都会失败；而且系统随时可能清掉它；iCloud 上的文件还可能尚未下载到本地 |
| 2 | **陈旧模块掩盖了真实编译错误** | 排查中 App 本身存在编译错误（`AVURLAsset` 没有 `fileType` 属性）。该错误导致 App target 未产出新模块，测试一直链接上一次的旧模块，于是报出「`importVideo` is inaccessible due to 'private'」这种风马牛不相及的错误，白白绕了一圈 |

> 第 2 条值得记：**当报错与源码明显对不上时，先确认目标是否真的编译成功了**。
> `xcodebuild` 只 grep `BUILD SUCCEEDED` 很容易漏掉 —— 那次它打印的是测试目标的结果。

### 17.2 修复

- 导入流程改为：**开启安全作用域 → 拷贝进 `Documents/Videos` → 用沙盒内的副本**。
  一次拷贝同时解决权限、文件被清理、iCloud 未下载三个问题。
- 解码器错误类型化，报错可读可定位：

| 错误 | 触发条件 |
| --- | --- |
| `fileNotFound` | 文件不存在 |
| `permissionDenied` | 拿不到读取权限 |
| `noVideoTrack` | 文件里没有画面轨道（只有音频） |
| `invalidSize` | 视频尺寸无效 |
| `unreadable` | 不是可解析的视频 |

- 顺带修掉一处**性能回退**：上一版为修 strides bug 改成了逐元素下标访问，
  而 `MLMultiArray` 下标有 NSNumber 装箱开销，实测让分割耗时翻 3 倍（23ms → 80ms）。
  改为「先判连续、连续走裸指针，不连续才逐元素」后回到 48–67ms（模拟器 CPU）。

### 17.3 UI 重构

| 项 | 变更 |
| --- | --- |
| 输入源切换 | 从「切换到相机 / 切换到视频」这种含糊说法，改为 **「实时视频 / 离线视频」分段控件** |
| 选视频 | 做成卡片：渐变图标 + 文件名（中间截断）+ 胶囊形「更换」按钮 |
| 无相机场景 | 选中「实时视频」时给出提示，而不是静默失败 |

### 17.4 验证

新增 `VideoSourceTests`（6 个用例），连同原有测试共 **11 个全部通过**：

| 用例 | 覆盖 |
| --- | --- |
| `testOpensBundledVideo` | 内置视频能初始化解码器并解出 1280×720 帧 |
| `testMissingFileReportsFileNotFound` | 文件不存在 → 明确报 `fileNotFound` |
| `testNonVideoFileReportsUnreadable` | .mp4 后缀但内容不是视频 → 不崩，给出可读错误 |
| `testImportCopiesFileIntoDirectory` | 导入拷到目标目录，且拷贝后可独立解码 |
| `testImportOverwritesExistingFile` | 同名文件重复导入覆盖而非报错 |
| `testImportAddsExtensionWhenMissing` | 无扩展名的 URL 自动补全 |

另新增调试入口 `DB_PICK=<路径>`，走**与文件选择器完全相同的导入链路**便于自动化验证。
实测日志：

```
[Video] 已导入到沙盒: .../Documents/Videos/my_test_video.mp4
[PIPE] 输入=离线视频 1280x720，分割输入 256x144，节点 18
[Video] 首帧解码成功 1280x720
[STAT] 离线视频 前景 10.9%
```


---

## 18. 人像边缘叠影的排查与修复（v0.8）

### 18.1 现象

真机跑用户提供的 `2104_raw.MP4`（1920×1080 / HEVC Main 10 / HLG HDR / 29.97fps / 7.54s）时，
**人像边缘出现大量平行条纹状叠影**。

### 18.2 排查过程

| 步骤 | 手段 | 结论 |
| --- | --- | --- |
| 1 | 抓帧对比 `source` / `mask` / `stored` / `cleaned` | `source` 里人是平滑亮区；`stored`（历史缓冲）里同一区域变成密集梳齿条纹 → **人的边缘被反复写进了历史缓冲** |
| 2 | 把 mask 轮廓叠加到源帧 | mask 只盖住人的右半部分，**左侧前缘完全没被圈住** —— 典型的「mask 落后于人」形状 |
| 3 | 加埋点实测 mask 时效 | **滞后 1 帧（峰值 4）**；上游是同步推理，**0 帧滞后** |
| 4 | 离线逐帧跑分割模型量人的速度 | **1.5 → 3.2 px/帧**（256×144 尺度），折算 1920 宽为 11 → 24 px/帧 |

### 18.3 根因

**掩膜膨胀不是用来补运动的，它只负责抹掉分割模型的边界误差。**

上游 `OpenCVDilateStage` 用 5×5（半径 2px）就够，是因为它**同步推理、mask 零帧滞后**；
本移植为了不阻塞渲染线程把推理放到后台队列，mask 天然滞后 1 帧——而人一帧走 3.2px，
**2px 的膨胀盖不住 1 帧的运动**，前缘像素被当成「背景稳定」，于是把人的边缘写进历史，
每帧叠一层 → 梳齿状叠影。

### 18.4 修复与验证

把膨胀半径从 2px 放大到 5px（覆盖「滞后 1 帧 × 帧间位移」）。
这样**既保留了异步推理带来的 30fps**，又补上了滞后量——比上游的同步方案两者兼得。

| 指标 | 修复前（半径 2） | 修复后（半径 5） |
| --- | --- | --- |
| 人像区历史缓冲形态 | 密集梳齿条纹 | 平滑 |
| **高频能量**（梳齿强度） | 6.91 | **2.75（降 60%）** |
| 帧率 | 30.0fps | 30.1fps |
| 分割耗时 | 8–9ms | 7–8ms |

### 18.5 遗留的工程改进项

mask 滞后是异步推理的固有代价（当前 1 帧）。若要彻底归零，需要像上游那样把
「回读 + 推理」插进同一帧内（拆成两个命令缓冲并等待），代价是帧率下降。
当前用膨胀补偿的方案是两者之间的更优权衡；若将来遇到更快的人像运动
（例如 60fps 素材或快速跑动），可继续加大半径或引入运动方向的自适应膨胀。


---

## 11. 变更记录

| 版本 | 日期 | 说明 |
| --- | --- | --- |
| v0.8 | 2026-10-09 | **修复人像边缘叠影**：实测出 mask 滞后 1 帧（上游同步推理为 0 帧）而人每帧移动 3.2px，2px 的膨胀盖不住 → 边缘被写进历史缓冲形成梳齿状叠影；膨胀半径 2→5 后高频能量降 60%，帧率仍 30fps |
| v0.7 | 2026-10-09 | **修复选完视频打不开**：根因是安全作用域 URL + 临时收件箱（改为开作用域后拷贝进沙盒）；排查中发现「编译失败 → 旧模块 → 报错与源码对不上」的陷阱；解码器错误类型化；修掉 strides 读取引入的性能回退（80ms→48ms）；输入源改为「实时视频/离线视频」分段控件，选视频做成卡片。新增 6 个视频链路测试（共 11 个全过） |
| v0.6 | 2026-10-08 | **范围收敛 + 离线视频测试**：移除角点检测与透视校正（26→17 节点）；新增 `VideoFrameSource` 与「视频测试」按钮，模拟器可直接验证整条管线；自制"真人走过静止白板"测试素材。修三个隐藏 bug（`vs_quad` 缺垂直翻转、`MLMultiArray` 未按 strides 读、抓帧 r8Unorm 步长错），补上 mask 膨胀、分割节流 5→1 帧。**去遮挡去除率 37% → 86%**，30fps 稳定 |
| v0.5 | 2026-10-08 | **真机联调**：相机朝向修正（1920×1080 横屏）、角点检测移出渲染线程（fps 17.6→30）、修掉上游 LIMITATION 使角点检出率 0→100%、抓帧死锁修复；新增 `DB_CAPTURE` 真机抓帧能力；白平衡经 Python 复算确认为忠实移植（平均差 9.1/255） |
| v0.4 | 2026-10-08 | **P2–P5 代码完成**：相机零拷贝管线、26 节点完整管线、`simd` 单应透视校正、自动角点检测（霍夫+四边形+平滑）、图像增强、交互控制条、15 个单元测试、`docs/glsl-to-msl.md`。记录 7 个实施问题，其中最关键的是 Swift 协议扩展静态派发导致 `prepare` 从不执行（透视矩阵一直为单位矩阵） |
| v0.3 | 2026-10-08 | **P1 完成**：手写同步文件夹工程 + Metal 渲染骨架（MetalContext/TexturePool/RenderStage/Renderer）+ Core ML 分割阶段 + 静态图与原图同屏；修掉 4 个实施问题（Metal 工具链、持久纹理每帧重分配导致黑屏、纹理回收竞争、r8Unorm 显示成红色）；真机 arm64 编译通过 |
| v0.2 | 2026-10-08 | **P0 完成**：pdmodel→ONNX→Core ML 全链路打通，模型 1.9 MB，ONNX↔Core ML 不一致像素 0.073% / 前景 IoU 0.9926；记录 6 个转换卡点与解法（见 §12）；新增 `scripts/model-convert/` 工具链与说明 |
| v0.1 | 2026-10-08 | 初始版本。完成上游 Android 版盘点（96 文件 / 28 着色器 / 模型归属确认 / 7 项缺陷发现），确定 D1–D14 架构决策、管线与着色器映射、P0–P5 分期与验收标准 |

---

**文档所有者**：单人开发　·　**审核状态**：方案已定稿，待开工 P0
