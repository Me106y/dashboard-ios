#!/usr/bin/env python3
"""恢复质量评估：干净参考图 vs 处理后的视频（逐帧 PSNR / SSIM / 时序一致性）。

用法
----
    # 最简：一张无遮挡的干净白板 + 处理后的视频
    python eval_restoration_video.py --reference ref.png --restored restored.mp4

    # 再给一份原始（未处理）视频：自动推导逐帧遮挡区域，额外输出「仅遮挡区」口径
    python eval_restoration_video.py --reference ref.png --restored restored.mp4 --input raw.mp4

    # 也可以显式给掩膜目录（frame_000001.png ...，白色 = 被遮挡/需要恢复）
    python eval_restoration_video.py --reference ref.png --restored restored.mp4 --mask-dir masks/

为什么需要「仅遮挡区」口径
--------------------------
未遮挡的像素在恢复输出里本来就是照抄，占比通常在 90% 以上。只报全帧指标会被这批
"白送" 的像素抬高到没有区分度，所以同时报全帧与仅遮挡区两个口径。

口径与 iOS 侧 `RestorationMetrics.swift` 保持一致：
亮度通道（0.299R + 0.587G + 0.114B）、SSIM 用 11×11 高斯窗 σ=1.5、
C1=(0.01·255)²、C2=(0.03·255)²、data_range=255。

注意：PSNR / SSIM 是全参考指标，参考必须是**同一机位、内容未变化**的干净白板。
一旦画面内容在录制期间被写过/擦过，参考对那段就失效了——那属于内容变化，不是算法
误差。建议把评估限制在内容未变的片段，或分段各自取参考。
"""

import argparse
import csv
import os
import sys

import cv2
import numpy as np


# ---------------------------------------------------------------- 基础指标

def to_luma(bgr):
    """BGR uint8 -> 亮度 float32（0…255）。"""
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)


def psnr(a, b, mask=None):
    diff = (a - b).astype(np.float64)
    if mask is not None:
        if mask.sum() == 0:
            return float("nan")
        mse = float((diff[mask] ** 2).sum()) / float(mask.sum())
    else:
        mse = float((diff ** 2).mean())
    if mse <= 0:
        return 100.0
    return min(10.0 * np.log10(255.0 * 255.0 / mse), 100.0)


def _ssim_map(a, b):
    window = 11
    sigma = 1.5
    c1 = (0.01 * 255.0) ** 2
    c2 = (0.03 * 255.0) ** 2

    def blur(x):
        return cv2.GaussianBlur(x, (window, window), sigma,
                                borderType=cv2.BORDER_REPLICATE)

    mu_a = blur(a)
    mu_b = blur(b)
    mu_aa = blur(a * a)
    mu_bb = blur(b * b)
    mu_ab = blur(a * b)

    var_a = mu_aa - mu_a * mu_a
    var_b = mu_bb - mu_b * mu_b
    cov_ab = mu_ab - mu_a * mu_b

    num = (2 * mu_a * mu_b + c1) * (2 * cov_ab + c2)
    den = (mu_a * mu_a + mu_b * mu_b + c1) * (var_a + var_b + c2)
    return num / den


def ssim(a, b, mask=None):
    m = _ssim_map(a, b).astype(np.float64)
    if mask is None:
        return float(m.mean())
    if mask.sum() == 0:
        return float("nan")
    return float(m[mask].mean())


def mean_abs_diff(a, b, mask=None):
    d = np.abs(a - b).astype(np.float64)
    if mask is None:
        return float(d.mean())
    if mask.sum() == 0:
        return float("nan")
    return float(d[mask].mean())


# ---------------------------------------------------------------- 遮挡区域

def occlusion_from_pair(input_frame, reference, thresh, dilate):
    """原始帧 vs 参考：差异大的地方基本就是 presenter 遮挡。"""
    diff = np.abs(input_frame.astype(np.float32) - reference.astype(np.float32))
    diff = diff.max(axis=2)
    mask = (diff > thresh).astype(np.uint8) * 255
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, k)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, k)
    if dilate > 0:
        kd = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (dilate * 2 + 1,) * 2)
        mask = cv2.dilate(mask, kd)
    return mask > 0


