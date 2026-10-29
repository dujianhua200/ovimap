/// 内置底图数据：信阳市 OSM 道路（含路名）+ 地名/POI。
///
/// 与建筑兜底包同一思路：离线预打包，App 启动时加载到内存，
/// 按 bbox 查询。Overpass 实时抓取作为补充（Xinyang 范围外或新数据），
/// 按名称+位置去重，避免重叠。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

import 'basemap.dart';
import 'overpass.dart';

/// 内置道路/地名包版本（与 asset 文件对应）。
const int kBundledRoadsVersion = 1;
const String kBundledRoadsAsset = 'assets/buildings/xinyang_roads.geojson.gz';
const String kBundledPlacesAsset = 'assets/buildings/xinyang_places.geojson.gz';

/// 天地图补充包（信阳）：村名/小队名（v2/search 网格扫描）+
/// 干线道路（WFS LRDL 1:100 万）。由 `tool/tdt_pack.py` 生成。
const String kBundledPlacesTdtAsset =
    'assets/buildings/xinyang_places_tdt.geojson.gz';
const String kBundledRoadsTdtAsset =
    'assets/buildings/xinyang_roads_tdt.geojson.gz';

/// 信阳市大致范围（WGS84），用于判断是否用内置数据。
const double kXinyangLonMin = 113.7;
const double kXinyangLonMax = 115.6;
const double kXinyangLatMin = 31.2;
const double kXinyangLatMax = 32.6;

/// 内置底图数据（单例，延迟加载）。
class BundledBasemap {
  static BundledBasemap? _instance;

  /// 测试用开关：设为 false 时禁用内置数据（避免干扰断言）。
  /// 默认 false，生产环境在 main.dart 中设为 true。
  static bool enabled = false;

  static Future<BundledBasemap> get instance async {
    final v = _instance;
    if (v != null) return v;
    final b = BundledBasemap._();
    await b._load();
    _instance = b;
    return b;
  }

  /// 测试用：重置单例。
  static void resetForTest() {
    _instance = null;
  }

  BundledBasemap._();

  final List<RoadPoly> _roads = [];
  final List<PlaceFeature> _places = [];

  bool get loaded => _roads.isNotEmpty || _places.isNotEmpty;

  Future<void> _load() async {
    try {
      // 道路
      final roadData = await rootBundle.load(kBundledRoadsAsset);
      final roadText =
          utf8.decode(gzip.decode(roadData.buffer.asUint8List()));
      final roadJson = jsonDecode(roadText) as Map<String, dynamic>;
      final loaded = <RoadPoly>[];
      for (final f in (roadJson['features'] as List)) {
        final fm = f as Map<String, dynamic>;
        final props = fm['properties'] as Map<String, dynamic>;
        final geom = fm['geometry'] as Map<String, dynamic>;
        final coords = (geom['coordinates'] as List)
            .map((c) => [(c[1] as num).toDouble(), (c[0] as num).toDouble()])
            .toList();
        if (coords.length < 2) continue;
        final hw = (props['highway'] as String?) ?? '';
        loaded.add(RoadPoly(
          coords,
          OverpassClient.gradeOf(hw),
          (props['name'] as String?) ?? '',
        ));
      }
      // 拓扑修复：删零长度段 + 同名端点吸附（加载时做一次）。
      _roads.addAll(cleanRoads(loaded));
    } catch (_) {}

    try {
      // 地名
      final placeData = await rootBundle.load(kBundledPlacesAsset);
      final placeText =
          utf8.decode(gzip.decode(placeData.buffer.asUint8List()));
      final placeJson = jsonDecode(placeText) as Map<String, dynamic>;
      for (final f in (placeJson['features'] as List)) {
        final fm = f as Map<String, dynamic>;
        final props = fm['properties'] as Map<String, dynamic>;
        final geom = fm['geometry'] as Map<String, dynamic>;
        final coords = geom['coordinates'] as List;
        final name = (props['name'] as String?) ?? '';
        if (name.isEmpty) continue;
        _places.add(PlaceFeature(
          name: name,
          lat: (coords[1] as num).toDouble(),
          lon: (coords[0] as num).toDouble(),
          level: _levelOf((props['kind'] as String?) ?? ''),
          isArea: false,
        ));
      }
    } catch (_) {}

    await _loadTdtExtras();
  }

