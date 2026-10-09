#!/usr/bin/env python3
"""
生成 App 图标（1024x1024，无透明通道，符合 Apple 规范）。

设计：白板 + 正在被擦除的人影
  —— 深色人像自左向右渐隐，板上的笔迹从人像身下透出来，
     正是 DigiBoard 在做的事：把人从白板画面里"擦掉"。

用法:
  scripts/.venv/bin/python scripts/assets/make_app_icon.py
"""
from __future__ import annotations

import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
HERE = pathlib.Path(__file__).resolve().parent
OUT_DIR = HERE.parent.parent / "DigiBoard" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

# 与 App 内主题一致的靛蓝
BG_TOP = (59, 116, 201)      # #3B74C9
BG_BOTTOM = (18, 36, 73)     # #122449
BOARD = (255, 255, 255)
INK = (34, 48, 63)           # #22303F
SILHOUETTE = (13, 26, 43)    # #0D1A2B


def gradient_background() -> Image.Image:
    """对角渐变背景"""
    y = np.linspace(0, 1, SIZE)[:, None]
    x = np.linspace(0, 1, SIZE)[None, :]
    t = np.clip((x * 0.35 + y * 0.65), 0, 1)[..., None]
    top = np.array(BG_TOP, dtype=np.float32)
    bottom = np.array(BG_BOTTOM, dtype=np.float32)
    rgb = (top * (1 - t) + bottom * t).astype(np.uint8)
    return Image.fromarray(rgb, "RGB")


def rounded_board(base: Image.Image) -> None:
    """白色白板 + 柔和投影"""
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [132, 232, 892, 826], radius=64, fill=(0, 0, 0, 110)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    base.paste(shadow, (0, 16), shadow)

    board = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(board).rounded_rectangle([120, 210, 904, 810], radius=60, fill=BOARD + (255,))
    base.paste(board, (0, 0), board)


def board_content(base: Image.Image) -> None:
    """板上的笔迹：两行"字" + 一个方框 + 一条箭头"""
    d = ImageDraw.Draw(base)
    d.rounded_rectangle([232, 322, 716, 378], radius=26, fill=INK)          # 第一行
    d.rounded_rectangle([232, 430, 560, 486], radius=26, fill=INK)          # 第二行
    d.rounded_rectangle([248, 566, 470, 740], radius=30, outline=INK, width=30)


def silhouette_layer() -> Image.Image:
    """人像剪影（头 + 肩），单独一层便于做渐隐"""
    layer = Image.new("L", (SIZE, SIZE), 0)
    d = ImageDraw.Draw(layer)
    d.ellipse([520, 214, 724, 418], fill=255)                               # 头
    d.rounded_rectangle([452, 430, 792, 810], radius=150, fill=255)         # 身体
    d.ellipse([452, 690, 792, 930], fill=255)                               # 肩部过渡
    return layer


def erase_mask() -> Image.Image:
    """
    擦除遮罩：自左向右渐隐的人像。
    左侧 30% 完全保留，到 78% 处完全消失 —— 制造"正在被抹掉"的观感。
    """
    x = np.linspace(0, 1, SIZE)[None, :].repeat(SIZE, axis=0)
    y = np.linspace(0, 1, SIZE)[:, None].repeat(SIZE, axis=1)
    # 擦除边界要"锐"：太小尺寸下宽渐变会糊成一团，锐边界才读得出"被擦掉一半"
    t = np.clip((x - 0.38) / (0.62 - 0.38), 0, 1)
    t = np.clip(t + (y - 0.5) * 0.30, 0, 1)          # 略带斜向
    alpha = ((1 - t) * 255).astype(np.uint8)
    return Image.fromarray(alpha, "L")


def main() -> None:
    icon = gradient_background()
    rounded_board(icon)
    board_content(icon)

    # 人像：用渐隐后的 alpha 贴到最上层
    sil = silhouette_layer()
    erase = erase_mask()
    alpha = Image.fromarray((np.asarray(sil).astype(np.float32) * np.asarray(erase).astype(np.float32) / 255).astype(np.uint8), "L")

    person = Image.new("RGBA", (SIZE, SIZE), SILHOUETTE + (0,))
    person.putalpha(alpha)
    icon = icon.convert("RGBA")
    icon.alpha_composite(person)

    # 擦除方向上加几道细白"划痕"，强化"正在擦"的感觉
    d = ImageDraw.Draw(icon)
    for i, (x0, y0, x1, y1) in enumerate([(566, 300, 640, 372), (596, 470, 676, 546), (566, 660, 646, 736)]):
        d.line([(x0, y0), (x1, y1)], fill=(255, 255, 255, 130 - i * 28), width=11)

    icon = icon.convert("RGB")                       # App 图标不能有透明通道
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / "AppIcon-1024.png"
    icon.save(out)
    print(f"已生成 {out}  ({icon.size[0]}x{icon.size[1]}, mode={icon.mode})")


if __name__ == "__main__":
    main()
