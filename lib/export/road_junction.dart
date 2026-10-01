import 'dart:math' as math;

import 'basemap.dart';

/// 道路交叉口处理：**开口（次路退让）+ 倒角**。
///
/// 正规地形图画法：主路边线贯通，次路边线在交叉口处断开（开口），
/// 开口端点以 45° 倒角线连接到主路边线（路缘石转角），而不是简单交叉。
///
/// 纯几何模块（笛卡尔米坐标），不依赖 DXF 写出，可单测。
class RoadJunction {
  RoadJunction._();

  /// 输入道路（中心线已简化，笛卡尔米坐标）。
  /// [halfW] 为该路双线描边半宽（米）。
  static JunctionResult process(List<JunctionRoad> roads, double chamferM) {
    final n = roads.length;
    final result = JunctionResult(
      List.generate(n, (_) => <List<List<double>>>[]),
      <List<List<double>>>[],
    );
    if (n == 0) return result;

    // 各路弧长表
    final cums = <List<double>>[];
    final totals = <double>[];
    for (final r in roads) {
      final cum = _cumLen(r.pts);
      cums.add(cum);
      totals.add(cum.isEmpty ? 0.0 : cum.last);
    }

    // ---- 1. 两两求交 ----
    // 每条路的交点表：s（本路弧长）、交点 P、对方半宽/等级/索引、对方弧长 s
    final hits = List.generate(n, (_) => <_Hit>[]);
    for (var i = 0; i < n; i++) {
      final a = roads[i].pts;
      if (a.length < 2) continue;
      for (var j = i + 1; j < n; j++) {
        final b = roads[j].pts;
        if (b.length < 2) continue;
        // 包围盒预检
        if (!_bboxOverlap(_bboxOf(a), _bboxOf(b),
            roads[i].halfW + roads[j].halfW)) {
          continue;
        }
        for (var ai = 0; ai < a.length - 1; ai++) {
          for (var bi = 0; bi < b.length - 1; bi++) {
            final p = _segIntersect(a[ai], a[ai + 1], b[bi], b[bi + 1]);
            if (p == null) continue;
            final sa = cums[i][ai] +
                _dist(a[ai], p) /
                    math.max(_dist(a[ai], a[ai + 1]), 1e-9) *
                    (cums[i][ai + 1] - cums[i][ai]);
            final sb = cums[j][bi] +
                _dist(b[bi], p) /
                    math.max(_dist(b[bi], b[bi + 1]), 1e-9) *
                    (cums[j][bi + 1] - cums[j][bi]);
            // 共用端点（两条 way 首尾相接，多为同一条路的分段）不视为交叉口，
            // 否则会在连续道路中间打出缺口。仅「端点—中部」相接才算 T 型口。
            if (_nearEnd(sa, totals[i]) && _nearEnd(sb, totals[j])) continue;
            hits[i].add(_Hit(sa, p, j, sb));
            hits[j].add(_Hit(sb, p, i, sa));
          }
        }
      }
    }

    // ---- 2. 主次判定 + 开口退让（切分 pieces）----
    for (var i = 0; i < n; i++) {
      final pts = roads[i].pts;
      final total = totals[i];
      if (pts.length < 2 || total < 1e-9) continue;
      final myRank = roads[i].grade.index;

      // 交点按弧长排序、去重（同一交点可能被相邻两段各检出一次）
      final hs = hits[i].toList()..sort((x, y) => x.s.compareTo(y.s));
      final uniq = <_Hit>[];
      for (final h in hs) {
        if (uniq.isEmpty || (h.s - uniq.last.s).abs() > 1e-6) uniq.add(h);
      }

      // 退让区间（仅当对方为 major）
      final cuts = <List<double>>[]; // [s0, s1]
      final trims = <_Trim>[]; // 倒角端点
      for (final h in uniq) {
        final o = roads[h.other];
        final oRank = o.grade.index;
        // 对方为 major：对方等级更高，或同级但索引更小（稳定确定）
        final otherIsMajor =
            oRank < myRank || (oRank == myRank && h.other < i);
        if (!otherIsMajor) continue;
        final trim = o.halfW + chamferM;
        final s0 = h.s - trim, s1 = h.s + trim;
        cuts.add([s0, s1]);
        // 倒角端点（朝向交点的方向）
        if (s0 > 1e-9) {
          final t = _pointAt(pts, cums[i], s0);
          trims.add(_Trim(t.p, t.dir, h.p, h.other, h.otherS));
        }
        if (s1 < total - 1e-9) {
          final t = _pointAt(pts, cums[i], s1);
          trims.add(_Trim(t.p, [-t.dir[0], -t.dir[1]], h.p, h.other, h.otherS));
        }
      }

      // 合并重叠区间，切分剩余弧长为 pieces
      cuts.sort((x, y) => x[0].compareTo(y[0]));
      final merged = <List<double>>[];
      for (final c in cuts) {
        if (merged.isEmpty || c[0] > merged.last[1] + 1e-9) {
          merged.add([c[0], c[1]]);
        } else {
          merged.last[1] = math.max(merged.last[1], c[1]);
        }
      }
      var cur = 0.0;
      for (final m in merged) {
        final a = math.max(cur, 0.0), b = math.min(m[0], total);
        if (b - a > 1e-6) {
          result.pieces[i].add(_subPolyline(pts, cums[i], a, b));
        }
        cur = math.max(cur, m[1]);
      }
      if (total - cur > 1e-6) {
        result.pieces[i]
            .add(_subPolyline(pts, cums[i], math.max(cur, 0.0), total));
      }

      // ---- 3. 倒角：次路开口端点 → 主路边线（45° 真倒角）----
      for (final t in trims) {
        final major = roads[t.majorIdx];
        final mt = _pointAt(major.pts, cums[t.majorIdx], t.majorS);
        // 主路局部直线近似（倒角很短，足够精确）
        final v = mt.dir;
        final m = [-v[1], v[0]];
        final ohw = major.halfW;
        // 次路端点法向（u 指向交点）
        final u = t.dir;
        final nn = [-u[1], u[0]];
        final hw = roads[i].halfW;
        for (final side in [1.0, -1.0]) {
          final c0 = [t.p[0] + nn[0] * hw * side, t.p[1] + nn[1] * hw * side];
          final relX = c0[0] - t.junctionP[0], relY = c0[1] - t.junctionP[1];
          final mSide = relX * m[0] + relY * m[1];
          if (mSide.abs() < 1e-9) continue;
          final sSign = mSide > 0 ? 1.0 : -1.0;
          final along = relX * v[0] + relY * v[1];
          if (along.abs() < 1e-9) continue; // 退化情形跳过
          // 45° 倒角：从次路边线端点起，落到主路边线上沿主路方向
          // 向外再张 chamferM 的点（两条腿等长 = 标准 45° 倒角）。
          final flare = along + along.sign * chamferM;
          final q = [
            t.junctionP[0] + m[0] * sSign * ohw + v[0] * flare,
            t.junctionP[1] + m[1] * sSign * ohw + v[1] * flare,
          ];
          final d = _dist(c0, q);
          if (d > 4 * ohw + chamferM * 2) continue; // 斜交过缓，跳过防怪线
          if (d < 1e-9) continue;
          result.chamfers.add([c0, q]);
        }
      }
    }
    return result;
  }

