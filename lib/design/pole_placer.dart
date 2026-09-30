import 'dart:math' as math;

import '../geo/geo_util.dart';

/// 智能布杆计算模块（纯 Dart，不依赖 Flutter UI，可被单元测试）。
///
/// 算法：
/// - 沿线路按弧长每 [spanM] 取一点；
/// - 顶点处转角超过 [cornerAngleDeg] 且 [cornerMustHave] 为 true 时强制立杆，
///   档距从拐点重新起算（避免出现超大档距）；
/// - 线路总长 < [spanM] 时至少在起点立一根；空线路返回空。
/// - 终点不强制立杆（残段 < spanM 是正常的收尾段）。
class RoutePoint {
  final double lat;
  final double lon;
  const RoutePoint(this.lat, this.lon);
}

/// 一根规划杆位（落盘前形态）。
class PolePlan {
  double lat;
  double lon;
  String name;
  PolePlan({required this.lat, required this.lon, this.name = ''});
}

class PolePlacer {
  PolePlacer._();

  /// 沿 [route] 布杆，返回杆位规划（含杆号）。
  ///
  /// [takenNames]：目标工程里已占用的杆号集合，编号时自动顺延跳过。
  static List<PolePlan> place({
    required List<RoutePoint> route,
    double spanM = 50,
    String prefix = 'G',
    int startNo = 1,
    int digits = 3,
    bool cornerMustHave = true,
    double cornerAngleDeg = 30,
    Set<String>? takenNames,
  }) {
    if (spanM <= 0) throw ArgumentError('spanM must be > 0, got $spanM');
    final pts = _dedup(route);
    final plans = <PolePlan>[];
    if (pts.isEmpty) return plans;

    final s = _arcLengths(pts);
    final total = s.last;

    // 总长不足一档（或只有一个有效点）：起点立一根。
    if (pts.length < 2 || total < spanM) {
      plans.add(PolePlan(lat: pts.first.lat, lon: pts.first.lon));
    } else {
      var lastPoleS = 0.0;
      var target = spanM;
      var vi = 1; // 下一个待考察的顶点下标
      plans.add(_at(pts, s, 0));
      while (true) {
        // 在 (lastPoleS, target) 区间内找第一个强制拐点。
        int? cornerIdx;
        if (cornerMustHave) {
          for (var i = vi; i < pts.length - 1; i++) {
            if (s[i] <= lastPoleS) continue;
            if (s[i] >= target) break;
            if (_turnAngleDeg(pts, i) > cornerAngleDeg) {
              cornerIdx = i;
              break;
            }
          }
        }
        if (cornerIdx != null) {
          plans.add(_at(pts, s, s[cornerIdx]));
          lastPoleS = s[cornerIdx];
          vi = cornerIdx + 1;
          target = lastPoleS + spanM;
          continue;
        }
        if (target > total) break;
        plans.add(_at(pts, s, target));
        lastPoleS = target;
        while (vi < pts.length - 1 && s[vi] <= target) {
          vi++;
        }
        target = lastPoleS + spanM;
      }
    }

    assignNames(plans,
        prefix: prefix, startNo: startNo, digits: digits, takenNames: takenNames);
    return plans;
  }

  /// 杆号格式化：prefix + 补零序号（如 G001）。序号超过 [digits] 位时不截断。
  static String poleName(String prefix, int no, int digits) =>
      '$prefix${no.toString().padLeft(digits, '0')}';

  /// 按顺序给杆位编号，跳过 [takenNames] 中已占用的杆号（自动顺延）。
  static void assignNames(
    List<PolePlan> poles, {
    String prefix = 'G',
    int startNo = 1,
    int digits = 3,
    Set<String>? takenNames,
  }) {
    final taken = Set<String>.of(takenNames ?? const <String>{});
    var no = startNo;
    for (final p in poles) {
      while (taken.contains(poleName(prefix, no, digits))) {
        no++;
      }
      p.name = poleName(prefix, no, digits);
      taken.add(p.name);
      no++;
    }
  }

  /// 相邻杆位的最大档距（米），预览提示用。
  static double maxSpanM(List<PolePlan> poles) {
    var m = 0.0;
    for (var i = 1; i < poles.length; i++) {
      final d = GeoUtil.haversine(
          poles[i - 1].lat, poles[i - 1].lon, poles[i].lat, poles[i].lon);
      if (d > m) m = d;
    }
    return m;
  }

  /// 线路总长（米，haversine 累加）。
  static double routeLengthM(List<RoutePoint> route) {
    final pts = _dedup(route);
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += GeoUtil.haversine(
          pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    }
    return total;
  }

  // ---- 内部 ----

  /// 去掉连续重复点（零长度段会导致方位角无定义）。
  static List<RoutePoint> _dedup(List<RoutePoint> route) {
    final out = <RoutePoint>[];
    for (final p in route) {
      if (out.isEmpty) {
        out.add(p);
        continue;
      }
      final q = out.last;
      if (GeoUtil.haversine(q.lat, q.lon, p.lat, p.lon) > 1e-6) out.add(p);
    }
    return out;
  }

  /// 各点累计弧长（米），s[0] = 0。
  static List<double> _arcLengths(List<RoutePoint> pts) {
    final s = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      s[i] = s[i - 1] +
          GeoUtil.haversine(
              pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    }
    return s;
  }

  /// 弧长位置 [target] 处的插值点（lat/lon 线性内插，短距离足够精确）。
  static PolePlan _at(List<RoutePoint> pts, List<double> s, double target) {
    var i = 0;
    while (i < s.length - 2 && s[i + 1] < target) {
      i++;
    }
    final segLen = s[i + 1] - s[i];
    final f = segLen <= 0 ? 0.0 : ((target - s[i]) / segLen).clamp(0.0, 1.0);
    return PolePlan(
      lat: pts[i].lat + (pts[i + 1].lat - pts[i].lat) * f,
      lon: pts[i].lon + (pts[i + 1].lon - pts[i].lon) * f,
    );
  }

  /// 顶点 i 处的转角（度）：入射段与出射段方位角之差的绝对值。
  static double _turnAngleDeg(List<RoutePoint> pts, int i) {
    final b1 = _bearing(pts[i - 1], pts[i]);
    final b2 = _bearing(pts[i], pts[i + 1]);
    var d = (b2 - b1).abs() % (2 * math.pi);
    if (d > math.pi) d = 2 * math.pi - d;
    return d * 180 / math.pi;
  }

  /// 平面近似方位角（弧度，自北顺时针），短距离足够精确。
  static double _bearing(RoutePoint a, RoutePoint b) {
    final latR = (a.lat + b.lat) / 2 * math.pi / 180;
    final dx = (b.lon - a.lon) * math.pi / 180 * math.cos(latR);
    final dy = (b.lat - a.lat) * math.pi / 180;
    return math.atan2(dx, dy);
  }
}
