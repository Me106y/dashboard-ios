#!/usr/bin/env python3
"""
P0 阶段一：PaddleSeg 推理模型 (model.pdmodel + model.pdiparams) -> 固定形状 ONNX

背景（踩过的坑，记录在此以免重复踩）：
  * 该模型是 PaddleSeg PP-HumanSegV2 portrait（MobileNetV3 骨干 + PPHumanSegHead/ASPP）。
  * 模型图里输入是动态的 (-1, 3, -1, -1)，而 ASPP 用了 AdaptiveAvgPool。
    paddle2onnx 无法为「动态输入」推导自适应池化的 kernel/stride，
    导出的 ONNX 里会留下 kernel_shape=[-1,-1]、strides=[0,0] 的非法 AveragePool 节点，
    ONNX Runtime 直接拒绝加载（kernel_shape[dim] > 0 was false）。
  * 解法：把 ASPP 的每个自适应池化分支，按 Paddle 语义换算成等价固定核的 AveragePool。
      kernel = ceil(H / oh),  stride = floor(H / oh)
      Paddle: start = floor(i*H/oh), end = ceil((i+1)*H/oh)
    当窗口恰好铺满时（本例成立），二者逐窗口等价。
  * 另外：模型输出是 ArgMax 的 int64 标签图，Core ML 不支持 int64，统一 Cast 成 int32。

用法:
    scripts/.venv/bin/python scripts/model-convert/01_pdmodel_to_onnx.py
"""
from __future__ import annotations

import math
import pathlib
import sys

import numpy as np
import onnx
import onnxruntime as ort
import paddle2onnx
from onnx import helper, TensorProto

# ---------------------------------------------------------------- 配置
HERE = pathlib.Path(__file__).resolve().parent
SRC_DIR = HERE / "source" / "humansegv2portrait"
OUT_DIR = HERE / "output"
ONNX_PATH = OUT_DIR / "humansegv2portrait.onnx"

INPUT_NAME = "x"
# deploy.yaml 的 transforms.target_size 是 PaddleSeg 的 (w, h) = (256, 144)
INPUT_W, INPUT_H = 256, 144
OPSET = 14  # hard_swish 需要 >= 14

# ASPP 三个空间金字塔分支的目标输出尺寸（读自 Paddle 图的 pool2d ksize）
ASPP_OUTPUT_SIZES = [(2, 2), (4, 4)]


def export_onnx() -> None:
    """用 paddle2onnx 导出（动态输入，先拿到结构完整的图）"""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    paddle2onnx.export(
        model_filename=str(SRC_DIR / "model.pdmodel"),
        params_filename=str(SRC_DIR / "model.pdiparams"),
        save_file=str(ONNX_PATH),
        opset_version=OPSET,
        enable_onnx_checker=True,
        verbose=False,
    )


def pin_input_shape(model: onnx.ModelProto, w: int = INPUT_W, h: int = INPUT_H) -> None:
    """把输入张量钉成静态 NHWC 入口形状 NCHW=[1,3,h,w]"""
    for inp in model.graph.input:
        if inp.name != INPUT_NAME:
            continue
        dim = inp.type.tensor_type.shape.dim
        dim[0].dim_value = 1
        dim[1].dim_value = 3
        dim[2].dim_value = h
        dim[3].dim_value = w


def infer_shapes(model: onnx.ModelProto) -> dict[str, list]:
    try:
        # data_prop=True 让 Shape/Slice/Concat 等常量分支也能推出来，
        # 否则下游卷积的输入形状会变成 unk__，导致 auto_pad 无法展开
        inferred = onnx.shape_inference.infer_shapes(model, strict_mode=False, data_prop=True)
    except Exception as exc:  # 形状推导失败不应中断流程
        print(f"  [warn] shape inference 失败: {exc}", file=sys.stderr)
        inferred = model
    out = {}
    for vi in list(inferred.graph.value_info) + list(inferred.graph.output) + list(inferred.graph.input):
        tt = vi.type.tensor_type
        if tt.HasField("shape"):
            out[vi.name] = [d.dim_value or d.dim_param for d in tt.shape.dim]
    return out


