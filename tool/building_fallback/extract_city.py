#!/usr/bin/env python3
"""从 CMAB 省包 zip 中按 bbox 提取建筑 → WGS84 GeoJSON。
用法: extract_xinyang.py <province.zip> <out.geojson> <minLon> <minLat> <maxLon> <maxLat>
只解析 header bbox 与目标相交的 .shp，大文件友好。
"""
import json, math, struct, sys, zipfile

R = 6378137.0  # Web Mercator 地球半径（.prj 正确；y = R·ln(tan(π/4+φ/2))）
M_PER_DEG = 111319.49079327358  # 仅 x = R·λrad = M_PER_DEG·lon° 成立

def lon_to_x(lon): return R * math.radians(lon)
def lat_to_y(lat): return R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
def x_to_lon(x): return math.degrees(x / R)
def y_to_lat(y): return math.degrees(2 * math.atan(math.exp(y / R)) - math.pi / 2)

def bbox_intersects(a, b):
    return not (a[2] < b[0] or a[0] > b[2] or a[3] < b[1] or a[1] > b[3])

def parse_shp(data, out_xy_bbox):
    """解析 .shp Polygon(type 5)，返回相交目标框的多边形（WebMercator 米）。"""
    if len(data) < 100 or struct.unpack('>i', data[0:4])[0] != 9994:
        raise ValueError('bad shp')
    if struct.unpack('<i', data[32:36])[0] != 5:
        raise ValueError('not polygon')
    polys = []
    off, n = 100, len(data)
    while off + 8 <= n:
        rec_len = struct.unpack('>i', data[off+4:off+8])[0] * 2
        rec_end = off + 8 + rec_len
        if rec_end > n or rec_len < 0: break
        if struct.unpack('<i', data[off+8:off+12])[0] == 5 and rec_len >= 44:
            p = off + 8
            num_parts = struct.unpack('<i', data[p+36:p+40])[0]
            num_pts = struct.unpack('<i', data[p+40:p+44])[0]
            if num_parts > 0 and num_pts > 0:
                parts = struct.unpack('<%di' % num_parts, data[p+44:p+44+4*num_parts])
                pt_off = p + 44 + 4 * num_parts
                rings, hit = [], False
                for i in range(num_parts):
                    s = parts[i]; e = parts[i+1] if i+1 < num_parts else num_pts
                    ring = []
                    for j in range(s, e):
                        x, y = struct.unpack('<2d', data[pt_off+j*16:pt_off+j*16+16])
                        ring.append((x, y))
                        if not hit and out_xy_bbox[0] <= x <= out_xy_bbox[2] and out_xy_bbox[1] <= y <= out_xy_bbox[3]:
                            hit = True
                    if ring: rings.append(ring)
                if hit and rings:
                    polys.append(rings)
        off = rec_end
    return polys

def main():
    zip_path, out_path = sys.argv[1], sys.argv[2]
    min_lon, min_lat, max_lon, max_lat = map(float, sys.argv[3:7])
    xy_bbox = (lon_to_x(min_lon), lat_to_y(min_lat), lon_to_x(max_lon), lat_to_y(max_lat))
    z = zipfile.ZipFile(zip_path)
    shp_names = [n for n in z.namelist() if n.endswith('.shp')]
    print(f'{len(shp_names)} shp files', flush=True)
    feats, skipped = [], 0
    for idx, name in enumerate(shp_names):
        head = z.read(name)[:100]
        fbx = struct.unpack('<4d', head[36:68])  # minx, miny, maxx, maxy
        if not bbox_intersects((fbx[0], fbx[1], fbx[2], fbx[3]), xy_bbox):
            skipped += 1
            continue
        data = z.read(name)
        for rings in parse_shp(data, xy_bbox):
            coords = []
            for ring in rings:
                coords.append([[round(x_to_lon(x), 6), round(y_to_lat(y), 6)] for x, y in ring])
            feats.append({"type": "Feature", "properties": {},
                          "geometry": {"type": "Polygon", "coordinates": coords}})
        if idx % 20 == 0:
            print(f'  [{idx}/{len(shp_names)}] feats={len(feats)}', flush=True)
    print(f'done: {len(feats)} buildings, skipped {skipped} files', flush=True)
    with open(out_path, 'w') as f:
        f.write('{"type":"FeatureCollection","features":[')
        for i, ft in enumerate(feats):
            if i: f.write(',')
            f.write(json.dumps(ft, separators=(',', ':')))
        f.write(']}')
    print('wrote', out_path, flush=True)

main()