  /// 合并天地图补充包（村名/小队名 + 干线道路）。
  ///
  /// 定位是**补充**不是替换：
  /// - 地名：与已有地名「同名且相距 ≤110m」视为同一处跳过；同名异地
  ///   （信阳到处是「李家塆」）照常保留，这正是要补的东西；
  /// - 道路：天地图 WFS 是 1:100 万数据，几何比内置 OSM 粗。若该段道路
  ///   七成以上采样点 300m 内已有 OSM 道路顶点，判定为同一条路，跳过——
  ///   否则 DXF 里会出现一条与真实道路平行、偏移几百米的"幽灵路"。
  ///   实测（信阳 945 段）：按此规则丢弃 145 段、保留 800 段（约 7,190 km），
  ///   OSM 道路覆盖不到的路段（约 65% 的采样点 3km 内无 OSM 道路）都会补上。
  Future<void> _loadTdtExtras() async {
    // ---- 地名 ----
    try {
      final data = await rootBundle.load(kBundledPlacesTdtAsset);
      final text = utf8.decode(gzip.decode(data.buffer.asUint8List()));
      final json = jsonDecode(text) as Map<String, dynamic>;
      // 同名地名索引：name → "格号" 集合（0.001° ≈ 110m）
      const cell = 0.001;
      final cells = <String, Set<String>>{};
      for (final p in _places) {
        (cells[p.name] ??= <String>{})
            .add('${(p.lat / cell).round()},${(p.lon / cell).round()}');
      }
      for (final f in (json['features'] as List)) {
        final fm = f as Map<String, dynamic>;
        final props = fm['properties'] as Map<String, dynamic>;
        final coords = (fm['geometry'] as Map<String, dynamic>)['coordinates']
            as List;
        final name = (props['name'] as String?) ?? '';
        if (name.isEmpty) continue;
        final lon = (coords[0] as num).toDouble();
        final lat = (coords[1] as num).toDouble();
        final i = (lat / cell).round(), j = (lon / cell).round();
        final set = cells[name];
        var dup = false;
        if (set != null) {
          for (var a = -1; a <= 1 && !dup; a++) {
            for (var b = -1; b <= 1; b++) {
              if (set.contains('${i + a},${j + b}')) {
                dup = true;
                break;
              }
            }
          }
        }
        if (dup) continue;
        (cells[name] ??= <String>{}).add('$i,$j');
        _places.add(PlaceFeature(
          name: name,
          lat: lat,
          lon: lon,
          level: _levelOf((props['kind'] as String?) ?? ''),
          isArea: false,
        ));
      }
    } catch (_) {}

    // ---- 干线道路 ----
    try {
      final data = await rootBundle.load(kBundledRoadsTdtAsset);
      final text = utf8.decode(gzip.decode(data.buffer.asUint8List()));
      final json = jsonDecode(text) as Map<String, dynamic>;
      // 现有道路顶点网格（0.005° ≈ 550m），用于"已被覆盖"判定
      const cell = 0.005;
      final grid = <String, List<List<double>>>{};
      for (final r in _roads) {
        for (final p in r.pts) {
          (grid['${(p[0] / cell).floor()}_${(p[1] / cell).floor()}'] ??= [])
              .add(p);
        }
      }
      bool covered(double lat, double lon) {
        final gx = (lat / cell).floor(), gy = (lon / cell).floor();
        for (var a = -1; a <= 1; a++) {
          for (var b = -1; b <= 1; b++) {
            for (final p
                in grid['${gx + a}_${gy + b}'] ?? const <List<double>>[]) {
              if (_distM(lat, lon, p[0], p[1]) <= 300) return true;
            }
          }
        }
        return false;
      }

      final added = <RoadPoly>[];
      for (final f in (json['features'] as List)) {
        final fm = f as Map<String, dynamic>;
        final props = fm['properties'] as Map<String, dynamic>;
        final coords = ((fm['geometry'] as Map<String, dynamic>)['coordinates']
                as List)
            .map((c) => [(c[1] as num).toDouble(), (c[0] as num).toDouble()])
            .toList();
        if (coords.length < 2) continue;
        // 均匀取至多 7 个采样点；七成以上被覆盖则判定为同一条路
        var hit = 0, n = 0;
        final step = math.max(1, coords.length ~/ 7);
        for (var k = 0; k < coords.length; k += step) {
          if (n >= 7) break;
          n++;
          if (covered(coords[k][0], coords[k][1])) hit++;
        }
        if (n > 0 && hit * 10 >= n * 7) continue; // OSM 已覆盖，跳过
        added.add(RoadPoly(
          coords,
          OverpassClient.gradeOf((props['highway'] as String?) ?? ''),
          (props['name'] as String?) ?? '',
        ));
      }
      _roads.addAll(cleanRoads(added));
    } catch (_) {}
  }