def load_mask(mask_dir, index, size, patterns=("frame_%06d.png", "frame_%06d.jpg",
                                                "%06d.png", "%d.png")):
    for pat in patterns:
        path = os.path.join(mask_dir, pat % index)
        if os.path.exists(path):
            m = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
            if m is None:
                return None
            if (m.shape[1], m.shape[0]) != size:
                m = cv2.resize(m, size, interpolation=cv2.INTER_NEAREST)
            return m > 127
    return None


# ---------------------------------------------------------------- 主流程

def parse_args():
    p = argparse.ArgumentParser(
        description="恢复质量评估：干净参考图 vs 处理后的视频（逐帧 PSNR / SSIM）")
    p.add_argument("--reference", required=True, help="无遮挡的干净白板参考图")
    p.add_argument("--restored", required=True, help="处理后的视频")
    p.add_argument("--input", default=None,
                   help="原始（未处理）视频；给了就自动推导逐帧遮挡区域")
    p.add_argument("--mask-dir", default=None,
                   help="逐帧遮挡掩膜目录（与 --input 二选一，优先用掩膜）")
    p.add_argument("--roi", nargs=4, type=int, default=None,
                   metavar=("X", "Y", "W", "H"), help="白板 ROI，按参考图尺寸")
    p.add_argument("--occ-thresh", type=int, default=25,
                   help="由 --input 推导遮挡区域时的灰度差阈值（默认 25）")
    p.add_argument("--occ-dilate", type=int, default=6,
                   help="遮挡掩膜膨胀半径，抵消边缘误差（默认 6）")
    p.add_argument("--flicker-tol", type=int, default=8,
                   help="判定「该像素已恢复正确」的灰度容差（默认 8）")
    p.add_argument("--max-frames", type=int, default=0, help="只跑前 N 帧，0 = 全部")
    p.add_argument("--csv", default=None, help="逐帧明细 CSV 输出路径")
    p.add_argument("--quiet", action="store_true", help="不打印逐帧进度")
    return p.parse_args()


