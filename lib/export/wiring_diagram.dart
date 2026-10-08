import 'dart:math' as math;

import '../models/fiber_link.dart';
import '../models/map_label.dart';

/// 配线图节点：设备在配线图中的排布位置（图纸坐标系，单位米）。
class WiringNode {
  final MapLabel device;
  final double x;
  final double y;
  final String label;

  /// 在路由链中的顺序（seq）。
  final int routeIndex;

  WiringNode(this.device, this.x, this.y, this.label, {this.routeIndex = -1});
}

/// 配线图连线：两节点之间的光缆。
class WiringEdge {
  final WiringNode from;
  final WiringNode to;
  final FiberLink link;

  WiringEdge(this.from, this.to, this.link);
}

/// 配线图排布结果。
class WiringLayout {
  final List<WiringNode> nodes;
  final List<WiringEdge> edges;

  /// 折线路径点（直角简化后的配线图走向），按顺序。
  final List<math.Point<double>> path;

  final double width;
  final double height;

  WiringLayout(this.nodes, this.edges, this.path, this.width, this.height);
}

/// 配线图自动排布：**直角简化式**，跟路由走向。
///
/// 2026-10-08 用户纠正（看参考 DXF 截图后）：
/// - 配线图不是直线总线，而是路由走向的直角简化版
/// - 参考：上半电缆先右后下，下半配线图也先右后下，只是压成直角、缩短距离
/// - 像地铁图：保留拓扑和大致走向，几何简化为直角，距离压缩
///
/// [routeLabels] 为路由链（有序，含 seq），用于确定走向。
/// 返回的坐标系原点在左下角，调用方负责平移到 DXF 位置。
WiringLayout layoutWiringDiagram(
  List<MapLabel> devices,
  List<FiberLink> links,
  List<MapLabel> routeLabels, {
  double segLen = 40,
}) {
  if (devices.isEmpty) return WiringLayout([], [], [], 0, 0);

  final byId = {for (final d in devices) d.id: d};

  // 只保留两端都存在的连线
  final validLinks = [
    for (final l in links)
      if (byId.containsKey(l.fromDeviceId) && byId.containsKey(l.toDeviceId)) l
  ];

  // 路由顺序：用 seq 字段（路由链的真实顺序）
  final routeSeqOf = <String, int>{};
  for (final l in routeLabels) {
    final s = l.seq;
    if (!routeSeqOf.containsKey(l.id) || s < routeSeqOf[l.id]!) {
      routeSeqOf[l.id] = s;
    }
  }

  // 按路由顺序排序
  final sorted = devices.toList()
    ..sort((a, b) {
      final ia = routeSeqOf[a.id] ?? 999999;
      final ib = routeSeqOf[b.id] ?? 999999;
      if (ia != ib) return ia.compareTo(ib);
      return a.name.compareTo(b.name);
    });

  // 取各设备的经纬度（用于判断走向）
  // 直角简化：相邻两点的向量，按主导轴量化为上下左右
  final path = <math.Point<double>>[];
  final nodeMap = <String, WiringNode>{};

  double x = 0, y = 0;
  path.add(math.Point(x, y));

  for (var i = 0; i < sorted.length; i++) {
    final d = sorted[i];
    if (i > 0) {
      final prev = sorted[i - 1];
      // 地理向量
      final dLon = d.lon - prev.lon;
      final dLat = d.lat - prev.lat;
      // 经纬度转米（等距近似）
      final avgLat = (d.lat + prev.lat) / 2;
      final cosLat = math.cos(avgLat * math.pi / 180);
      final dxM = dLon * 111000.0 * cosLat;
      final dyM = dLat * 111000.0;
      // 按主导轴量化为直角方向
      String dir;
      if (dxM.abs() >= dyM.abs()) {
        dir = dxM >= 0 ? 'R' : 'L'; // 右 / 左
      } else {
        dir = dyM >= 0 ? 'U' : 'D'; // 上 / 下
      }
      // 走直角段（压缩为固定长度，保持方向）
      switch (dir) {
        case 'R':
          x += segLen;
        case 'L':
          x -= segLen;
        case 'U':
          y += segLen;
        case 'D':
          y -= segLen;
      }
      path.add(math.Point(x, y));
    }
    final label = d.name.isNotEmpty ? d.name : d.id.substring(0, 8);
    final node = WiringNode(d, x, y, label,
        routeIndex: routeSeqOf[d.id] ?? -1);
    nodeMap[d.id] = node;
  }

  final nodes = sorted.map((d) => nodeMap[d.id]!).toList();
  final edges = [
    for (final l in validLinks)
      if (nodeMap.containsKey(l.fromDeviceId) &&
          nodeMap.containsKey(l.toDeviceId))
        WiringEdge(
            nodeMap[l.fromDeviceId]!, nodeMap[l.toDeviceId]!, l),
  ];

  double minX = 0, maxX = 0, minY = 0, maxY = 0;
  for (final p in path) {
    if (p.x < minX) minX = p.x;
    if (p.x > maxX) maxX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.y > maxY) maxY = p.y;
  }

  return WiringLayout(
      nodes, edges, path, maxX - minX + segLen, maxY - minY + segLen);
}
