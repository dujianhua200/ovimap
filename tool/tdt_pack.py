#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""天地图数据 → 信阳离线矢量包（村庄/小队名 + 干线道路）。

用途：App 内置包（assets/buildings/xinyang_places_tdt.geojson.gz、
xinyang_roads_tdt.geojson.gz）的数据采集脚本，可重复执行。

数据源（均为 CGCS2000/WGS84，不做 GCJ 转换）：
- 地名：天地图 v2/search 检索（queryType=2），**按关键词枚举**而不是按
  地理位置扫——实测 pointLonlat / level 对返回集合毫无影响（同一关键词在
  相距 100km 的两点返回同样 600 条），扩大覆盖只能换关键词：
  通名（塆/湾/庄/村/冲/畈/岗/洼）× 姓氏、「姓+家+通名」、方位/地形前缀。
  单关键词最多取 600 条（start 只接受 0/300，count 上限 300）。
- 道路：天地图 WFS LRDL 图层（1:100 万，带名称与等级）。

用法：
  TDT_KEY=xxxx python3 -I tool/tdt_pack.py names --out /tmp/tdtpack
  python3 -I tool/tdt_pack.py roads --out /tmp/tdtpack
  python3 -I tool/tdt_pack.py pack  --out /tmp/tdtpack \
      --assets assets/buildings