  static PlaceLevel _levelOf(String kind) {
    switch (kind) {
      case 'city':
      case 'town':
        return PlaceLevel.town;
      case 'village':
      case 'hamlet':
        return PlaceLevel.village;
      case 'suburb':
      case 'neighbourhood':
        return PlaceLevel.suburb;
      default:
        return PlaceLevel.residential;
    }
  }

  /// bbox 是否在信阳市范围内（有内置数据）。
  static bool inXinyang(double lonMin, double latMin, double lonMax, double latMax) {
    return lonMin >= kXinyangLonMin &&
        lonMax <= kXinyangLonMax &&
        latMin >= kXinyangLatMin &&
        latMax <= kXinyangLatMax;
  }

  /// 按 bbox 查询内置道路。
  List<RoadPoly> roadsIn(double lonMin, double latMin, double lonMax, double latMax) {
    return _roads.where((r) {
      return r.pts.any((p) =>
          p[1] >= lonMin && p[1] <= lonMax && p[0] >= latMin && p[0] <= latMax);
    }).toList();
  }

  /// 按 bbox 查询内置地名。
  List<PlaceFeature> placesIn(
      double lonMin, double latMin, double lonMax, double latMax) {
    return _places
        .where((p) =>
            p.lon >= lonMin &&
            p.lon <= lonMax &&
            p.lat >= latMin &&
            p.lat <= latMax)
        .toList();
  }

  /// 道路拓扑修复：删除零长度段 + 同名路端点吸附。
  ///
  /// 加载时调用一次。修的是 OSM 原始数据的拓扑错误：
  /// - 零长度/极短段（<2m，含 0 米退化段）直接删除；
  /// - 同名路端点在 15m 内的间隙自动吸合，补上碎段间的断口。
  ///
  /// 不是美化数据：同名路直接吸合；异名路仅交叉角才吸合，
  /// 平行路/辅路不碰；吸附后交叉口识别才能正常工作
  /// （RoadJunction 依赖线段精确相交，同一路口多点会重复生成倒角）。
  static List<RoadPoly> cleanRoads(List<RoadPoly> roads) {
    // 1. 删零长度段（总长 < 2m）
    final kept = <RoadPoly>[];
    for (final r in roads) {
      if (r.pts.length >= 2 && _polylineLengthM(r.pts) >= 2.0) {
        kept.add(r);
      }
    }
    // 2. 端点吸附（15m，同名）
    return _snapEndpoints(kept, 15.0);
  }

