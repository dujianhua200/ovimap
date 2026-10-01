/// 建筑兜底包：本地预置建筑轮廓数据（CMAB 等开源数据集预处理）。
///
/// 背景：中国区 OSM `building=*` 覆盖稀疏，Overpass 经常抓回空集。
/// 兜底包是按城市预处理好的建筑 GeoJSON（WGS84），`BasemapFetcher.fetchFor`
/// 在 OSM 建筑为空/过少时自动按 bbox 查询补上。
///
/// 目录：`${basemapDir}/fallback/`（与 `buildings/` 缓存同级）：
/// - `index.json`：已安装包元数据 `{id, name, version, source, date, buildings}`
/// - `<id>.geojson`：该包建筑（FeatureCollection，Polygon/MultiPolygon，WGS84）
///
/// 包由维护方离线预处理（shapefile → WGS84 → 按市裁剪 → GeoJSON），
/// App 端只做下载安装 + bbox 查询，不做重型转换。
library;

import 'dart:convert';
import 'dart:io';

import '../services/store.dart';
import 'basemap.dart';

/// 可下载的兜底包注册表（维护方预处理好后发布到 GitHub release）。
class FallbackPackage {
  final String id;
  final String name;
  final String url;
  final String version;
  final String source;
  const FallbackPackage({
    required this.id,
    required this.name,
    required this.url,
    required this.version,
    required this.source,
  });
}

/// 当前已发布的兜底包（v1：信阳市，CMAB v7 预处理）。
List<FallbackPackage> get fallbackRegistry => const [
      FallbackPackage(
        id: 'xinyang',
        name: '信阳市',
        url: 'https://raw.githubusercontent.com/dujianhua200/ovimap/'
            'data/buildings-xinyang-v1/xinyang_buildings.geojson.gz',
        version: 'v1',
        source: 'CMAB v7（2025-04-20，清华大学）预处理',
      ),
    ];

class FallbackStore {
  final Directory root;
  FallbackStore(this.root);

  static Future<FallbackStore> open() async {
    final base = await LabelStore.instance.basemapDir();
    final d = Directory('${base.path}/fallback');
    if (!d.existsSync()) d.createSync(recursive: true);
    return FallbackStore(d);
  }

  File get _indexFile => File('${root.path}/index.json');

  /// 已安装包元数据（未安装返回 null）。
  Map<String, dynamic>? meta([String id = 'xinyang']) {
    try {
      final f = _indexFile;
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map) {
        final m = Map<String, dynamic>.from(decoded);
        return m['id'] == id ? m : null;
      }
    } catch (_) {}
    return null;
  }

  bool get hasPackage => meta() != null;

  File _pkgFile(String id) => File('${root.path}/$id.geojson');

  /// 按 bbox（`[minLat, minLon, maxLat, maxLon]`）查询兜底包建筑。
  ///
  /// GeoJSON 可能很大：流式只取外环与 bbox 相交的要素（整文件读入、
  /// 逐 feature 判断，不做全量几何运算）。
  Future<List<BuildingPoly>> query(List<double> bbox, {String id = 'xinyang'}) async {
    final f = _pkgFile(id);
    if (!f.existsSync()) return [];
    final minLat = bbox[0], minLon = bbox[1], maxLat = bbox[2], maxLon = bbox[3];
    final out = <BuildingPoly>[];
    try {
      final text = await f.readAsString();
      final root = jsonDecode(text);
      final feats = root is Map ? root['features'] : null;
      if (feats is! List) return [];
      for (final feat in feats) {
        if (feat is! Map) continue;
        final geom = feat['geometry'];
        if (geom is! Map) continue;
        final type = geom['type'];
        final coords = geom['coords'] ?? geom['coordinates'];
        if (coords is! List) continue;
        final polys = type == 'Polygon'
            ? [coords]
            : type == 'MultiPolygon'
                ? coords
                : null;
        if (polys == null) continue;
        for (final poly in polys) {
          if (poly is! List || poly.isEmpty) continue;
          final rings = <List<List<double>>>[];
          var hit = false;
          for (final ring in poly) {
            if (ring is! List) continue;
            final pts = <List<double>>[];
            for (final p in ring) {
              if (p is! List || p.length < 2) continue;
              final lon = (p[0] as num).toDouble();
              final lat = (p[1] as num).toDouble();
              pts.add([lat, lon]); // BuildingPoly 点序为 [lat, lon]
              if (!hit &&
                  lat >= minLat &&
                  lat <= maxLat &&
                  lon >= minLon &&
                  lon <= maxLon) {
                hit = true;
              }
            }
            if (pts.isNotEmpty) rings.add(pts);
          }
          if (hit && rings.isNotEmpty) {
            out.add(BuildingPoly(rings, ''));
          }
        }
      }
    } catch (_) {
      return [];
    }
    return out;
  }

  /// 下载并安装兜底包；[onProgress] 收 `(received, total)`（total 可能为 -1）。
  ///
  /// URL 以 `.gz` 结尾时自动 gzip 解压（纯 Dart，无第三方依赖）。
  Future<void> install(
    FallbackPackage pkg, {
    void Function(int received, int total)? onProgress,
  }) async {
    final req = await HttpClient().getUrl(Uri.parse(pkg.url));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw HttpException('下载失败：HTTP ${resp.statusCode}', uri: Uri.parse(pkg.url));
    }
    final total = resp.contentLength;
    final tmp = File('${root.path}/${pkg.id}.geojson.tmp');
    final sink = tmp.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
    } catch (e) {
      await sink.close();
      rethrow;
    }
    // gzip 解压（发布包为 .gz 以省流量）。
    var text = await tmp.readAsString();
    if (pkg.url.endsWith('.gz')) {
      try {
        final raw = await tmp.readAsBytes();
        text = utf8.decode(gzip.decode(raw));
      } catch (e) {
        await tmp.delete();
        throw FormatException('建筑包解压失败：$e');
      }
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['type'] != 'FeatureCollection') {
      await tmp.delete();
      throw const FormatException('下载的文件不是合法建筑包（GeoJSON）');
    }
    final feats = decoded['features'];
    final count = feats is List ? feats.length : 0;
    await tmp.rename(_pkgFile(pkg.id).path);
    _indexFile.writeAsStringSync(jsonEncode({
      'id': pkg.id,
      'name': pkg.name,
      'version': pkg.version,
      'source': pkg.source,
      'date': DateTime.now().toIso8601String().substring(0, 10),
      'buildings': count,
    }));
  }

  /// 删除已安装包。
  Future<void> uninstall([String id = 'xinyang']) async {
    final f = _pkgFile(id);
    if (f.existsSync()) await f.delete();
    if (_indexFile.existsSync()) await _indexFile.delete();
  }
}
