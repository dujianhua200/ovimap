#!/usr/bin/env python3
"""建筑轮廓规整化：将 AI 提取的锯齿轮廓正交化，接近商业地图观感。

流程（Web Mercator 米制下）：
1. 去重连续重复点
2. Douglas-Peucker 简化（eps=0.4m）去抖动
3. 主导方向检测（最长边）+ 边角度吸附到 90° 倍数
4. 相邻吸附直线求交重建多边形
5. 面积变化 >30% 或非法则回退到简化结果

用法：python3 regularize.py in.geojson.gz out.geojson.gz
"""
import gzip
import json
import math
import sys

R = 6378137.0


def lonlat_to_merc(lon, lat):
    x = R * math.radians(lon)
    lat = max(min(lat, 85.05112878), -85.05112878)
    y = R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
    return x, y


def merc_to_lonlat(x, y):
    lon = math.degrees(x / R)
    lat = math.degrees(2 * math.atan(math.exp(y / R)) - math.pi / 2)
    return lon, lat


def perp_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    L = math.hypot(dx, dy)
    if L == 0:
        return math.hypot(px - ax, py - ay)
    return abs((px - ax) * dy - (py - ay) * dx) / L


def douglas_peucker(pts, eps):
    """pts: [(x,y)...] 开环；返回简化后开环点列。"""
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
    return [p for p, k in zip(pts, keep) if k]


def ring_area(pts):
    s = 0.0
    n = len(pts)
    for i in range(n):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2


def edge_angle(dx, dy):
    return math.atan2(dy, dx)


def norm90(a):
    """角度归一到 [0, 90°)。"""
    a = a % math.pi
    if a >= math.pi / 2:
        a -= math.pi / 2
    # 接近 90° 的按 0 处理（方向无向）
    return a


def dominant_angle(pts):
    """最长边的方向（归一到[0,90°)）作为主导方向。"""
    n = len(pts)
    best, blen = 0.0, 0.0
    for i in range(n):
        x1, y1 = pts[i]
        x2, y2 = pts[(i + 1) % n]
        L = math.hypot(x2 - x1, y2 - y1)
        if L > blen:
            blen = L
            best = edge_angle(x2 - x1, y2 - y1)
    return norm90(best)


def line_intersection(p1, d1, p2, d2):
    """直线 p1+t*d1 与 p2+s*d2 的交点；平行返回 None。"""
    (x1, y1), (dx1, dy1) = p1, d1
    (x2, y2), (dx2, dy2) = p2, d2
    denom = dx1 * dy2 - dy1 * dx2
    if abs(denom) < 1e-9:
        return None
    t = ((x2 - x1) * dy2 - (y2 - y1) * dx2) / denom
    return (x1 + t * dx1, y1 + t * dy1)


def orthogonalize(pts):
    """pts: 闭环点列（首尾同点）；返回正交化后闭环点列，失败返回 None。"""
    # 去尾部重复点，转开环
    ring = pts[:-1] if pts[0] == pts[-1] else pts[:]
    # 去连续重复
    clean = [ring[0]]
    for p in ring[1:]:
        if math.hypot(p[0] - clean[-1][0], p[1] - clean[-1][1]) > 1e-6:
            clean.append(p)
    if len(clean) < 4:
        return None
    n = len(clean)
    theta = dominant_angle(clean)
    # 每条边吸附后的方向（单位向量）
    dirs = []
    for i in range(n):
        x1, y1 = clean[i]
        x2, y2 = clean[(i + 1) % n]
        a = edge_angle(x2 - x1, y2 - y1)
        # 吸附到 theta + k*90°
        k = round((a - theta) / (math.pi / 2))
        sa = theta + k * math.pi / 2
        dirs.append((math.cos(sa), math.sin(sa)))
    # 新顶点 = 边(i-1)直线 与 边(i)直线 的交点
    new_ring = []
    for i in range(n):
        p_prev, d_prev = clean[i - 1], dirs[i - 1]
        p_cur, d_cur = clean[i], dirs[i]
        q = line_intersection(p_prev, d_prev, p_cur, d_cur)
        if q is None:
            return None
        # 交点离原顶点太远 → 形状不适合正交化
        if math.hypot(q[0] - clean[i][0], q[1] - clean[i][1]) > 8.0:
            return None
        new_ring.append(q)
    # 去除共线冗余点
    out = []
    m = len(new_ring)
    for i in range(m):
        x1, y1 = new_ring[i - 1]
        x2, y2 = new_ring[i]
        x3, y3 = new_ring[(i + 1) % m]
        v1 = (x2 - x1, y2 - y1)
        v2 = (x3 - x2, y3 - y2)
        cross = abs(v1[0] * v2[1] - v1[1] * v2[0])
        dot = v1[0] * v2[0] + v1[1] * v2[1]
        if cross < 1e-6 and dot > 0:
            continue  # 共线同向，跳过中间点
        out.append((x2, y2))
    if len(out) < 4:
        return None
    out.append(out[0])
    return out


def regularize_ring(ring_lonlat):
    """单环规整化，输入输出均为 lon/lat 闭环。"""
    # 转米制
    mpts = [lonlat_to_merc(lon, lat) for lon, lat in ring_lonlat]
    # 闭环转开环做简化
    open_pts = mpts[:-1] if mpts[0] == mpts[-1] else mpts[:]
    simp = douglas_peucker(open_pts, 0.4)
    if len(simp) < 4:
        return ring_lonlat
    simp.append(simp[0])
    orig_area = ring_area([p for p in mpts[:-1]])
    # 正交化
    ortho = orthogonalize(simp)
    if ortho is not None:
        new_area = ring_area(ortho[:-1])
        if orig_area > 1e-6 and abs(new_area - orig_area) / orig_area <= 0.30:
            simp = ortho
        # 否则回退到简化结果
    # 转回 lon/lat
    return [merc_to_lonlat(x, y) for x, y in simp]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with gzip.open(src, 'rt') as f:
        data = json.load(f)
    feats = data['features']
    total = len(feats)
    for idx, feat in enumerate(feats):
        geom = feat.get('geometry') or {}
        if geom.get('type') == 'Polygon':
            coords = geom.get('coordinates') or []
            new_coords = []
            for ring in coords:
                if len(ring) >= 4:
                    try:
                        new_coords.append(regularize_ring(ring))
                    except Exception:
                        new_coords.append(ring)
                else:
                    new_coords.append(ring)
            geom['coordinates'] = new_coords
        # MultiPolygon 暂不处理（CMAB 信阳包内应无）
        if idx % 20000 == 0:
            print(f'{idx}/{total}', flush=True)
    print(f'{total}/{total} done', flush=True)
    with gzip.open(dst, 'wt', compresslevel=9) as f:
        json.dump(data, f, separators=(',', ':'))


if __name__ == '__main__':
    main()
