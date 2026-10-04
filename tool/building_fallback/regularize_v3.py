#!/usr/bin/env python3
"""建筑轮廓 v3 优化：在 v2 规整化基础上进一步清理。

针对用户反馈"乱七八糟、不像建筑轮廓"：
1. 面积过滤：删除 <25㎡ 的碎片（棚屋/噪声，非正常建筑）
2. 复杂轮廓强简化：顶点>24 的多边形用 eps=1.2m 强 DP 再压一遍
3. 细长碎片过滤：周长²/面积 > 120 的极细长条视为噪声删除
4. 保留 v2 的正交化（已规整的不动）

用法：python3 regularize_v3.py in.geojson.gz out.geojson.gz
"""
import gzip
import json
import math
import sys

R = 6378137.0
MIN_AREA_M2 = 25.0
COMPLEX_VERTICES = 24
STRONG_EPS = 1.2
SLIVER_RATIO = 120.0  # perim^2 / area


def lonlat_to_merc(lon, lat):
    x = R * math.radians(lon)
    lat = max(min(lat, 85.05112878), -85.05112878)
    y = R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
    return x, y


def merc_to_lonlat(x, y):
    lon = math.degrees(x / R)
    lat = math.degrees(2 * math.atan(math.exp(y / R)) - math.pi / 2)
    return lon, lat


def ring_area_m2(ring):
    pts = [lonlat_to_merc(lon, lat) for lon, lat in ring]
    s = 0.0
    for i in range(len(pts) - 1):
        s += pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1]
    return abs(s) / 2


def ring_perim_m(ring):
    pts = [lonlat_to_merc(lon, lat) for lon, lat in ring]
    return sum(
        math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1])
        for i in range(len(pts) - 1)
    )


def perp_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    L = math.hypot(dx, dy)
    if L == 0:
        return math.hypot(px - ax, py - ay)
    return abs((px - ax) * dy - (py - ay) * dx) / L


def douglas_peucker(pts, eps):
    n = len(pts)
    if n <= 2:
        return pts[:]
    keep = [False] * n
    keep[0] = keep[n - 1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        ax, ay = pts[a]
        bx, by = pts[b]
        dmax, idx = 0.0, -1
        for i in range(a + 1, b):
            d = perp_dist(pts[i][0], pts[i][1], ax, ay, bx, by)
            if d > dmax:
                dmax, idx = d, i
        if dmax > eps:
            keep[idx] = True
            stack.append((a, idx))
            stack.append((idx, b))
    return [p for i, p in enumerate(pts) if keep[i]]


def process_ring(ring_lonlat):
    """返回 (保留?, 新ring)"""
    area = ring_area_m2(ring_lonlat)
    if area < MIN_AREA_M2:
        return False, None
    perim = ring_perim_m(ring_lonlat)
    if area > 0 and (perim * perim) / area > SLIVER_RATIO:
        return False, None

    # 转米制开环
    pts = [lonlat_to_merc(lon, lat) for lon, lat in ring_lonlat]
    if pts[0] == pts[-1]:
        pts = pts[:-1]

    # 复杂轮廓强简化
    if len(pts) > COMPLEX_VERTICES:
        pts = douglas_peucker(pts + [pts[0]], STRONG_EPS)[:-1]
        if len(pts) < 4:
            return False, None

    # 转回经纬度闭环
    out = [merc_to_lonlat(x, y) for x, y in pts]
    out.append(out[0])
    # 强简化后面积若崩坏则丢弃
    if ring_area_m2(out) < MIN_AREA_M2:
        return False, None
    return True, out


def main():
    inp, outp = sys.argv[1], sys.argv[2]
    with gzip.open(inp, 'rt') as f:
        d = json.load(f)
    kept, dropped_tiny, dropped_sliver, simplified = 0, 0, 0, 0
    new_feats = []
    for feat in d['features']:
        g = feat['geometry']
        if g['type'] != 'Polygon':
            continue
        ring = g['coordinates'][0]
        area_before = ring_area_m2(ring)
        ok, new_ring = process_ring(ring)
        if not ok:
            if area_before < MIN_AREA_M2:
                dropped_tiny += 1
            else:
                dropped_sliver += 1
            continue
        if len(new_ring) < len(ring):
            simplified += 1
        feat['geometry']['coordinates'] = [new_ring]
        # 只保留外环（内环多为噪声孔）
        new_feats.append(feat)
        kept += 1
    d['features'] = new_feats
    with gzip.open(outp, 'wt') as f:
        json.dump(d, f, separators=(',', ':'))
    print(f"保留 {kept}，删除小碎片 {dropped_tiny}，删除细长条 {dropped_sliver}，"
          f"强简化 {simplified}")


if __name__ == '__main__':
    main()