def main(args):
    reference = cv2.imread(args.reference, cv2.IMREAD_COLOR)
    if reference is None:
        sys.exit("读不到参考图：%s" % args.reference)
    height, width = reference.shape[:2]
    if args.roi:
        x, y, w, h = args.roi
        roi = np.zeros((height, width), dtype=bool)
        roi[y:y + h, x:x + w] = True
    else:
        roi = np.ones((height, width), dtype=bool)

    ref_luma = to_luma(reference)

    cap_res = cv2.VideoCapture(args.restored)
    if not cap_res.isOpened():
        sys.exit("读不到视频：%s" % args.restored)
    cap_in = cv2.VideoCapture(args.input) if args.input else None
    if cap_in is not None and not cap_in.isOpened():
        sys.exit("读不到输入视频：%s" % args.input)

    total = int(cap_res.get(cv2.CAP_PROP_FRAME_COUNT)) or 0
    print("参考图 %dx%d；处理视频约 %d 帧%s" % (
        width, height, total,
        ("，ROI x=%d y=%d w=%d h=%d" % tuple(args.roi)) if args.roi else "，全帧"))
    if args.input and not args.mask_dir:
        print("遮挡区域：由 --input 与参考图逐帧推导（阈值 %d，膨胀 %d px）"
              % (args.occ_thresh, args.occ_dilate))
    elif args.mask_dir:
        print("遮挡区域：读取掩膜目录 %s" % args.mask_dir)
    else:
        print("遮挡区域：未提供（只给全帧口径）")

    rows = []
    prev_luma = None
    index = 0
    while True:
        ok, frame = cap_res.read()
        if not ok:
            break
        if frame.shape[1] != width or frame.shape[0] != height:
            frame = cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)
        cur_luma = to_luma(frame)

        occ = None
        if args.mask_dir:
            occ = load_mask(args.mask_dir, index, (width, height))
        elif cap_in is not None:
            ok_in, frame_in = cap_in.read()
            if ok_in:
                if frame_in.shape[1] != width or frame_in.shape[0] != height:
                    frame_in = cv2.resize(frame_in, (width, height),
                                          interpolation=cv2.INTER_AREA)
                occ = occlusion_from_pair(frame_in, reference,
                                          args.occ_thresh, args.occ_dilate)
        occ_roi = (occ & roi) if occ is not None else None

        row = {
            "frame": index,
            "psnr_full": psnr(cur_luma, ref_luma, roi),
            "ssim_full": ssim(cur_luma, ref_luma, roi),
            "mae_full": mean_abs_diff(cur_luma, ref_luma, roi),
            "occ_ratio": float(occ_roi.mean()) if occ_roi is not None else float("nan"),
            "psnr_occ": (psnr(cur_luma, ref_luma, occ_roi)
                         if occ_roi is not None else float("nan")),
            "ssim_occ": (ssim(cur_luma, ref_luma, occ_roi)
                         if occ_roi is not None else float("nan")),
            "mae_occ": (mean_abs_diff(cur_luma, ref_luma, occ_roi)
                        if occ_roi is not None else float("nan")),
        }
        if prev_luma is not None:
            row["mad_prev_full"] = mean_abs_diff(cur_luma, prev_luma, roi)
            # 只统计「本来就已恢复正确」的像素抖不抖——那才是闪烁
            matched = (np.abs(prev_luma - ref_luma) <= args.flicker_tol) & \
                      (np.abs(cur_luma - ref_luma) <= args.flicker_tol) & roi
            row["flicker_matched"] = mean_abs_diff(cur_luma, prev_luma, matched)
        else:
            row["mad_prev_full"] = float("nan")
            row["flicker_matched"] = float("nan")
        rows.append(row)
        prev_luma = cur_luma

        if not args.quiet and (index + 1) % 100 == 0:
            print("  ... %d 帧" % (index + 1))
        index += 1
        if args.max_frames and index >= args.max_frames:
            break

    cap_res.release()
    if cap_in is not None:
        cap_in.release()

    if not rows:
        sys.exit("视频里没读到任何帧")

    def summary(key):
        vals = np.array([r[key] for r in rows], dtype=np.float64)
        vals = vals[~np.isnan(vals)]
        if vals.size == 0:
            return None
        return dict(mean=float(vals.mean()),
                    median=float(np.median(vals)),
                    p5=float(np.percentile(vals, 5)),
                    p95=float(np.percentile(vals, 95)),
                    n=int(vals.size))

    print("\n================ 汇总（%d 帧）================" % len(rows))
    for key, label in (("psnr_full", "PSNR 全帧 (dB)"),
                       ("ssim_full", "SSIM 全帧"),
                       ("mae_full", "MAE 全帧 (灰度级)"),
                       ("occ_ratio", "遮挡区占比"),
                       ("psnr_occ", "PSNR 仅遮挡区 (dB)"),
                       ("ssim_occ", "SSIM 仅遮挡区"),
                       ("mae_occ", "MAE 仅遮挡区 (灰度级)"),
                       ("mad_prev_full", "帧间 MAD 全帧"),
                       ("flicker_matched", "闪烁（已正确像素上的帧间 MAD）")):
        s = summary(key)
        if s is None:
            continue
        print("%-38s mean %8.4f   median %8.4f   p5 %8.4f   p95 %8.4f"
              % (label, s["mean"], s["median"], s["p5"], s["p95"]))

    csv_path = args.csv or os.path.join(
        os.path.dirname(os.path.abspath(args.restored)),
        "restoration_metrics_per_frame.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print("\n逐帧明细已写入：%s" % csv_path)


if __name__ == "__main__":
    main(parse_args())
