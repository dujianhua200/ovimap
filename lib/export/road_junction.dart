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
  /// [snapTol]：近miss容差（米）。端点到对方线段距离 <= snapTol 且
  /// 不近似平行时视为相交，兜底吸附后仍残留的小间隙（异名路路口）。
  static JunctionResult process(List<JunctionRoad> roads, double chamferM,
      {double snapTol = 3.0}) {
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
            var p = _segIntersect(a[ai], a[ai + 1], b[bi], b[bi + 1]);
            // 近miss兜底：精确不交但端点距对方线段 <= snapTol 时视为相交。
            p ??= _segNearMiss(a[ai], a[ai + 1], b[bi], b[bi + 1], snapTol);
            if (p == null) continue;
            // 有符号投影：近miss 交点可能在线段外（s 为负或 >total），
            // 用直线距离会误算成段内点，导致开口切错位置。
            final sa = cums[i][ai] +
                _signedT(a[ai], a[ai + 1], p) *
                    (cums[i][ai + 1] - cums[i][ai]);
            final sb = cums[j][bi] +
                _signedT(b[bi], b[bi + 1], p) *
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

      // 交点按弧长排序、去重：同一路口被多条路/相邻两段各检出一次时，
      // 弧长差 < 3m 即视为同一路口，合并为一个 hit，避免重复开口/倒角。
      final hs = hits[i].toList()..sort((x, y) => x.s.compareTo(y.s));
      final uniq = <_Hit>[];
      for (final h in hs) {
        if (uniq.isEmpty || (h.s - uniq.last.s).abs() > 3.0) uniq.add(h);
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
    // ---- 4. 倒角去重：同一路口多条路交点差 1–3m 时，同一逻辑倒角
    // 会被重复生成多次（中点相近、方向相近）。按两端点均相近判重，
    // 保留第一条，避免路口出现重叠的杂乱倒角。----
    return JunctionResult(result.pieces, _dedupChamfers(result.chamfers));
  }

  /// 倒角去重：两条倒角中点相距 < 2m、方向近似平行（|cos| > 0.86），
  /// 且中点偏移主要沿倒角方向（同线偏移，|dot| > 0.7）即判为同一倒角。
  /// T 型口左右一对倒角的中点偏移垂直于倒角方向（并排），不会误杀；
  /// 同一逻辑倒角重复生成时是同线偏移。
  static List<List<List<double>>> _dedupChamfers(
      List<List<List<double>>> chamfers) {
    final out = <List<List<double>>>[];
    for (final c in chamfers) {
      final cmx = (c[0][0] + c[1][0]) / 2, cmy = (c[0][1] + c[1][1]) / 2;
      final cdx = c[1][0] - c[0][0], cdy = c[1][1] - c[0][1];
      final clen = math.sqrt(cdx * cdx + cdy * cdy);
      var dup = false;
      for (final o in out) {
        final omx = (o[0][0] + o[1][0]) / 2, omy = (o[0][1] + o[1][1]) / 2;
        final offx = cmx - omx, offy = cmy - omy;
        final offLen = math.sqrt(offx * offx + offy * offy);
        if (offLen > 2.0) continue;
        final odx = o[1][0] - o[0][0], ody = o[1][1] - o[0][1];
        final olen = math.sqrt(odx * odx + ody * ody);
        if (clen < 1e-9 || olen < 1e-9 || offLen < 1e-9) continue;
        // 方向平行？
        final cosA = (cdx * odx + cdy * ody) / (clen * olen);
        if (cosA.abs() <= 0.86) continue;
        // 中点偏移是否主要沿倒角方向（同线偏移）？
        final alongRatio = (offx * cdx + offy * cdy).abs() / (offLen * clen);
        if (alongRatio > 0.7) {
          dup = true;
          break;
        }
      }
      if (!dup) out.add(c);
    }
    return out;
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

  /// 近miss检测：精确不交时，端点到对方线段距离 <= tol 视为相交。
  ///
  /// 返回交点（端点在对方线段上的投影）。近似平行（夹角 < ~14°）
  /// 时返回 null，避免把双向车道、平行辅路误判为交叉口。
  static List<double>? _segNearMiss(
      List<double> a1, List<double> a2,
      List<double> b1, List<double> b2, double tol) {
    if (tol <= 0) return null;
    // 平行判定：方向余弦 |cos| 接近 1 = 平行，不视为交叉
    final rX = a2[0] - a1[0], rY = a2[1] - a1[1];
    final sX = b2[0] - b1[0], sY = b2[1] - b1[1];
    final rLen = math.sqrt(rX * rX + rY * rY);
    final sLen = math.sqrt(sX * sX + sY * sY);
    if (rLen < 1e-9 || sLen < 1e-9) return null;
    final cosA = (rX * sX + rY * sY) / (rLen * sLen);
    if (cosA.abs() > 0.97) return null;

    // 端点到对方线段的最近距离
    var best = double.infinity;
    List<double>? bestP;
    for (final ap in [a1, a2]) {
      final proj = _nearestOnSeg(ap, b1, b2);
      final d = _dist(ap, proj);
      if (d < best) {
        best = d;
        bestP = proj;
      }
    }
    for (final bp in [b1, b2]) {
      final proj = _nearestOnSeg(bp, a1, a2);
      final d = _dist(bp, proj);
      if (d < best) {
        best = d;
        bestP = proj;
      }
    }
    if (best <= tol) return bestP;
    return null;
  }

  /// 有符号投影参数：点 p 在线段 a→b 方向上的参数。
  /// 0 = a，1 = b；<0 表示在 a 之前，>1 表示在 b 之后。
  static double _signedT(List<double> a, List<double> b, List<double> p) {
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-18) return 0.0;
    return ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2;
  }

  /// 点到线段的最近点。
  static List<double> _nearestOnSeg(
      List<double> p, List<double> a, List<double> b) {
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-18) return a;
    var t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    return [a[0] + dx * t, a[1] + dy * t];
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
