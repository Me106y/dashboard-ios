#!/usr/bin/env python3
"""
P0 验证脚本：在真实白板照上跑 ONNX / Core ML，输出 mask 与对照图。

PaddleSeg PP-HumanSegV2 的预处理（对应 deploy.yaml 的 Resize + Normalize）：
    resize -> 256x144 (w,h)  ->  /255  ->  (x - 0.5) / 0.5   [mean=std=0.5]

用法:
    scripts/.venv/bin/python scripts/model-convert/03_run_and_visualize.py [图片路径]
"""
from __future__ import annotations

import pathlib
import sys

import numpy as np
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "output"
OUT.mkdir(parents=True, exist_ok=True)

W, H = 256, 144
DEFAULT_IMG = "/Users/Zhuanz/Desktop/DigiBoard/WhiteboardApp-main/app/src/main/res/drawable/infront.jpg"
MEAN = np.array([0.5, 0.5, 0.5], dtype=np.float32)
STD = np.array([0.5, 0.5, 0.5], dtype=np.float32)


def preprocess(img: Image.Image) -> np.ndarray:
    """PIL 图 -> NCHW float32 [1,3,144,256]"""
    rgb = img.convert("RGB").resize((W, H), Image.BILINEAR)
    x = np.asarray(rgb, dtype=np.float32) / 255.0          # HWC in [0,1]
    x = (x - MEAN) / STD                                   # Normalize
    x = np.transpose(x, (2, 0, 1))[None, ...]              # NCHW
    return np.ascontiguousarray(x, dtype=np.float32)


def run_onnx(x: np.ndarray) -> np.ndarray:
    import onnxruntime as ort
    sess = ort.InferenceSession(str(OUT / "humansegv2portrait.onnx"),
                                providers=["CPUExecutionProvider"])
    return sess.run(None, {sess.get_inputs()[0].name: x})[0]


def run_coreml(x: np.ndarray) -> np.ndarray:
    import coremltools as ct
    model = ct.models.MLModel(str(OUT / "humansegv2portrait.mlpackage"))
    # Core ML 使用图像输入，这里直接从归一化张量换算回 0-255 的图
    img = ((x[0].transpose(1, 2, 0) * STD + MEAN) * 255.0).clip(0, 255).astype(np.uint8)
    out = model.predict({"image": Image.fromarray(img)})
    key = [k for k in out if "mask" in k.lower()][0]
    return np.asarray(out[key])


def save_visuals(img: Image.Image, mask: np.ndarray, tag: str) -> None:
    small = img.convert("RGB").resize((W, H), Image.BILINEAR)
    m = (mask.reshape(H, W) > 0).astype(np.uint8)
    mask_img = Image.fromarray(m * 255, mode="L")

    # 三图横排：原图 | mask | 叠加
    overlay = np.asarray(small).copy()
    sel = m.astype(bool)
    overlay[sel] = (0.45 * overlay[sel] + 0.55 * np.array([255, 60, 60])).astype(np.uint8)
    overlay_img = Image.fromarray(overlay)

    strip = Image.new("RGB", (W * 3 + 16, H), (255, 255, 255))
    strip.paste(small, (0, 0))
    strip.paste(mask_img.convert("RGB"), (W + 8, 0))
    strip.paste(overlay_img, (2 * W + 16, 0))
    strip = strip.resize((strip.width * 2, strip.height * 2), Image.NEAREST)
    p = OUT / f"compare_{tag}.png"
    strip.save(p)
    print(f"  对照图: {p}")

    fg = float(m.mean())
    ys, xs = np.nonzero(m)
    if len(xs):
        print(f"  前景占比: {fg*100:.1f}%  前景包围盒: x[{xs.min()},{xs.max()}] y[{ys.min()},{ys.max()}]")
    else:
        print(f"  前景占比: {fg*100:.1f}%  (无前景!)")


def main() -> None:
    img_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_IMG
    print(f"输入图: {img_path}")
    img = Image.open(img_path)
    print(f"原始尺寸: {img.size}")

    x = preprocess(img)

    print("\n[ONNX]")
    onnx_mask = run_onnx(x)
    print(f"  输出 shape={onnx_mask.shape} dtype={onnx_mask.dtype} 取值={np.unique(onnx_mask)}")
    save_visuals(img, onnx_mask, "onnx")

    mlp = OUT / "humansegv2portrait.mlpackage"
    if mlp.exists():
        print("\n[Core ML]")
        try:
            cm_mask = run_coreml(x)
            print(f"  输出 shape={cm_mask.shape} dtype={cm_mask.dtype} 取值={np.unique(cm_mask)}")
            save_visuals(img, cm_mask, "coreml")
            a = (onnx_mask.reshape(H, W) > 0)
            b = (np.asarray(cm_mask).reshape(H, W) > 0)
            diff = float((a != b).mean())
            iou = float((a & b).sum() / max((a | b).sum(), 1))
            print(f"\n  ONNX vs Core ML: 不一致像素={diff*100:.3f}%  前景 IoU={iou:.4f}")
        except Exception as exc:
            print(f"  Core ML 推理失败: {type(exc).__name__}: {exc}")
    else:
        print("\n(Core ML 模型尚未生成，跳过对照)")


if __name__ == "__main__":
    main()
