# 模型转换：PP-HumanSegV2 portrait → Core ML

把上游 Android 版打包的 PaddleSeg 推理模型转成 iOS 可用的 Core ML 模型。

## 事实前提

- 上游 App 实际加载的是 **PaddleSeg 官方 `PP-HumanSegV2 portrait`**
  （MobileNetV3 骨干 + PPHumanSegHead/ASPP），不是 `model/` 目录里那套自研的
  `MobileSegV2 + RepViT`。见 PRD「关键发现 01」。
- 输入张量 `[1, 3, 144, 256]`（`deploy.yaml` 的 `target_size: [256,144]` 是 PaddleSeg 的 `(w,h)`）。
- 模型输出是 **ArgMax 的 int64 标签图**，不是概率图。

## 工具链

独立 venv，不动系统 Python（本机系统 Python 是 3.9，太老）：

```bash
/opt/homebrew/bin/python3.12 -m venv scripts/.venv
scripts/.venv/bin/python -m pip install -r scripts/requirements.txt
scripts/.venv/bin/python -m pip install setuptools   # paddle 需要
```

## 用法

```bash
# 1) Paddle 推理模型 -> 固定形状 ONNX（含多项图修复）
scripts/.venv/bin/python scripts/model-convert/01_pdmodel_to_onnx.py

# 2) ONNX -> PyTorch -> TorchScript -> Core ML
scripts/.venv/bin/python scripts/model-convert/02_onnx_to_coreml.py

# 3) 在真实白板照上跑，出对照图并比对 ONNX / Core ML
scripts/.venv/bin/python scripts/model-convert/03_run_and_visualize.py
```

## 踩过的坑（重要）

> 这些不是理论风险，是实际卡住过的点，按顺序记录。

1. **自适应池化转坏**
   `paddle2onnx` 面对动态输入 `(-1,3,-1,-1)` 无法推导 ASPP 里 `AdaptiveAvgPool` 的
   kernel/stride，导出物中会留下 `kernel_shape=[-1,-1]`、`strides=[0,0]` 的非法
   `AveragePool`，ONNX Runtime 直接拒绝加载。
   **解法**：先钉死输入形状，再按 Paddle 语义
   （`start=floor(i*H/oh)`、`end=ceil((i+1)*H/oh)`）换算成等价固定核。
   实测：ASPP 输入特征图 `9×16`，三支分别池化到 `1×1 / 2×2 / 4×4`，
   2×2 用 `kernel=[5,8] stride=[4,8]`，4×4 用 `kernel=[3,4] stride=[2,4]`。

2. **Paddle 3.x 读不了旧格式模型**
   试图用 paddle ≥ 3.0 配合 `paddle2onnx 2.x`（其 CLI 才支持 `input_shape_dict`），
   结果 `load_inference_model` 走 PIR 分支，
   抛 `UnicodeDecodeError: 'utf-8' codec can't decode byte 0xf5`。
   **结论**：必须用 **paddlepaddle 2.6.2**（有 `macosx_11_0_arm64` + `cp312` 轮子）。

3. **coremltools 没有 ONNX 前端**
   自 **7.0** 起移除，8.x 只剩 TensorFlow / PyTorch 两个 source；
   本机试装 7.2 还出现 `libcoremlpython` / `libmilstoragepython` 加载失败。
   **解法**：走官方支持路线 `ONNX --onnx2torch--> torch --trace--> Core ML`。

4. **权重被内联成 Constant**
   `paddle2onnx` 把全部 414 个权重导出成 `Constant` 节点，而 `onnx2torch`
   只从 `graph.initializer` 取卷积权重，直接 `KeyError`。
   **解法**：规范化——把 `Constant` 提升为 `initializer`。

5. **`auto_pad: SAME_UPPER` 不被 onnx2torch 支持**
   **解法**：输入形状既然已固定，就按 ONNX 规则把 19 个 `SAME_*` 全部展开成显式 `pads`。
   注意 ONNX 形状推导要开 **`data_prop=True`**，否则 `Shape/Slice/Concat`
   那条常量分支推不出来，下游卷积输入形状会变成 `unk__`。

6. **Core ML 图像预处理 pass 的两个形状陷阱**（源码
   `.../mil/passes/insert_image_preprocessing_op.py`）
   - `scale` 直接参与广播 → **必须是标量**，传 `[s,s,s]` 会报
     `Incompatible dim 3 in shapes (1,3,144,256) vs (1,1,1,3)`
   - `bias` 会被 reshape 成 `[1,3,1,1]` → **必须按通道给三元组**，传标量会报
     `cannot reshape array of size 1 into shape (1,3,1,1)`

## 产物

| 文件 | 说明 |
| --- | --- |
| `output/humansegv2portrait.onnx` | 固定形状 ONNX，`[1,3,144,256] f32 → [1,144,256] i32` |
| `output/humansegv2portrait.mlpackage` | Core ML mlProgram，图像输入 256×144 RGB，输出 `[1,144,256] INT32`，1.9 MB |
| `output/compare_onnx.png` | 原图 / ONNX mask / 叠加 |
| `output/compare_coreml.png` | 原图 / Core ML mask / 叠加 |

## 验证结果（2026-10-08）

测试图 `infront.jpg`（4032×1908，人在白板前）：

| 指标 | ONNX | Core ML |
| --- | --- | --- |
| 前景占比 | 9.9% | 9.8% |
| 前景包围盒 | x[122,190] y[31,143] | x[122,190] y[31,143] |

**一致性**：不一致像素 **0.073%**，前景 **IoU 0.9926**。
（比原定数值闸门「≤1% 不一致 / IoU ≥0.98」更严，且已满足。）

## 归一化（App 侧需与此一致）

对应 `deploy.yaml` 的 `Normalize`，mean=std=0.5：

```
x' = (x/255 - 0.5) / 0.5
```

该式已编进 Core ML 模型的 `ImageType`（`scale = 1/127.5`，`bias = -1.0`），
因此 **App 直接喂 0–255 的 RGB 图像即可**，不要再归一化一次。
