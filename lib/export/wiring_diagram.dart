import 'dart:math' as math;

import '../models/fiber_link.dart';
import '../models/map_label.dart';

/// 配线图节点：设备在配线图中的排布位置（图纸坐标系，单位米）。
class WiringNode {
  final MapLabel device;
  final double x;
  final double y;
  final String label;

  WiringNode(this.device, this.x, this.y, this.label);
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
  final double width;
  final double height;

  WiringLayout(this.nodes, this.edges, this.width, this.height);
}

/// 配线图自动排布：根据设备真实经纬度生成**与路由图同向**的压缩示意。
///
/// 2026-10-08 用户纠正：配线图走向必须跟路由图一致，只是缩短距离；
/// 此前 BFS 分层左右排布是抽象示意，不符合联通竣工图规范，已废弃。
///
/// 布局规则：
/// - 节点按真实经纬度定位，经等距投影换算为米后**统一压缩**到目标尺寸
/// - 保持方向与相对位置不变（与路由图同向），距离按比例缩短
/// - 相邻节点最小间距 20m，防重叠
///
/// 返回的坐标系原点在左下角，调用方负责平移到 DXF 右侧位置。
WiringLayout layoutWiringDiagram(
  List<MapLabel> devices,
  List<FiberLink> links, {
  double maxWidth = 400,
  double maxHeight = 300,
  double minGap = 20,
}) {
  if (devices.isEmpty) return WiringLayout([], [], 0, 0);

  final byId = {for (final d in devices) d.id: d};

  // 只保留两端都存在的连线
  final validLinks = [
    for (final l in links)
      if (byId.containsKey(l.fromDeviceId) && byId.containsKey(l.toDeviceId)) l
  ];

  // 地理范围（度）
  var minLat = double.infinity, maxLat = -double.infinity;
  var minLon = double.infinity, maxLon = -double.infinity;
  for (final d in devices) {
    if (d.lat < minLat) minLat = d.lat;
    if (d.lat > maxLat) maxLat = d.lat;
    if (d.lon < minLon) minLon = d.lon;
    if (d.lon > maxLon) maxLon = d.lon;
  }
  final avgLat = (minLat + maxLat) / 2;
  final cosLat = math.cos(avgLat * math.pi / 180);

  // 经纬度跨度换算为米（等距近似）
  double lonM(double lon) => (lon - minLon) * 111000.0 * cosLat;
  double latM(double lat) => (lat - minLat) * 111000.0;
  final spanX = lonM(maxLon);
  final spanY = latM(maxLat);

  // 统一压缩比例：保持宽高比，方向与路由图一致
  final sx = spanX > 1 ? maxWidth / spanX : 1.0;
  final sy = spanY > 1 ? maxHeight / spanY : 1.0;
  final scale = math.min(sx, sy);

  // 初排
  final nodeMap = <String, WiringNode>{};
  for (final d in devices) {
    final x = lonM(d.lon) * scale;
    final y = latM(d.lat) * scale;
    final label = d.name.isNotEmpty ? d.name : d.id.substring(0, 8);
    nodeMap[d.id] = WiringNode(d, x, y, label);
  }

  // 防重叠：距离过近的节点沿连线方向推开（简单迭代）
  final nodes = nodeMap.values.toList();
  for (var iter = 0; iter < 10; iter++) {
    var moved = false;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final a = nodes[i], b = nodes[j];
        final dx = b.x - a.x, dy = b.y - a.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist < minGap && dist > 0.001) {
          final push = (minGap - dist) / 2;
          final ux = dx / dist, uy = dy / dist;
          final na = WiringNode(a.device, a.x - ux * push, a.y - uy * push, a.label);
          final nb = WiringNode(b.device, b.x + ux * push, b.y + uy * push, b.label);
          nodes[i] = na;
          nodes[j] = nb;
          nodeMap[a.device.id] = na;
          nodeMap[b.device.id] = nb;
          moved = true;
        }
      }
    }
    if (!moved) break;
  }

  final edges = [
    for (final l in validLinks)
      if (nodeMap.containsKey(l.fromDeviceId) &&
          nodeMap.containsKey(l.toDeviceId))
        WiringEdge(
            nodeMap[l.fromDeviceId]!, nodeMap[l.toDeviceId]!, l),
  ];

  double maxX = 0, maxY = 0;
  for (final n in nodes) {
    if (n.x > maxX) maxX = n.x;
    if (n.y > maxY) maxY = n.y;
  }

  return WiringLayout(nodes, edges, maxX + minGap, maxY + minGap);
}
