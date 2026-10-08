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

  /// 折线路径点（整条路由的直角简化），按顺序。
  final List<math.Point<double>> path;

  final double width;
  final double height;

  WiringLayout(this.nodes, this.edges, this.path, this.width, this.height);
}

/// 配线图自动排布：**整条路由的直角简化**，跟路由走向。
///
/// 2026-10-08 用户纠正（看导出 DXF 截图后）：
/// - 配线图必须跟整条路由走，不能只连纤设备的两点一线
/// - 中间杆路的转弯也要保留（简化成直角），否则方向不对
/// - 像地铁图：整条线路简化为直角折线，纤设备标在对应位置
///
/// [routeLabels] 为完整路由链（有序，含 seq），用于生成路径走向。
/// [devices] 为纤设备，按 seq 定位到路径上。
WiringLayout layoutWiringDiagram(
  List<MapLabel> devices,
  List<FiberLink> links,
  List<MapLabel> routeLabels, {
  double segLen = 40,
}) {
  if (routeLabels.isEmpty) return WiringLayout([], [], [], 0, 0);

  final byId = {for (final d in devices) d.id: d};

  // 只保留两端都存在的连线
  final validLinks = [
    for (final l in links)
      if (byId.containsKey(l.fromDeviceId) && byId.containsKey(l.toDeviceId)) l
  ];

  // 按 seq 排序完整路由链
  final sortedRoute = routeLabels.toList()..sort((a, b) => a.seq.compareTo(b.seq));

  // 生成直角简化路径：整条路由，每个转弯保留
  final path = <math.Point<double>>[];
  // seq -> 路径点索引
  final seqToPathIdx = <int, int>{};

  double x = 0, y = 0;
  path.add(math.Point(x, y));
  if (sortedRoute.isNotEmpty) {
    seqToPathIdx[sortedRoute[0].seq] = 0;
  }

  for (var i = 1; i < sortedRoute.length; i++) {
    final prev = sortedRoute[i - 1];
    final curr = sortedRoute[i];
    // 地理向量
    final dLon = curr.lon - prev.lon;
    final dLat = curr.lat - prev.lat;
    final avgLat = (curr.lat + prev.lat) / 2;
    final cosLat = math.cos(avgLat * math.pi / 180);
    final dxM = dLon * 111000.0 * cosLat;
    final dyM = dLat * 111000.0;
    // 按主导轴量化为直角方向
    if (dxM.abs() >= dyM.abs()) {
      x += dxM >= 0 ? segLen : -segLen; // 右 / 左
    } else {
      y += dyM >= 0 ? segLen : -segLen; // 上 / 下
    }
    path.add(math.Point(x, y));
    seqToPathIdx[curr.seq] = path.length - 1;
  }

  // 纤设备按 seq 定位到路径上
  final nodeMap = <String, WiringNode>{};
  final nodes = <WiringNode>[];
  final sortedDevices = devices.toList()
    ..sort((a, b) => a.seq.compareTo(b.seq));
  for (final d in sortedDevices) {
    final pathIdx = seqToPathIdx[d.seq];
    double nx, ny;
    if (pathIdx != null && pathIdx < path.length) {
      nx = path[pathIdx].x;
      ny = path[pathIdx].y;
    } else {
      // 不在路由链上：放末尾
      nx = x + segLen;
      ny = y;
    }
    final label = d.name.isNotEmpty ? d.name : d.id.substring(0, 8);
    final node = WiringNode(d, nx, ny, label, routeIndex: d.seq);
    nodeMap[d.id] = node;
    nodes.add(node);
  }

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
