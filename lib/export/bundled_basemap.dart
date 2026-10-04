/// 内置底图数据：信阳市 OSM 道路（含路名）+ 地名/POI。
///
/// 与建筑兜底包同一思路：离线预打包，App 启动时加载到内存，
/// 按 bbox 查询。Overpass 实时抓取作为补充（Xinyang 范围外或新数据），
/// 按名称+位置去重，避免重叠。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'basemap.dart';
import 'overpass.dart';

/// 内置道路/地名包版本（与 asset 文件对应）。
const int kBundledRoadsVersion = 1;
const String kBundledRoadsAsset = 'assets/buildings/xinyang_roads.geojson.gz';
const String kBundledPlacesAsset = 'assets/buildings/xinyang_places.geojson.gz';

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
      for (final f in (roadJson['features'] as List)) {
        final fm = f as Map<String, dynamic>;
        final props = fm['properties'] as Map<String, dynamic>;
        final geom = fm['geometry'] as Map<String, dynamic>;
        final coords = (geom['coordinates'] as List)
            .map((c) => [(c[1] as num).toDouble(), (c[0] as num).toDouble()])
            .toList();
        if (coords.length < 2) continue;
        final hw = (props['highway'] as String?) ?? '';
        _roads.add(RoadPoly(
          coords,
          OverpassClient.gradeOf(hw),
          (props['name'] as String?) ?? '',
        ));
      }
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

  /// 合并内置与实时数据，去重（同名+位置相近视为重复，留最宽的）。
  ///
  /// 内置已离线去重；实时数据补充内置没有的。重复时保留等级高的（更宽的）。
  static List<RoadPoly> mergeRoads(List<RoadPoly> bundled, List<RoadPoly> live) {
    if (bundled.isEmpty) return live;
    if (live.isEmpty) return bundled;
    // 按名称分组，组内按等级排序
    final byName = <String, List<RoadPoly>>{};
    for (final r in bundled) {
      byName.putIfAbsent(r.name, () => []).add(r);
    }
    final out = List<RoadPoly>.from(bundled);
    for (final r in live) {
      final sameName = byName[r.name];
      if (sameName == null || sameName.isEmpty) {
        out.add(r);
        byName.putIfAbsent(r.name, () => []).add(r);
        continue;
      }
      // 同名：检查是否与已有的几何重叠（首尾点或中点相近）
      bool isDup = false;
      RoadPoly? toReplace;
      for (final b in sameName) {
        if (_roadsOverlap(b, r)) {
          isDup = true;
          // 留最宽的：如果 live 的更宽，替换
          if (_gradeRank(r.grade) > _gradeRank(b.grade)) {
            toReplace = b;
          }
          break;
        }
      }
      if (toReplace != null) {
        final idx = out.indexOf(toReplace);
        if (idx >= 0) out[idx] = r;
        sameName.remove(toReplace);
        sameName.add(r);
      } else if (!isDup) {
        out.add(r);
        sameName.add(r);
      }
      // isDup 且不更宽 → 丢弃 live 的重复
    }
    return out;
  }

  /// 道路等级排序（数字越大越宽）。
  static int _gradeRank(RoadGrade grade) {
    switch (grade) {
      case RoadGrade.trunk:
        return 8;
      case RoadGrade.primary:
        return 6;
      case RoadGrade.secondary:
        return 4;
      case RoadGrade.tertiary:
        return 2;
      default:
        return 0;
    }
  }

  /// 两条同名道路是否几何重叠（任一端点或中点在 100m 内）。
  static bool _roadsOverlap(RoadPoly a, RoadPoly b) {
    if (a.pts.isEmpty || b.pts.isEmpty) return false;
    // 检查 a 的首/中/尾点是否靠近 b 的任一点
    final aSamples = <List<double>>[
      a.pts.first,
      a.pts[a.pts.length ~/ 2],
      a.pts.last,
    ];
    for (final p in aSamples) {
      for (final q in b.pts) {
        // 约 100m = 0.001 度
        if ((p[0] - q[0]).abs() < 0.001 && (p[1] - q[1]).abs() < 0.001) {
          return true;
        }
      }
    }
    return false;
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
