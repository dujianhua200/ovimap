import 'dart:convert';

import '../models/map_label.dart';
import 'import_model.dart';

/// 奥维 JSON 导出（.ovjsn）解析。
///
/// 字段依据奥维官方 Web API 文档（omapAPI_WS.pdf §2.4）：
/// `ObjItems[]` → `{Type, Object:{Name, Comment, ObjectDetail:{Gcj02, PointList}}}`
/// - `Type`：7=点，8=线，13=面
/// - `Gcj02`：0=真实经纬度，1=gcj02（→ 转 WGS-84）
/// - `PointList`：扁平 `[lat,lng,lat,lng,…]`，或 `{Lat,Lng}` 对象数组
///
/// 名称取 `Name`/`ObjName`（取不到用 ''）；文件头 UTF-8 BOM 会被 strip。
/// 纯静态、无 UI 依赖；大文件时由 UI 层经 `Isolate.run` 调用。
class OvjsnParser {
  OvjsnParser._();

  static const _typePoint = 7;
  static const _typeLine = 8;
  static const _typeArea = 13;

  static ImportParseResult parse(String text, {String fileName = ''}) {
    var t = text;
    if (t.startsWith('\uFEFF')) t = t.substring(1); // UTF-8 BOM
    final dynamic decoded;
    try {
      decoded = jsonDecode(t);
    } catch (e) {
      throw FormatException('不是有效的 ovjsn(JSON) 文件: $e');
    }
    final rawItems = decoded is Map
        ? decoded['ObjItems']
        : (decoded is List ? decoded : null);
    final items = _asList(rawItems);

    final labels = <MapLabel>[];
    final comments = <String>[];
    var sawGcj = false;

    for (final raw in items) {
      if (raw is! Map) continue;
      final item = raw.cast<String, dynamic>();
      final obj = item['Object'] is Map
          ? (item['Object'] as Map).cast<String, dynamic>()
          : item;
      final detail = obj['ObjectDetail'] is Map
          ? (obj['ObjectDetail'] as Map).cast<String, dynamic>()
          : (item['ObjectDetail'] is Map
                ? (item['ObjectDetail'] as Map).cast<String, dynamic>()
                : <String, dynamic>{});

      final type = _asInt(obj['Type'] ?? item['Type']);
      final name = _asString(
        obj['Name'] ?? obj['ObjName'] ?? item['Name'] ?? item['ObjName'],
      );
      final isGcj =
          _truthy(detail['Gcj02']) ||
          _truthy(item['Gcj02']) ||
          _truthy(obj['Gcj02']);
      if (isGcj) sawGcj = true;
      final comment = _asString(obj['Comment'] ?? item['Comment']);
      if (comment.isNotEmpty && !comments.contains(comment)) {
        comments.add(comment);
      }

      if (type == _typePoint) {
        final p = _singlePoint(detail);
        if (p == null) continue;
        final w = importToWgs84(p[0], p[1], isGcj02: isGcj);
        labels.add(MapLabel(typeId: 'pipe', lat: w[0], lon: w[1], name: name));
      } else if (type == _typeLine || type == _typeArea) {
        var pts = _pointList(detail);
        if (pts.length < 2) continue;
        if (type == _typeArea) pts = _closeRing(pts);
        final gid = MapLabel().id;
        for (var i = 0; i < pts.length; i++) {
          final w = importToWgs84(pts[i][0], pts[i][1], isGcj02: isGcj);
          labels.add(
            MapLabel(
              typeId: 'pipe',
              lat: w[0],
              lon: w[1],
              name: i == 0 ? name : '',
              lineGroupId: gid,
            ),
          );
        }
      }
      // 其他 Type（如导航 11）暂不支持：静默跳过（JSON 结构自描述，无数据丢失歧义）
    }

    for (var i = 0; i < labels.length; i++) {
      labels[i].seq = i + 1;
    }
    final units = labels.isEmpty
        ? <ImportUnit>[]
        : [
            ImportUnit(
              folderPath: const [],
              name: baseNameWithoutExt(fileName),
              labels: labels,
              description: comments.isEmpty ? null : comments.join('\n'),
            ),
          ];
    return ImportParseResult(
      units: units,
      detectedSystem: sawGcj ? 'GCJ02' : 'WGS84',
    );
  }

  /// 点对象：优先 {Lat,Lng} 结构（Point/LatLng/Center/PointStart），
  /// 其次 PointList 首对，再次 detail 直挂 Lat/Lng。
  static List<double>? _singlePoint(Map<String, dynamic> detail) {
    for (final k in ['Point', 'LatLng', 'Center', 'PointStart', 'Position']) {
      final p = _asLatLng(detail[k]);
      if (p != null) return p;
    }
    final list = _pointList(detail);
    if (list.isNotEmpty) return list.first;
    return _asLatLng(detail);
  }

  /// 线/面点串：PointList/Points/Vertexes，兼容扁平数列与对象数组。
  static List<List<double>> _pointList(Map<String, dynamic> detail) {
    for (final k in ['PointList', 'Points', 'Vertexes', 'LinePoints']) {
      final pts = _parsePoints(detail[k]);
      if (pts.isNotEmpty) return pts;
    }
    return const [];
  }

  static List<List<double>> _parsePoints(dynamic v) {
    final out = <List<double>>[];
    if (v is! List || v.isEmpty) return out;
    // 扁平 [lat,lng,lat,lng,…]
    if (v.every((e) => e is num)) {
      for (var i = 0; i + 1 < v.length; i += 2) {
        final p = _valid(
          (v[i] as num).toDouble(),
          (v[i + 1] as num).toDouble(),
        );
        if (p != null) out.add(p);
      }
      return out;
    }
    for (final e in v) {
      List<double>? p;
      if (e is Map) {
        p = _asLatLng(e);
      } else if (e is List && e.length >= 2 && e[0] is num && e[1] is num) {
        p = _valid((e[0] as num).toDouble(), (e[1] as num).toDouble());
      }
      if (p != null) out.add(p);
    }
    return out;
  }

  /// {Lat,Lng}（含大小写/全称变体）→ [lat, lng]；非法返回 null。
  static List<double>? _asLatLng(dynamic v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    final lat = _asDouble(
      m['Lat'] ?? m['lat'] ?? m['Latitude'] ?? m['latitude'],
    );
    final lng = _asDouble(
      m['Lng'] ?? m['lng'] ?? m['Longitude'] ?? m['longitude'],
    );
    if (lat == null || lng == null) return null;
    return _valid(lat, lng);
  }

  static List<double>? _valid(double lat, double lng) {
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return [lat, lng];
  }

  static List<List<double>> _closeRing(List<List<double>> pts) {
    if (pts.length >= 2) {
      final a = pts.first, b = pts.last;
      if ((a[0] - b[0]).abs() > 1e-9 || (a[1] - b[1]).abs() > 1e-9) {
        return [
          ...pts,
          [a[0], a[1]],
        ];
      }
    }
    return pts;
  }

  static List<dynamic> _asList(dynamic v) => v is List ? v : const [];

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? -1;
  }

  static double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  static String _asString(dynamic v) => v == null ? '' : '$v'.trim();

  /// Gcj02 标志：1 / '1' / true / 'true' → true。
  static bool _truthy(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = '$v'.trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }
}
