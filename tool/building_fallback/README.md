# 建筑兜底包制作工具

从 CMAB（清华大学全国建筑数据集，Figshare）省包 zip 中按城市 bbox 裁剪建筑，
输出 WGS84 GeoJSON，供 App「建筑兜底包」下载安装。

## 用法

```bash
python3 extract_city.py <省包.zip> <输出.geojson> <minLon> <minLat> <maxLon> <maxLat>
# 例：信阳市
python3 extract_city.py henan.zip xinyang_buildings.geojson 113.6 31.1 116.0 32.75
gzip -9 xinyang_buildings.geojson
```

## 关键结论（2026-10-01 实测）

- CMAB 按省分包（`henan.zip` 1.16GB），包内按处理批次拆成多个 `.shp`（非按城市）。
- 坐标系：`.prj` 声称 Web Mercator，**实测确为 Web Mercator**（`y = R·ln(tan(π/4+φ/2))`，R=6378137）。
  注意：曾误判为 Plate Carrée——系脚本公式把 R 写成 20037508 所致，已修正。
- 只解析 header bbox 与目标相交的 `.shp`（153 个文件中信阳只命中 15 个）。
- 信阳市结果：98006 栋，GeoJSON 154MB → gzip 18.7MB。
- CMAB 覆盖 3667 个"自然城市"（含县级市及非建成区），县城覆盖良好；
  纯农田/深山无建筑属正常（本来就没有房子）。

## 分发

经 GitHub git-database API 推送到 `data/buildings-xinyang-v1` 分支。
App 通过分支根目录的 `manifest.json` 发现版本（后台自动更新）。

**国内可访问性（2026-10-02 起）**：数据文件与 manifest 的主线路为 jsDelivr CDN
（`https://cdn.jsdelivr.net/gh/dujianhua200/ovimap@data/buildings-xinyang-v1/…`，
国内有节点），`raw.githubusercontent.com` 仅作备用——App 按 manifest 的
`url` → `mirrors` 顺序自动切换。

⚠️ 发新版后必须清 jsDelivr 缓存（否则国内用户拿到旧 manifest）：
```bash
curl "https://purge.jsdelivr.net/gh/dujianhua200/ovimap@data/buildings-xinyang-v1/manifest.json"
curl "https://purge.jsdelivr.net/gh/dujianhua200/ovimap@data/buildings-xinyang-v1/xinyang_buildings.geojson.gz"
```
（release asset 需走 uploads.github.com，当前网络 surrogate 不放行，故用数据分支。）