  // ---------- 几何原语 ----------

  static double _dist(List<double> a, List<double> b) {
    final dx = a[0] - b[0], dy = a[1] - b[1];
    return math.sqrt(dx * dx + dy * dy);
  }

  static List<double> _cumLen(List<List<double>> pts) {
    final cum = <double>[0.0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum.last + _dist(pts[i - 1], pts[i]));
    }
    return cum;
  }

  static List<double> _bboxOf(List<List<double>> pts) {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (final p in pts) {
      if (p[0] < x0) x0 = p[0];
      if (p[0] > x1) x1 = p[0];
      if (p[1] < y0) y0 = p[1];
      if (p[1] > y1) y1 = p[1];
    }
    return [x0, y0, x1, y1];
  }

  static bool _bboxOverlap(List<double> a, List<double> b, double pad) =>
      a[0] - pad <= b[2] + pad &&
      b[0] - pad <= a[2] + pad &&
      a[1] - pad <= b[3] + pad &&
      b[1] - pad <= a[3] + pad;

  /// 弧长 s 是否在折线端点处（容差 1 微米）。
  static bool _nearEnd(double s, double total) =>
      s < 1e-6 || (total - s) < 1e-6;

  /// 线段相交（含端点相接、T 型）；平行/共线/重叠返回 null。
  static List<double>? _segIntersect(
      List<double> a1, List<double> a2, List<double> b1, List<double> b2) {
    final rX = a2[0] - a1[0], rY = a2[1] - a1[1];
    final sX = b2[0] - b1[0], sY = b2[1] - b1[1];
    final denom = rX * sY - rY * sX;
    final rLen = math.sqrt(rX * rX + rY * rY);
    final sLen = math.sqrt(sX * sX + sY * sY);
    if (rLen < 1e-9 || sLen < 1e-9) return null;
    // 平行判定（相对容差）：含共线重叠，一律不视为交叉口
    if (denom.abs() / (rLen * sLen) < 1e-9) return null;
    final qpx = b1[0] - a1[0], qpy = b1[1] - a1[1];
    final t = (qpx * sY - qpy * sX) / denom;
    final u = (qpx * rY - qpy * rX) / denom;
    const eps = 1e-9;
    if (t < -eps || t > 1 + eps || u < -eps || u > 1 + eps) return null;
    return [a1[0] + rX * t.clamp(0.0, 1.0), a1[1] + rY * t.clamp(0.0, 1.0)];
  }

  /// 弧长 s 处的点与切向（s  clamp 进 [0, total]）。
  static _PtDir _pointAt(List<List<double>> pts, List<double> cum, double s) {
    final total = cum.isEmpty ? 0.0 : cum.last;
    final sc = s.clamp(0.0, total);
    var lo = 0, hi = cum.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] < sc) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final i = math.max(1, lo);
    final segLen = cum[i] - cum[i - 1];
    final t = segLen < 1e-12 ? 0.0 : (sc - cum[i - 1]) / segLen;
    final a = pts[i - 1], b = pts[i];
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len = math.sqrt(dx * dx + dy * dy);
    final dir = len < 1e-9 ? [1.0, 0.0] : [dx / len, dy / len];
    return _PtDir([a[0] + dx * t, a[1] + dy * t], dir);
  }

  /// 取弧长 [a, b] 区间的子折线（含插值端点）。
  static List<List<double>> _subPolyline(
      List<List<double>> pts, List<double> cum, double a, double b) {
    final out = <List<double>>[];
    out.add(_pointAt(pts, cum, a).p);
    for (var i = 1; i < pts.length; i++) {
      if (cum[i] > a + 1e-9 && cum[i] < b - 1e-9) out.add(pts[i]);
    }
    out.add(_pointAt(pts, cum, b).p);
    // 去重相邻重复点
    final dedup = <List<double>>[];
    for (final p in out) {
      if (dedup.isEmpty || _dist(dedup.last, p) > 1e-9) dedup.add(p);
    }
    return dedup;
  }
}

/// 输入道路。
class JunctionRoad {
  final List<List<double>> pts;
  final RoadGrade grade;
  final double halfW;
  JunctionRoad(this.pts, this.grade, this.halfW);
}

/// 处理结果：每条路的 pieces（与输入同序）+ 倒角线段。
class JunctionResult {
  final List<List<List<List<double>>>> pieces;
  final List<List<List<double>>> chamfers;
  JunctionResult(this.pieces, this.chamfers);
}

class _Hit {
  final double s; // 本路弧长
  final List<double> p; // 交点
  final int other; // 对方索引
  final double otherS; // 对方弧长
  _Hit(this.s, this.p, this.other, this.otherS);
}

class _Trim {
  final List<double> p; // 次路开口端点（中心线）
  final List<double> dir; // 朝向交点的单位方向
  final List<double> junctionP; // 交点
  final int majorIdx; // 主路索引
  final double majorS; // 主路弧长
  _Trim(this.p, this.dir, this.junctionP, this.majorIdx, this.majorS);
}

class _PtDir {
  final List<double> p;
  final List<double> dir;
  _PtDir(this.p, this.dir);
}