注意：
- 密钥只从环境变量 TDT_KEY 读取，不落盘、不进仓库。
- 天地图有频率限制，脚本内置 1.6s 节流与 429 指数退避。
"""

import argparse
import gzip
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---- 信阳范围（WGS84）----
LON_MIN, LON_MAX = 113.55, 115.75
LAT_MIN, LAT_MAX = 31.10, 32.75

# 锚点网格间距（度）。0.15° 经度≈14km，0.14° 纬度≈15km。
STEP_LON = 0.15
STEP_LAT = 0.14

# 豫南自然村/小队通名。塆=湾的本地写法（信阳、孝感、黄冈一带），两个都要。
TONG = ["塆", "湾", "庄", "村", "冲", "畈", "岗", "洼"]

# **关键词枚举**（不是锚点扫描）。
# 实测（2026-10）：天地图 v2/search 的 queryType=2 **忽略 pointLonlat**——
# 同一关键词在相距 100km 的两个点上返回的是同一批 600 条；`level` 也不影响。
# 单关键词最多取 600 条（start 只接受 0/300，count 上限 300）。
# 因此扩大覆盖只能**换关键词**：姓氏/方位 + 通名，每个关键词各自一套 600 条。
# 「塆」全国命中 16,713 条，只靠它只能拿到最靠前的 600 条。
SURNAMES = [
    "王", "李", "张", "刘", "陈", "杨", "黄", "赵", "周", "吴",
    "徐", "孙", "胡", "朱", "高", "林", "何", "郭", "马", "罗",
    "梁", "宋", "郑", "谢", "韩", "唐", "冯", "于", "董", "萧",
    "程", "曹", "袁", "邓", "许", "傅", "沈", "曾", "彭", "吕",
    "苏", "卢", "蒋", "蔡", "贾", "丁", "魏", "薛", "叶", "阎",
    "余", "潘", "杜", "戴", "夏", "钟", "汪", "田", "任", "姜",
    "范", "方", "石", "姚", "谭", "廖", "邹", "熊", "金", "陆",
    "郝", "孔", "白", "崔", "康", "毛", "邱", "秦", "江", "史",
    "顾", "侯", "邵", "孟", "龙", "万", "段", "雷", "钱", "汤",
    "尹", "黎", "易", "常", "武", "乔", "贺", "赖", "龚", "文",
]

# 方位/地形前缀（「南冲」「大洼」「上畈」这类没有姓氏的村名）
PREFIXES = [
    "大", "小", "新", "老", "上", "下", "中", "前", "后", "南",
    "北", "东", "西", "高", "石", "白", "黄", "青", "水", "山",
    "河", "桥", "塘", "岭", "沟", "堰", "田", "坪", "庙", "寨",
    "坡", "园", "林", "花", "果", "竹", "柳", "松", "柏", "杨",
    "桃", "枣", "栗", "茶", "沙", "土", "咀", "崖", "洞", "泉",
    "井", "铺", "店", "楼", "坊", "集", "窑", "瓦", "板", "油",
]

# 「王家塆」这类带「家」的写法只在这几个通名上成立（王家村/王家冲也有）。
JIA_TONG = ["塆", "湾", "庄", "村", "冲", "洼"]


def build_keywords():
    kws = list(TONG)
    for s in SURNAMES:
        kws += [s + t for t in TONG]
        kws += [s + "家" + t for t in JIA_TONG]
    for p in PREFIXES:
        kws += [p + t for t in TONG]
    # 去重保序
    seen = set()
    out = []
    for k in kws:
        if k not in seen:
            seen.add(k)
            out.append(k)
    return out

SEARCH_URL = "https://api.tianditu.gov.cn/v2/search"
WFS_URL = "https://gisserver.tianditu.gov.cn/TDTService/wfs"

THROTTLE_S = 1.6
PAGE_SIZE = 300
MAX_START = 300  # 实测 start>300 返回 400


def log(msg):
    print(msg, flush=True)


def http_get(url, timeout=40):
    req = urllib.request.Request(url, headers={"User-Agent": "ovimap-pack/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def get_json(url, retries=5):
    delay = 5
    for i in range(retries):
        try:
            return json.loads(http_get(url).decode("utf-8"))
        except urllib.error.HTTPError as e:
            # 429/5xx 退避重试；4xx 其他直接抛
            if e.code == 429 or e.code >= 500:
                log(f"  HTTP {e.code}，退避 {delay}s 重试 ({i + 1}/{retries})")
                time.sleep(delay)
                delay = min(delay * 2, 120)
                continue
            raise
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            log(f"  网络错误 {e}，退避 {delay}s 重试 ({i + 1}/{retries})")
            time.sleep(delay)
            delay = min(delay * 2, 120)
    raise RuntimeError(f"重试 {retries} 次仍失败: {url[:120]}")


def search_page(key, kw, start):
    post = {
        "keyWord": kw,
        "level": "12",
        "mapBound": f"{LON_MIN},{LAT_MIN},{LON_MAX},{LAT_MAX}",
        "queryType": "2",
        "start": str(start),
        "count": str(PAGE_SIZE),
        # 固定基准点即可：实测 pointLonlat 不影响返回集合（见文件头）。
        "pointLonlat": "114.0913,32.1264",
        "queryTerm": "name",
    }
    url = (SEARCH_URL + "?postStr=" + urllib.parse.quote(json.dumps(post))
           + "&type=query&tk=" + key)
    return get_json(url)


def pois_of(resp):
    out = []
    for p in resp.get("pois") or []:
        name = (p.get("name") or "").strip()
        ll = (p.get("lonlat") or "").split(",")
        if not name or len(ll) != 2:
            continue
        try:
            lon = float(ll[0])
            lat = float(ll[1])
        except ValueError:
            continue
        out.append({
            "name": name,
            "lon": lon,
            "lat": lat,
            "addr": (p.get("address") or "").strip(),
        })
    return out


def in_xinyang(p):
    """只保留信阳市辖区的点（bbox 内还可能混入驻马店/南阳/湖北/安徽）。"""
    if not (LON_MIN <= p["lon"] <= LON_MAX and LAT_MIN <= p["lat"] <= LAT_MAX):
        return False
    addr = p["addr"]
    if addr:
        return "信阳市" in addr
    return True


def cmd_names(args):
    key = os.environ.get("TDT_KEY", "").strip()
    if not key:
        sys.exit("缺少环境变量 TDT_KEY（天地图 key）")
    os.makedirs(args.out, exist_ok=True)
    raw = os.path.join(args.out, "names_raw.jsonl")
    done_path = os.path.join(args.out, "names_done.txt")

    done = set()
    if os.path.exists(done_path):
        with open(done_path, encoding="utf-8") as f:
            done = {ln.strip() for ln in f if ln.strip()}

    kws = build_keywords()
    log(f"关键词 {len(kws)} 个（取消的锚点维度：pointLonlat 无效，见文件头）")
    n = 0
    kept = 0
    t0 = time.time()
    with open(raw, "a", encoding="utf-8") as out, \
            open(done_path, "a", encoding="utf-8") as dones:
        for kw in kws:
            n += 1
            if kw in done:
                continue
            got_any = False
            for start in (0, MAX_START):
                try:
                    resp = search_page(key, kw, start)
                except Exception as e:  # 单关键词失败不中断整轮
                    log(f"  [{kw}] start={start} 失败: {e}")
                    break
                pois = pois_of(resp)
                got_any = True
                for p in pois:
                    if not in_xinyang(p):
                        continue
                    p["kw"] = kw
                    p["src"] = "tdt"
                    out.write(json.dumps(p, ensure_ascii=False) + "\n")
                    kept += 1
                if len(pois) < PAGE_SIZE:
                    break
                time.sleep(THROTTLE_S)
            if got_any:
                dones.write(kw + "\n")
                dones.flush()
            out.flush()
            if n % 20 == 0 or n == len(kws):
                el = time.time() - t0
                log(f"  {n}/{len(kws)} ({n * 100 // len(kws)}%) 保留 {kept} "
                    f"已用 {el / 60:.1f} 分钟")
            time.sleep(THROTTLE_S)
    log(f"采集完成：{kept} 条 → {raw}")


def cmd_roads(args):
    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, "roads_wfs.json")
    url = (WFS_URL + "?service=WFS&version=1.0.0&request=GetFeature"
           "&typeName=TDTService:LRDL&outputFormat=application/json"
           f"&maxFeatures=5000&bbox={LON_MIN},{LAT_MIN},{LON_MAX},{LAT_MAX}")
    log("拉取 LRDL…")
    d = get_json(url)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
    log(f"道路要素 {len(d.get('features') or [])} 条 → {out_path}")


GRADE_MAP = {
    "高": "trunk",
    "一": "primary",
    "二": "secondary",
    "三": "tertiary",
    "四": "residential",
    "等": "other",
}

# ---- 地名清洗规则 ----
# 关键词扫描会顺带捞到大量非地名 POI（村卫生室、XX村小学、超市…），
# 直接写进 DXF 就是满图噪声，这里按业务词过滤。
BIZ_WORDS = [
    "小学", "中学", "学校", "幼儿园", "大学", "医院", "卫生院", "卫生室",
    "卫生所", "诊所", "药店", "药房", "超市", "商店", "门市", "批发",
    "酒店", "宾馆", "饭店", "餐馆", "农家乐", "银行", "信用社", "加油",
    "营业厅", "移动", "联通", "电信", "公司", "工厂", "合作社", "养殖",
    "种植", "市场", "物流", "快递", "汽修", "维修", "建材", "五金",
    "母婴", "派出所", "供电", "理发", "财政", "税务", "工商", "邮政",
    "粮站", "粮所", "农技", "兽医", "烟草", "储蓄", "信用社",
]

# 机构类结尾（自然村/行政村名不会这么收尾）。注意「店/铺/集/桥/场」是
# 正经村名后缀（王店、李铺、张集、李湾桥），不在此列。
# 「队」「部」不收：信阳不少村民小组就叫「××队」，那是用户要的小队名。
BIZ_SUFFIX = [
    "所", "站", "局", "院", "校", "库", "馆", "中心", "公司", "厂",
]

# 村/社区**办公点** POI：「张大塆村村委会」→ 归一成行政村名「张大塆村」。
# 这类点位通常就在行政村中心，是行政村名最可靠的来源，
# 但原名太长、且与自然村点位可能重复，归一后按下面规则去重。
ADMIN_SUFFIX = [
    "村民委员会", "居民委员会", "社区居委会", "村委会", "居委会",
]

# 镇/乡政府点：「李家寨镇政府」→「李家寨镇」。
# 只收镇/乡一级：市政府/县政府/区政府在 OSM 包里已有，重复标注没意义。
GOV_SUFFIX = ["政府"]


def clean_name(name):
    """清洗单个地名，返回 (name, kind, is_admin)；不保留时 name 为空。"""
    n = name.strip()
    for k in BIZ_WORDS:
        if k in n:
            return "", "", False
    is_admin = False
    for s in ADMIN_SUFFIX:
        if n.endswith(s):
            n = n[: -len(s)]
            is_admin = True
            break
    if not is_admin:
        for s in GOV_SUFFIX:
            if n.endswith(s):
                cand = n[: -len(s)]
                # 仅保留镇/乡一级（去掉"政府"后仍以 镇/乡 结尾）
                if cand.endswith(("镇", "乡")) and len(cand) >= 2:
                    n = cand
                    is_admin = True
                break
    # 归一之后再看机构结尾（村委会/政府已在上面处理掉，这里防漏网的
    # 「岗李乡财政所」「××邮政所」这类 POI）
    for suf in BIZ_SUFFIX:
        if n.endswith(suf):
            return "", "", False
    if len(n) < 2 or len(n) > 9:
        return "", "", False
    if is_admin:
        return n, ("town" if n.endswith(("镇", "乡")) else "village"), True
    kind = "village" if n.endswith("村") else "hamlet"
    return n, kind, False


def cmd_pack(args):
    raw = os.path.join(args.out, "names_raw.jsonl")
    roads_src = os.path.join(args.out, "roads_wfs.json")
    os.makedirs(args.assets, exist_ok=True)

    # ---- 地名：清洗 → 按名称 + 位置去重（同名同地算一处，同名异地都保留）----
    seen = set()
    natural = []  # (name, lat, lon, addr)
    admin = []    # (name, lat, lon, addr) 由村委会/居委会/政府点归一得来
    if os.path.exists(raw):
        with open(raw, encoding="utf-8") as f:
            for ln in f:
                ln = ln.strip()
                if not ln:
                    continue
                p = json.loads(ln)
                name, kind, is_admin = clean_name(p["name"])
                if not name:
                    continue
                kk = (name, round(p["lat"], 5), round(p["lon"], 5))
                if kk in seen:
                    continue
                seen.add(kk)
                (admin if is_admin else natural).append(
                    (name, kind, p["lat"], p["lon"], p.get("addr", "")))

    # 行政村办公点去重：1km 内已有同名自然村（含去掉"村/社区"后缀的同名），
    # 说明该点位已被自然村标注覆盖，不再重复出一个名字。
    by_name = {}
    for n, _k, lat, lon, _a in natural:
        by_name.setdefault(n, []).append((lat, lon))

    def _m(lat1, lon1, lat2, lon2):
        dlat = (lat2 - lat1) * 110540.0
        dlon = (lon2 - lon1) * 111320.0 * math.cos(math.radians((lat1 + lat2) / 2))
        return math.hypot(dlat, dlon)

    kept_admin = []
    for n, kind, lat, lon, addr in admin:
        cands = {n}
        for suf in ("村", "社区"):
            if n.endswith(suf):
                cands.add(n[: -len(suf)])
        dup = False
        for c in cands:
            for (la, lo) in by_name.get(c, ()):
                if _m(lat, lon, la, lo) <= 1000.0:
                    dup = True
                    break
            if dup:
                break
        if not dup:
            kept_admin.append((n, kind, lat, lon, addr))

    feats = []
    for n, kind, lat, lon, addr in natural + kept_admin:
        feats.append({
            "type": "Feature",
            "properties": {
                "name": n,
                "kind": kind,
                "src": "tdt",
                "addr": addr,
            },
            "geometry": {
                "type": "Point",
                "coordinates": [round(lon, 6), round(lat, 6)],
            },
        })
    places_out = os.path.join(args.assets, "xinyang_places_tdt.geojson.gz")
    with gzip.open(places_out, "wt", encoding="utf-8") as f:
        json.dump({"type": "FeatureCollection", "features": feats}, f,
                  ensure_ascii=False, separators=(",", ":"))
    log(f"地名 {len(feats)} 条 → {places_out} ({os.path.getsize(places_out)} B)")

    # ---- 道路：LRDL 每条 MultiLineString 拆成单条 LineString ----
    rfeats = []
    if os.path.exists(roads_src):
        with open(roads_src, encoding="utf-8") as f:
            d = json.load(f)
        for ft in d.get("features") or []:
            props = ft.get("properties") or {}
            name = (props.get("NAME") or "").strip()
            if not name:  # 无名的 1:100 万道路没标注价值，跳过
                continue
            grade = GRADE_MAP.get((props.get("RTEG") or "").strip(), "other")
            geom = ft.get("geometry") or {}
            lines = []
            if geom.get("type") == "LineString":
                lines = [geom["coordinates"]]
            elif geom.get("type") == "MultiLineString":
                lines = geom["coordinates"]
            for line in lines:
                if len(line) < 2:
                    continue
                rfeats.append({
                    "type": "Feature",
                    "properties": {"name": name, "highway": grade, "src": "tdt"},
                    "geometry": {"type": "LineString", "coordinates": line},
                })
    roads_out = os.path.join(args.assets, "xinyang_roads_tdt.geojson.gz")
    with gzip.open(roads_out, "wt", encoding="utf-8") as f:
        json.dump({"type": "FeatureCollection", "features": rfeats}, f,
                  ensure_ascii=False, separators=(",", ":"))
    log(f"道路 {len(rfeats)} 段 → {roads_out} ({os.path.getsize(roads_out)} B)")

    # 统计
    if feats:
        cnt = {}
        for x in feats:
            k = len(x["properties"]["name"])
            cnt[k] = cnt.get(k, 0) + 1
        log(f"名称长度分布(前5): {sorted(cnt.items())[:5]}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("names", "roads", "pack"):
        p = sub.add_parser(name)
        p.add_argument("--out", required=True)
        if name == "pack":
            p.add_argument("--assets", required=True)
    args = ap.parse_args()
    {"names": cmd_names, "roads": cmd_roads, "pack": cmd_pack}[args.cmd](args)


if __name__ == "__main__":
    main()
