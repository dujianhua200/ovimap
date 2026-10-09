#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把导出的 DXF 渲染成 PNG，直观核对图面观感。

用 ezdxf 的 matplotlib 后端（Drawing addon），它按**真实 DXF 坐标**绘制，
所以图上量出来的长度就是模型单位 × 出图比例 = 真实米数。

同时打印量距核对表，确认「图上量距 × 比例 == 真实米数」。

用法：
  python3 tool/render_dxf_preview.py out.dxf out.png [出图比例]
"""
import sys
import math
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import ezdxf
from ezdxf.addons.drawing import RenderContext, Frontend
from ezdxf.addons.drawing.matplotlib import MatplotlibBackend
from ezdxf.addons.drawing.config import Configuration, BackgroundPolicy


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    ps = int(argv[3]) if len(argv) > 3 else 3000

    doc = ezdxf.readfile(src)          # 严格打开，非 recover
    msp = doc.modelspace()

    # ---------- 量距核对 ----------
    print(f"=== {src}  出图比例 1:{ps} ===")
    segs = []
    for e in msp.query('LINE[layer=="GanLu"]'):
        s, t = e.dxf.start, e.dxf.end
        d = math.hypot(s.x - t.x, s.y - t.y)
        segs.append((d, e))
    segs.sort(key=lambda z: -z[0])
    if segs:
        pin_r = 0.0025               # 杆符号圆半径（纸面 2.5mm）
        print(f"杆路档数：{len(segs)}")
        print(f"{'序号':>4} {'图上长度(单位)':>14} {'×比例=米':>12} "
              f"{'+pin缩进=米':>12}")
        for i, (d, _) in enumerate(segs[:6]):
            real = d * ps
            with_pin = real + 2 * pin_r * ps
            print(f"{i+1:>4} {d:>14.5f} {real:>12.1f} {with_pin:>12.1f}")
        avg = sum(d for d, _ in segs) / len(segs)
        print(f"平均档距：图上 {avg:.5f} → 真实 {avg*ps:.1f} m（含pin缩进 "
              f"{avg*ps + 2*pin_r*ps:.1f} m）")

    # 配线图（PeiXianTu 层）尺度 —— 应与路由图同量级
    pw = []
    for e in msp.query('LINE[layer=="PeiXianTu"]'):
        s, t = e.dxf.start, e.dxf.end
        pw.append(math.hypot(s.x - t.x, s.y - t.y))
    if pw:
        print(f"配线图线段 {len(pw)} 条，最长 {max(pw):.5f} → {max(pw)*ps:.1f} m")

    # 字号集合
    hs = sorted({round(t.dxf.height, 5) for t in msp.query('TEXT')})
    print(f"字高集合（纸面毫米 = 值×1000）：{[round(h*1000, 2) for h in hs]}")
    lbl = [t.dxf.text for t in msp.query('TEXT[layer=="TuQian"]')
           if "比例" in t.dxf.text]
    print(f"图面比例标注：{lbl}")

    # ---------- 渲染 ----------
    # 让中文字体可用，否则宋体名显示为方块
    plt.rcParams["font.sans-serif"] = [
        "Songti SC", "STSong", "PingFang SC", "Heiti SC",
        "Arial Unicode MS", "SimHei", "DejaVu Sans",
    ]
    plt.rcParams["axes.unicode_minus"] = False

    fig = plt.figure(figsize=(16, 11), dpi=150)
    # 标题用 suptitle 并留出顶部空间，避免被 axes 裁掉
    fig.suptitle(
        f"李庄架空光缆改造工程  路由图 + 配线图    出图比例 1:{ps}"
        f"    （模型空间 1 单位 = 1mm 纸面）",
        fontsize=13, color="#2C2C2A", y=0.985)
    ax = fig.add_axes([0.03, 0.03, 0.94, 0.90])
    ax.set_facecolor("white")
    fig.patch.set_facecolor("white")

    ctx = RenderContext(doc)
    out = MatplotlibBackend(ax)
    # **必须 WHITE + finalize=True**：CUSTOM 会清空图层，
    # finalize=False 则不做最终的坐标归一（实测整图空白）。
    # 深色观感靠"渲染成白底 PNG 后再整体反相"实现，见下方 invert。
    cfg = Configuration(
        background_policy=BackgroundPolicy.WHITE,
        lineweight_scaling=0.5,
        min_lineweight=0.6,
    )
    Frontend(ctx, out, config=cfg).draw_layout(msp, finalize=True)

    ax.axis("off")
    fig.savefig(dst, dpi=150, facecolor="white")
    print(f"已渲染：{dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
