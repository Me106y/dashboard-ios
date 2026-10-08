#!/usr/bin/env python3
"""
生成离线测试视频素材：真人横向走过静止白板。

为什么需要这个素材
------------------
去遮挡依赖「同一像素在别的时刻是干净的」这一前提，所以**静态图无法验证去遮挡**
（历史缓冲里存的还是同一个人）。上游 README 的演示视频已不可访问，
因此这里自制：用 P0 的 ONNX 分割模型把真人抠出、合成到静止白板背景上，
再让人像横穿画面——每块背景像素都会在某一刻露出来，正是时序重建能生效的场景。

产物
----
  fixtures/whiteboard_bg.jpg      静止白板背景（对照组真值）
  fixtures/sample_whiteboard.mp4  1280x720 / 30fps / 6s 循环
  fixtures/frames/                中间帧（已 gitignore，可重新生成）

用法
----
  scripts/.venv/bin/python scripts/model-convert/04_make_test_video.py
"""
from __future__ import annotations

import pathlib
import subprocess

import numpy as np
import onnxruntime as ort
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
FRAMES = FIXTURES / "frames"
ONNX = HERE / "output" / "humansegv2portrait.onnx"
SRC = pathlib.Path("/Users/Zhuanz/Desktop/DigiBoard/WhiteboardApp-main/app/src/main/res/drawable")

W, H = 256, 144            # 分割网络输入
OUT_W, OUT_H = 1280, 720   # 视频尺寸
FPS, SECONDS = 30, 6
FFMPEG = "/usr/local/bin/ffmpeg"


def segment(image: Image.Image, session: ort.InferenceSession) -> np.ndarray:
    rgb = image.convert("RGB").resize((W, H), Image.BILINEAR)
    x = np.asarray(rgb, dtype=np.float32) / 255.0
    x = (x - 0.5) / 0.5
    x = np.ascontiguousarray(x.transpose(2, 0, 1)[None])
    return session.run(None, {session.get_inputs()[0].name: x})[0][0] > 0


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    FRAMES.mkdir(exist_ok=True)
    for old in FRAMES.glob("*.png"):
        old.unlink()

    session = ort.InferenceSession(str(ONNX), providers=["CPUExecutionProvider"])

    # 1) 抠出「人在白板前」这张里的人
    person_src = Image.open(SRC / "infront.jpg").convert("RGB")
    mask = segment(person_src, session)
    print(f"人像 mask 前景占比 {(mask > 0).mean() * 100:.1f}%")

    mask_big = np.asarray(Image.fromarray((mask * 255).astype(np.uint8))
                          .resize(person_src.size, Image.NEAREST)) > 127
    rgba = np.dstack([np.asarray(person_src), (mask_big * 255).astype(np.uint8)])
    person = Image.fromarray(rgba, "RGBA")
    ys, xs = np.nonzero(mask_big)
    pad = 10
    person = person.crop((max(xs.min() - pad, 0), max(ys.min() - pad, 0),
                          min(xs.max() + pad, person.width), min(ys.max() + pad, person.height)))

    # 2) 静止白板背景（也是验证去遮挡时的真值）
    background = Image.open(SRC / "whiteboard.jpg").convert("RGB").resize((OUT_W, OUT_H), Image.LANCZOS)
    background.save(FIXTURES / "whiteboard_bg.jpg", quality=90)

    # 3) 逐帧合成
    person_h = int(OUT_H * 0.78)
    scale = person_h / person.height
    person_scaled = person.resize((int(person.width * scale), person_h), Image.LANCZOS)

    total = FPS * SECONDS
    for i in range(total):
        t = i / (total - 1)
        x = int(-person_scaled.width * 0.6 + t * (OUT_W + person_scaled.width * 0.2))
        y = OUT_H - person_h + 12
        frame = background.copy()
        frame.paste(person_scaled, (x, y), person_scaled)
        frame.save(FRAMES / f"f{i:04d}.png")
    print(f"生成 {total} 帧")

    # 4) 编码
    out = FIXTURES / "sample_whiteboard.mp4"
    subprocess.run([FFMPEG, "-y", "-loglevel", "error",
                    "-framerate", str(FPS), "-i", str(FRAMES / "f%04d.png"),
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "main",
                    "-movflags", "+faststart", str(out)], check=True)
    print(f"完成: {out}  ({out.stat().st_size / 1024:.0f} KB)")
    print(f"提示：把 {out.name} 拷到 DigiBoard/Resources/ 供 App 内使用")


if __name__ == "__main__":
    main()
