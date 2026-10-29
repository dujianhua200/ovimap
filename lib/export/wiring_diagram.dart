import 'dart:math' as math;

import '../models/fiber_link.dart';
import '../models/map_label.dart';

/// 配线图节点：设备在配线图中的排布位置（图纸坐标，单位米，原点 = 配线图左下角）。
class WiringNode {
  final MapLabel device;
  final double x;
  final double y;
  final String label;

  /// 是否落在路由链上（false = 旁挂设备，按最近路由点法向外偏摆放）。
  final bool onRoute;

  WiringNode(this.device, this.x, this.y, this.label, {this.onRoute = true});
}

/// 配线图连线：两节点之间的光缆。
class WiringEdge {
  final WiringNode from;
  final WiringNode to;
  final FiberLink link;

  /// 已压缩的折线（含首尾）。走向沿路由（含转弯），长度按统一比例缩短。
  final List<math.Point<double>> path;

  WiringEdge(this.from, this.to, this.link, this.path);
}

/// 配线图排布结果。
class WiringLayout {
  final List<WiringNode> nodes;
  final List<WiringEdge> edges;

  /// 整条路由压缩后的折线（仅供包围盒/调试参考，导出时不再逐段绘制）。
  final List<math.Point<double>> path;

  /// 配线图自身宽高（米），已包含四周 [padM] 留白。
  final double width;
  final double height;

  /// 压缩比例（配线图长度 ÷ 真实路由长度，< 1 表示缩短）。
  final double scale;

  WiringLayout(this.nodes, this.edges, this.path, this.width, this.height,
      this.scale);
}