  /// 折线总长（米），pts 为 [lat, lon]。
  static double _polylineLengthM(List<List<double>> pts) {
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += _distM(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]);
    }
    return total;
  }

  /// 两点间距离（米），近似平面投影。
  static double _distM(double lat1, double lon1, double lat2, double lon2) {
    final dLat = (lat2 - lat1) * 110540.0;
    final dLon = (lon2 - lon1) *
        111320.0 *
        math.cos((lat1 + lat2) * 0.5 * math.pi / 180.0);
    return math.sqrt(dLat * dLat + dLon * dLon);
  }

  /// 同名路端点吸附：15m 内的同名端点用并查集合并到质心。
  ///
  /// 吸附规则：
  /// - 同名（非空）路端点：直接吸合（同路碎段）；
  /// - 异名路端点：仅当两路在端点处呈交叉角（非平行，|cos| < 0.97，
  ///   夹角 > ~14°）时吸合——同一路口多条路的端点应汇到一点，
  ///   否则 RoadJunction 会把同一路口识别成多个点、重复生成倒角；
  /// - 平行路（双向车道、平行辅路）不吸合；无名路不吸附。
  static List<RoadPoly> _snapEndpoints(List<RoadPoly> roads, double tolM) {
    final n = roads.length;
    // 端点列表
    final endpoints = <_RoadEndpoint>[];
    for (var i = 0; i < n; i++) {
      final pts = roads[i].pts;
      if (pts.length < 2) continue;
      endpoints.add(_RoadEndpoint(i, true, pts.first[0], pts.first[1]));
      endpoints.add(_RoadEndpoint(i, false, pts.last[0], pts.last[1]));
    }
    if (endpoints.isEmpty) return roads;

    // 并查集
    final parent = List<int>.generate(endpoints.length, (i) => i);
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[ra] = rb;
    }

    // 网格索引加速：cell 取 tolM/90000 度（纬向/经向均大于 tolM）。
    final cellDeg = tolM / 90000.0;
    final grid = <String, List<int>>{};
    for (var i = 0; i < endpoints.length; i++) {
      final e = endpoints[i];
      final key =
          '${(e.lat / cellDeg).floor()}_${(e.lon / cellDeg).floor()}';
      (grid[key] ??= []).add(i);
    }

    // 相邻 3x3 网格内找近端点，合并
    for (var i = 0; i < endpoints.length; i++) {
      final e = endpoints[i];
      final name = roads[e.roadIdx].name;
      if (name.isEmpty) continue;
      final gx = (e.lat / cellDeg).floor();
      final gy = (e.lon / cellDeg).floor();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          for (final j in grid['${gx + dx}_${gy + dy}'] ?? const <int>[]) {
            if (j <= i) continue;
            final e2 = endpoints[j];
            final name2 = roads[e2.roadIdx].name;
            if (name2.isEmpty) continue;
            if (_distM(e.lat, e.lon, e2.lat, e2.lon) > tolM) continue;
            if (name == name2) {
              union(i, j);
            } else {
              // 异名：仅交叉角才吸合（平行路不吸）
              if (!_parallelAtEndpoint(roads, e, e2)) union(i, j);
            }
          }
        }
      }
    }

    // 每组求质心
    final groups = <int, List<int>>{};
    for (var i = 0; i < endpoints.length; i++) {
      (groups[find(i)] ??= []).add(i);
    }

    // 复制点列，应用吸附
    final newPts = <int, List<List<double>>>{};
    for (final group in groups.values) {
      if (group.length < 2) continue;
      var sumLat = 0.0, sumLon = 0.0;
      for (final idx in group) {
        sumLat += endpoints[idx].lat;
        sumLon += endpoints[idx].lon;
      }
      final cLat = sumLat / group.length;
      final cLon = sumLon / group.length;
      for (final idx in group) {
        final e = endpoints[idx];
        final pts = newPts[e.roadIdx] ??=
            roads[e.roadIdx].pts.map((p) => List<double>.from(p)).toList();
        if (e.isFirst) {
          pts.first[0] = cLat;
          pts.first[1] = cLon;
        } else {
          pts.last[0] = cLat;
          pts.last[1] = cLon;
        }
      }
    }

    // 重建
    final out = <RoadPoly>[];
    for (var i = 0; i < n; i++) {
      final pts = newPts[i] ?? roads[i].pts;
      out.add(RoadPoly(pts, roads[i].grade, roads[i].name));
    }
    return out;
  }

  /// 两端点处道路是否近似平行（夹角 < ~14°，|cos| > 0.97）。
  /// 方向取端点处指向路内的单位向量。
  static bool _parallelAtEndpoint(
      List<RoadPoly> roads, _RoadEndpoint a, _RoadEndpoint b) {
    List<double> dir(_RoadEndpoint e) {
      final pts = roads[e.roadIdx].pts;
      if (e.isFirst) {
        return [pts[1][0] - pts[0][0], pts[1][1] - pts[0][1]];
      } else {
        return [
          pts[pts.length - 1][0] - pts[pts.length - 2][0],
          pts[pts.length - 1][1] - pts[pts.length - 2][1]
        ];
      }
    }

    final d1 = dir(a), d2 = dir(b);
    final l1 = math.sqrt(d1[0] * d1[0] + d1[1] * d1[1]);
    final l2 = math.sqrt(d2[0] * d2[0] + d2[1] * d2[1]);
    if (l1 < 1e-12 || l2 < 1e-12) return true; // 退化段视为平行，不吸
    final cosA = (d1[0] * d2[0] + d1[1] * d2[1]) / (l1 * l2);
    return cosA.abs() > 0.97;
  }

  /// 合并内置与实时数据：直接拼接，不做几何去重（用户要求"抓取什么样子就什么样子"）。
  ///
  /// 只去掉完全相同的（同名+首尾点完全一致），不做"留最宽的"处理。
  /// 合并后走一次拓扑修复（删零长度段 + 同名端点吸附），实时路同样受益。
  static List<RoadPoly> mergeRoads(List<RoadPoly> bundled, List<RoadPoly> live) {
    if (bundled.isEmpty) return cleanRoads(live);
    if (live.isEmpty) return cleanRoads(bundled);
    final seen = <String>{};
    for (final r in bundled) {
      seen.add(_roadKey(r));
    }
    final out = List<RoadPoly>.from(bundled);
    for (final r in live) {
      if (seen.add(_roadKey(r))) out.add(r);
    }
    return cleanRoads(out);
  }

  /// 简单去重键：名称+首尾点（精确匹配才算重复）。
  static String _roadKey(RoadPoly r) {
    if (r.pts.isEmpty) return r.name;
    final f = r.pts.first, l = r.pts.last;
    return '${r.name}|${f[0]}|${f[1]}|${l[0]}|${l[1]}';
  }

  /// 合并内置与实时地名，去重（同名+位置相近视为重复）。
  static List<PlaceFeature> mergePlaces(
      List<PlaceFeature> bundled, List<PlaceFeature> live) {
    if (bundled.isEmpty) return live;
    if (live.isEmpty) return bundled;
    final seen = <String>{};
    for (final p in bundled) {
      seen.add(_placeKey(p));
    }
    final out = List<PlaceFeature>.from(bundled);
    for (final p in live) {
      if (seen.add(_placeKey(p))) out.add(p);
    }
    return out;
  }

  static String _placeKey(PlaceFeature p) {
    // 名称 + 位置（约 100m 网格）
    return '${p.name}|${(p.lat * 1000).round()}|${(p.lon * 1000).round()}';
  }
}

/// 道路端点（吸附用）：roadIdx + 是否起点 + 位置。
class _RoadEndpoint {
  final int roadIdx;
  final bool isFirst;
  final double lat;
  final double lon;
  _RoadEndpoint(this.roadIdx, this.isFirst, this.lat, this.lon);
}
