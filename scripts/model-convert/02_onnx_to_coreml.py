#!/usr/bin/env python3
"""
P0 阶段二：固定形状 ONNX -> Core ML (.mlpackage)

为什么绕道 PyTorch：
  coremltools 自 7.0 起移除了 ONNX 前端（8.x 只剩 TensorFlow / PyTorch 两个 source），
  7.2 在本机还出现原生库加载不全的问题。所以走官方支持路线：
      ONNX --onnx2torch--> torch.nn.Module --torch.jit.trace--> TorchScript --coremltools--> Core ML

归一化（与 deploy.yaml 的 Normalize 一致）直接编进 Core ML 的 ImageType：
    scale = 1/127.5, bias = -1.0   =>   x/255 * 2 - 1  ==  (x/255 - 0.5) / 0.5

用法:
    scripts/.venv/bin/python scripts/model-convert/02_onnx_to_coreml.py
"""
from __future__ import annotations

import pathlib

import numpy as np
import torch
import coremltools as ct
import onnx
from onnx2torch import convert as onnx_to_torch

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "output"
ONNX_PATH = OUT / "humansegv2portrait.onnx"
MLPACKAGE = OUT / "humansegv2portrait.mlpackage"

W, H = 256, 144


def main() -> None:
    print("[1/4] ONNX -> PyTorch …")
    onnx_model = onnx.load(str(ONNX_PATH))
    module = onnx_to_torch(onnx_model)
    module.eval()
    print(f"  模块类型: {type(module).__name__}")

    print("[2/4] TorchScript 追踪 …")
    dummy = torch.randn(1, 3, H, W)
    with torch.no_grad():
        traced = torch.jit.trace(module, dummy, strict=False)
    ref = traced(dummy)
    ref_np = np.asarray(ref)
    print(f"  追踪输出: shape={ref_np.shape} dtype={ref_np.dtype} 取值={np.unique(ref_np)}")

    print("[3/4] 转 Core ML …")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 3, H, W),
            # 注意 coremltools 的 insert_image_preprocessing pass：
            #   scale 直接参与广播 -> 必须标量
            #   bias  会被 reshape 成 [1,3,1,1] -> 必须按通道给三元组
            scale=1.0 / 127.5,
            bias=[-1.0] * 3,
            color_layout=ct.colorlayout.RGB,
        )],
        outputs=[ct.TensorType(name="mask", dtype=np.int32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.short_description = "PP-HumanSegV2 portrait — 人像分割（256x144 -> 144x256 标签图）"
    mlmodel.input_description["image"] = "RGB 图像 256x144（0-255），内部按 Normalize(mean=std=0.5) 归一化"
    mlmodel.output_description["mask"] = "人像标签图 144x256，int32，取值 0/1"
    mlmodel.save(str(MLPACKAGE))
    print(f"  已保存: {MLPACKAGE}")

    print("[4/4] Core ML 自检 …")
    from PIL import Image
    # 用与 ONNX 相同的归一化输入核对（换算回 0-255 图像喂给 Core ML）
    x = dummy.numpy()
    img = ((x[0].transpose(1, 2, 0) * 0.5 + 0.5) * 255.0).clip(0, 255).astype(np.uint8)
    out = mlmodel.predict({"image": Image.fromarray(img)})
    m = np.asarray(out["mask"])
    print(f"  预测输出: shape={m.shape} dtype={m.dtype} 取值={np.unique(m)}")
    print(f"\n完成: {MLPACKAGE}")


if __name__ == "__main__":
    main()