def fix_adaptive_pools(model: onnx.ModelProto) -> int:
    """
    修复 paddle2onnx 留下的非法 AveragePool（自适应池化）。
    输出尺寸不同 -> kernel/stride 不同；这里按每个节点的输出通道数不变、
    并根据 ASPP 分支的目标输出尺寸逐一改写。
    """
    broken = [n for n in model.graph.node
              if n.op_type == "AveragePool"
              and any(a.name == "kernel_shape" and min(a.ints) <= 0 for a in n.attribute)]
    if len(broken) != len(ASPP_OUTPUT_SIZES):
        print(f"  [warn] 预期 {len(ASPP_OUTPUT_SIZES)} 个坏节点，实际 {len(broken)} 个")

    # 借用形状推导拿到池化输入的空间尺寸
    shapes = infer_shapes(model)
    src_name = broken[0].input[0]
    src_shape = shapes.get(src_name)
    if not src_shape or not isinstance(src_shape[2], int):
        raise RuntimeError(f"无法推导池化输入 {src_name} 的空间尺寸，得到 {src_shape}")
    in_h, in_w = int(src_shape[2]), int(src_shape[3])

    fixed = 0
    for node, (out_h, out_w) in zip(broken, ASPP_OUTPUT_SIZES):
        kernel = [math.ceil(in_h / out_h), math.ceil(in_w / out_w)]
        stride = [in_h // out_h, in_w // out_w]
        for attr in node.attribute:
            if attr.name == "kernel_shape":
                attr.ints[:] = kernel
            elif attr.name == "strides":
                attr.ints[:] = stride
        print(f"  ASPP {out_h}x{out_w}: 输入 {in_h}x{in_w} -> kernel={kernel} stride={stride}")
        fixed += 1

    print(f"  共修复 {fixed} 个自适应池化节点")
    return fixed




def resolve_auto_pad(model: onnx.ModelProto) -> int:
    """
    把 Conv/Pool 的 auto_pad=SAME_UPPER|SAME_LOWER 展开成显式 pads。

    很多后端（包括 onnx2torch）没有实现 SAME_* 自动填充。
    输入形状已钉死，因此可以按 ONNX 规则精确算出 pad：
        out      = ceil(in / stride)
        total    = max((out-1)*stride + (kernel-1)*dilation + 1 - in, 0)
        SAME_UPPER -> (total//2, total - total//2)
        SAME_LOWER -> (total - total//2, total//2)
    """
    shapes = infer_shapes(model)
    resolved = 0
    unresolved: list[str] = []

    for node in model.graph.node:
        if node.op_type not in ("Conv", "AveragePool", "MaxPool"):
            continue
        attrs = {a.name: helper.get_attribute_value(a) for a in node.attribute}
        auto_pad = attrs.get("auto_pad", b"NOTSET")
        if isinstance(auto_pad, bytes):
            auto_pad = auto_pad.decode()
        if auto_pad not in ("SAME_UPPER", "SAME_LOWER"):
            continue

        shape = shapes.get(node.input[0])
        if not shape or not isinstance(shape[2], int) or not isinstance(shape[3], int):
            unresolved.append(node.name or node.op_type)
            continue

        kernel = list(attrs["kernel_shape"])
        strides = list(attrs.get("strides", [1] * len(kernel)))
        dilations = list(attrs.get("dilations", [1] * len(kernel)))
        pads = []
        for axis, k in enumerate(kernel):
            in_size = shape[2 + axis]
            st, dl = strides[axis], dilations[axis]
            out_size = math.ceil(in_size / st)
            total = max((out_size - 1) * st + (k - 1) * dl + 1 - in_size, 0)
            begin = total // 2
            end = total - begin
            if auto_pad == "SAME_LOWER":
                begin, end = end, begin
            pads.extend([begin, end])

        for a in list(node.attribute):
            if a.name == "auto_pad":
                node.attribute.remove(a)
        node.attribute.append(helper.make_attribute("auto_pad", "NOTSET"))
        node.attribute.append(helper.make_attribute("pads", pads))
        resolved += 1

    if unresolved:
        print(f"  [warn] {len(unresolved)} 个节点无法解析输入形状: {unresolved[:5]}")
    return resolved

def lift_constants(model: onnx.ModelProto) -> int:
    """
    把 Constant 节点提升为 graph initializer。

    paddle2onnx 会把全部权重内联成 Constant 节点（本模型有 414 个），
    而 onnx2torch / 部分后端只从 graph.initializer 里取卷积权重，
    会直接 KeyError。这里做一次规范化，产出的 ONNX 更通用。
    """
    existing = {i.name for i in model.graph.initializer}
    promoted, kept = [], []
    for node in model.graph.node:
        if node.op_type != "Constant" or len(node.output) != 1 or node.output[0] in existing:
            kept.append(node)
            continue
        attrs = {a.name: helper.get_attribute_value(a) for a in node.attribute}
        name = node.output[0]
        tensor = None
        if "value" in attrs:
            tensor = attrs["value"]
        elif "value_float" in attrs:
            tensor = helper.make_tensor(name, TensorProto.FLOAT, [], [attrs["value_float"]])
        elif "value_floats" in attrs:
            tensor = helper.make_tensor(name, TensorProto.FLOAT, [len(attrs["value_floats"])], attrs["value_floats"])
        elif "value_int" in attrs:
            tensor = helper.make_tensor(name, TensorProto.INT64, [], [attrs["value_int"]])
        elif "value_ints" in attrs:
            tensor = helper.make_tensor(name, TensorProto.INT64, [len(attrs["value_ints"])], attrs["value_ints"])
        if tensor is None:
            kept.append(node)
            continue
        tensor.name = name
        promoted.append(tensor)
        existing.add(name)
    model.graph.initializer.extend(promoted)
    del model.graph.node[:]
    model.graph.node.extend(kept)
    return len(promoted)

def cast_output_to_int32(model: onnx.ModelProto, out_name: str = "mask") -> str:
    """注意：必须在 pin_input_shape 之后再调用。"""
    """把 int64 的 ArgMax 输出 Cast 成 int32（Core ML 不支持 int64）"""
    producer = next(n for n in model.graph.node if n.op_type == "ArgMax")
    raw = producer.output[0]
    del producer.output[:]
    producer.output.append(raw + "_i64")

    cast = helper.make_node("Cast", [raw + "_i64"], [out_name], to=TensorProto.INT32)
    model.graph.node.append(cast)

    old_out = model.graph.output[0]
    # ArgMax 输出是 [N, H, W]（无通道维），输入已钉死，所以形状可确定
    new_out = helper.make_tensor_value_info(out_name, TensorProto.INT32, [1, INPUT_H, INPUT_W])
    model.graph.output.remove(old_out)
    model.graph.output.append(new_out)
    return out_name


def verify() -> None:
    x = np.zeros((1, 3, INPUT_H, INPUT_W), dtype=np.float32)
    sess = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    yi = sess.get_inputs()[0]
    yo = sess.get_outputs()[0]
    y = sess.run(None, {yi.name: x})[0]
    print(f"  ORT 输入 : {yi.name} {yi.shape} {yi.type}")
    print(f"  ORT 输出 : {yo.name} {yo.shape} {yo.type}")
    print(f"  实测输出 : shape={y.shape} dtype={y.dtype} 取值={np.unique(y)}")


def main() -> None:
    print("[1/7] paddle2onnx 导出中…")
    export_onnx()

    print("[2/7] 钉死输入形状并修复自适应池化…")
    model = onnx.load(str(ONNX_PATH))
    pin_input_shape(model)
    fix_adaptive_pools(model)

    print("[3/7] 展开 SAME_* 自动填充…")
    n_pad = resolve_auto_pad(model)
    print(f"  处理 {n_pad} 个 auto_pad 节点")

    print("[4/7] 常量提升（Constant -> initializer）…")
    n = lift_constants(model)
    print(f"  提升 {n} 个常量")

    print("[5/7] 输出 ArgMax int64 -> int32…")
    cast_output_to_int32(model)

    print("[6/7] 检查并保存…")
    onnx.checker.check_model(model)
    onnx.save(model, str(ONNX_PATH))

    print("[7/7] ONNX Runtime 验证…")
    verify()

    size_mb = ONNX_PATH.stat().st_size / 1e6
    print(f"\n完成: {ONNX_PATH}  ({size_mb:.2f} MB)")


if __name__ == "__main__":
    main()