/// 配线图自动排布：**纯拓扑结构**，只排设备与光缆，不复制整条杆路。
///
/// 2026-10-29 用户定版：
/// - 配线图 = 拓扑：只含连线两端的设备（光交/分纤箱/成端等），杆路不逐杆复制；
/// - 走向与路由一致：每条连线沿它在路由上经过的那段折线走（保留拐点），
///   再把整条路由**统一压缩**到目标跨度 [targetSpanM]，即「方向不变、线变短」；
/// - 不在路由链上的设备旁挂在最近路由点外侧；
/// - 导出端按 [width]/[height] 做落点避让，保证不压路由/底图。
///
/// [routeLabels]：完整路由链（有序，含 seq），只用于取走向；
/// [devices]：参与拓扑的设备（连线端点）；
/// [links]：光缆连线；
/// [targetSpanM]：配线图最长边目标尺寸（米），由导出端按纸面毫米换算；
/// [padM]：四周留白（米），用于容纳符号与文字。
WiringLayout layoutWiringDiagram(
  List<MapLabel> devices,
  List<FiberLink> links,
  List<MapLabel> routeLabels, {
  double targetSpanM = 200,
  double padM = 0,
}) {
  if (devices.isEmpty || routeLabels.isEmpty) {
    return WiringLayout(const [], const [], const [], 0, 0, 1);
  }

  final target = targetSpanM > 0 ? targetSpanM : 200.0;

  // 1) 路由投影到米（统一基准纬度），并累计弧长。
  final sortedRoute = routeLabels.toList()
    ..sort((a, b) => a.seq.compareTo(b.seq));
  final baseLon = sortedRoute.first.lon;
  final baseLat = sortedRoute.first.lat;
  final sx = 111320.0 * math.cos(baseLat * math.pi / 180);
  const sy = 110540.0;

  final pts = <math.Point<double>>[];
  final cum = <double>[];
  for (var i = 0; i < sortedRoute.length; i++) {
    final p = math.Point<double>(
      (sortedRoute[i].lon - baseLon) * sx,
      (sortedRoute[i].lat - baseLat) * sy,
    );
    if (pts.isEmpty) {
      pts.add(p);
      cum.add(0);
    } else {
      pts.add(p);
      cum.add(cum.last + _pdist(pts[pts.length - 2], p));
    }
  }

  // 2) 统一压缩系数：整条路由最长边压到 target 米。
  var rMinX = double.infinity, rMinY = double.infinity;
  var rMaxX = -double.infinity, rMaxY = -double.infinity;
  for (final p in pts) {
    rMinX = math.min(rMinX, p.x);
    rMinY = math.min(rMinY, p.y);
    rMaxX = math.max(rMaxX, p.x);
    rMaxY = math.max(rMaxY, p.y);
  }
  final span = math.max(rMaxX - rMinX, rMaxY - rMinY);
  final scale = span > 1e-6 ? target / span : 1.0;

  // seq -> 路由点下标（重复 seq 取第一个）
  final seqToIdx = <int, int>{};
  for (var i = 0; i < sortedRoute.length; i++) {
    seqToIdx.putIfAbsent(sortedRoute[i].seq, () => i);
  }

  // 3) 设备落点：在路由链上的按 seq 定位，其余旁挂。
  final pos = <String, math.Point<double>>{};
  final anchorIdx = <String, int>{};
  final onRoute = <String, bool>{};
  final occupied = <math.Point<double>>[];

  for (final d in devices) {
    final idx = seqToIdx[d.seq];
    if (idx == null) continue;
    final p = math.Point<double>(pts[idx].x * scale, pts[idx].y * scale);
    pos[d.id] = p;
    anchorIdx[d.id] = idx;
    onRoute[d.id] = true;
    occupied.add(p);
  }

  final offDevices = [
    for (final d in devices)
      if (!pos.containsKey(d.id)) d
  ];
  if (offDevices.isNotEmpty) {
    final off = math.max(target * 0.07, 4.0);
    for (final d in offDevices) {
      final raw = math.Point<double>(
        (d.lon - baseLon) * sx,
        (d.lat - baseLat) * sy,
      );
      var bi = 0;
      var bd = double.infinity;
      for (var i = 0; i < pts.length; i++) {
        final dx = pts[i].x - raw.x, dy = pts[i].y - raw.y;
        final dd = dx * dx + dy * dy;
        if (dd < bd) {
          bd = dd;
          bi = i;
        }
      }
      final t = _tangentAt(pts, bi);
      // 沿路由法向逐级外推，避开已占用位置
      var k = 1.0;
      math.Point<double> p;
      do {
        p = math.Point<double>(
          pts[bi].x * scale - t.y * off * k,
          pts[bi].y * scale + t.x * off * k,
        );
        k += 1;
      } while (occupied.any((q) => _pdist(q, p) < off * 0.9) && k < 8);
      pos[d.id] = p;
      anchorIdx[d.id] = bi;
      onRoute[d.id] = false;
      occupied.add(p);
    }
  }

  // 4) 节点 + 连线（连线沿路由剪取，保留拐点）。
  final nodes = <WiringNode>[];
  for (final d in devices) {
    final p = pos[d.id];
    if (p == null) continue;
    nodes.add(WiringNode(d, p.x, p.y, _labelOf(d), onRoute: onRoute[d.id]!));
  }
  if (nodes.isEmpty) {
    return WiringLayout(const [], const [], const [], 0, 0, scale);
  }
  final nodeById = {for (final n in nodes) n.device.id: n};

  List<math.Point<double>> edgePath(MapLabel a, MapLabel b) {
    final pa = pos[a.id]!, pb = pos[b.id]!;
    final ia = anchorIdx[a.id], ib = anchorIdx[b.id];
    final bothOnRoute = onRoute[a.id]! && onRoute[b.id]!;
    if (bothOnRoute && ia != null && ib != null && ia != ib) {
      final lo = math.min(ia, ib), hi = math.max(ia, ib);
      final line = [
        for (var i = lo; i <= hi; i++)
          math.Point<double>(pts[i].x * scale, pts[i].y * scale)
      ];
      return ia <= ib ? line : line.reversed.toList();
    }
    // 同一路由点或旁挂设备：直接连两点
    return [pa, pb];
  }

  final edges = <WiringEdge>[];
  for (final l in links) {
    final a = nodeById[l.fromDeviceId], b = nodeById[l.toDeviceId];
    if (a == null || b == null) continue;
    edges.add(WiringEdge(a, b, l, edgePath(a.device, b.device)));
  }

  // 5) 包围盒 + 统一平移到留白内。
  var bx0 = double.infinity, by0 = double.infinity;
  var bx1 = -double.infinity, by1 = -double.infinity;
  void mark(double x, double y) {
    bx0 = math.min(bx0, x);
    by0 = math.min(by0, y);
    bx1 = math.max(bx1, x);
    by1 = math.max(by1, y);
  }

  for (final n in nodes) {
    mark(n.x, n.y);
  }
  for (final e in edges) {
    for (final p in e.path) {
      mark(p.x, p.y);
    }
  }
  final w = bx1 - bx0, h = by1 - by0;
  final shX = padM - bx0, shY = padM - by0;

  final shifted = <String, WiringNode>{};
  for (final n in nodes) {
    shifted[n.device.id] = WiringNode(
        n.device, n.x + shX, n.y + shY, n.label,
        onRoute: n.onRoute);
  }

  return WiringLayout(
    [for (final d in devices) if (shifted[d.id] != null) shifted[d.id]!],
    [
      for (final e in edges)
        WiringEdge(
          shifted[e.from.device.id]!,
          shifted[e.to.device.id]!,
          e.link,
          [
            for (final p in e.path)
              math.Point<double>(p.x + shX, p.y + shY)
          ],
        )
    ],
    [
      for (final p in pts)
        math.Point<double>(p.x * scale + shX, p.y * scale + shY)
    ],
    w + 2 * padM,
    h + 2 * padM,
    scale,
  );
}

double _pdist(math.Point<double> a, math.Point<double> b) {
  final dx = a.x - b.x, dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}

math.Point<double> _norm(math.Point<double> v) {
  final len = math.sqrt(v.x * v.x + v.y * v.y);
  if (len < 1e-9) return const math.Point<double>(0, 0);
  return math.Point<double>(v.x / len, v.y / len);
}

/// 路由点处的单位切线方向（转弯点取前后两段归一化均值）。
math.Point<double> _tangentAt(List<math.Point<double>> pts, int i) {
  if (pts.length < 2) return const math.Point<double>(1, 0);
  math.Point<double> d;
  if (i <= 0) {
    d = math.Point<double>(pts[1].x - pts[0].x, pts[1].y - pts[0].y);
  } else if (i >= pts.length - 1) {
    d = math.Point<double>(
        pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
  } else {
    final a = _norm(math.Point<double>(
        pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
    final b = _norm(math.Point<double>(
        pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y));
    d = math.Point<double>(a.x + b.x, a.y + b.y);
  }
  final n = _norm(d);
  return (n.x == 0 && n.y == 0) ? const math.Point<double>(1, 0) : n;
}

String _labelOf(MapLabel d) {
  if (d.name.isNotEmpty) return d.name;
  return d.id.length > 8 ? d.id.substring(0, 8) : d.id;
}
