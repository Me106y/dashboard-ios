# DigiBoard iOS

移动端「数字无遮挡白板」系统的 **iOS 原生实现**。

> 相机取景 → 人像分割 → 时序背景重建（去遮挡）→ 透视校正 → 图像增强 → 全屏显示

本仓库是 [Me106y/DigiBoard](https://github.com/Me106y/DigiBoard) 的 Android 版在 iOS 上的
**算法对等、实现重写**版本。不是 Kotlin→Swift 的逐行翻译，而是用现代图形栈重写同一条算法链。

## 文档

| 文件 | 说明 |
| --- | --- |
| [`PRD.html`](PRD.html) | **产品与移植文档（推荐阅读，含导航与打印）** |
| [`PRD.md`](PRD.md) | 同一份文档的 Markdown 母本 |

打开方式：

```bash
open PRD.html
```

## 技术栈

- **图形**：Metal（`MTKView` + `CVMetalTextureCache`），21 个 MSL 着色器
- **推理**：Core ML（`PP-HumanSegV2 portrait`，pdmodel → ONNX → `.mlpackage`），ANE 加速
- **相机**：AVFoundation，1920×1080 @ 30fps，`32BGRA` 零拷贝
- **界面**：SwiftUI 外壳 + UIKit `MTKView` 画布
- **几何**：Swift + `simd`（霍夫直线、最大四边形、单应矩阵）

**零第三方二进制依赖。**

## 当前状态

**方案已定稿，待开工 P0。** 分六期交付：

| 期 | 内容 | 验收 |
| --- | --- | --- |
| P0 | 模型闸门：pdmodel → ONNX → Core ML | 视觉验收：mask 能合理抠出人像 |
| P1 | 渲染骨架 + 静态图 → mask | 真机同屏显示原图与 mask |
| P2 | 相机链路 + 去遮挡闭环 | 人走过时遮挡区被历史帧填上 |
| P3 | 透视校正（自动 / 手动） | 白板被摆正，双模式可切换 |
| P4 | 图像增强 | 逐级对照 Android 版视觉一致 |
| P5 | 交互与收尾 | 控件可用、单测通过、文档齐全 |

详见 [PRD](PRD.html) 的「分期计划与验收标准」。

## 目录结构

```
DigiBoard.xcodeproj     手写工程 + 同步文件夹（新增源文件无需改工程）
DigiBoard/              App 源码（App / Camera / Render / Pipeline /
                        Segmentation / Geometry / Shaders / Resources）
DigiBoardTests/         单元测试（几何、单应、纹理池）
docs/glsl-to-msl.md     28 个着色器的逐条移植对照
scripts/                模型转换与诊断脚本
PRD.md / PRD.html       本文档
```

## 环境

- Xcode 26.3 / iOS SDK 26.2 / Swift 6.2
- 最低部署目标 iOS 17.0
- 真机验证机：iPhone 16（Team `UW345FU9VD`，自动签名）

## 许可

上游项目为 Apache 2.0，本移植版沿用同一许可。
