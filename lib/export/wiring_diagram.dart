import '../models/fiber_link.dart';
import '../models/map_label.dart';

/// 配线图节点：设备在配线图中的排布位置（图纸坐标系，单位米）。
class WiringNode {
  final MapLabel device;
  final double x;
  final double y;
  final String label;
  /// 在路由链中的顺序索引（用于按路由方向排序）。
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
  final double width;
  final double height;

  WiringLayout(this.nodes, this.edges, this.width, this.height);
}

/// 配线图自动排布：**水平总线式**，按路由方向排序。
///
/// 2026-10-08 用户纠正：
/// - 配线图不是地理 2D 排布，而是按**路由顺序**左右排列的总线图
/// - 参考联通竣工图：水平主干 + 垂直引下到各箱体
/// - 设备顺序 = 在路由链中的先后顺序，不是连线创建顺序
///
/// [routeLabels] 为路由链（有序），用于确定设备先后顺序。
/// 返回的坐标系原点在左下角，调用方负责平移到 DXF 位置。
WiringLayout layoutWiringDiagram(
  List<MapLabel> devices,
  List<FiberLink> links,
  List<MapLabel> routeLabels, {
  double nodeGap = 50,
  double busY = 0,
  double dropLen = 30,
}) {
  if (devices.isEmpty) return WiringLayout([], [], 0, 0);

  final byId = {for (final d in devices) d.id: d};

  // 只保留两端都存在的连线
  final validLinks = [
    for (final l in links)
      if (byId.containsKey(l.fromDeviceId) && byId.containsKey(l.toDeviceId)) l
  ];

  // 路由顺序索引：label 在路由链中的位置
  final routeIndexOf = <String, int>{};
  for (var i = 0; i < routeLabels.length; i++) {
    routeIndexOf.putIfAbsent(routeLabels[i].id, () => i);
  }

  // 按路由顺序排序；不在路由链中的按原顺序放末尾
  final sorted = devices.toList()
    ..sort((a, b) {
      final ia = routeIndexOf[a.id] ?? 999999;
      final ib = routeIndexOf[b.id] ?? 999999;
      if (ia != ib) return ia.compareTo(ib);
      return a.name.compareTo(b.name);
    });

  // 水平排布：等距，总线在 y=busY，设备在总线下方 dropLen 处
  final nodeMap = <String, WiringNode>{};
  for (var i = 0; i < sorted.length; i++) {
    final d = sorted[i];
    final x = i * nodeGap;
    final y = busY - dropLen;
    final label = d.name.isNotEmpty ? d.name : d.id.substring(0, 8);
    final node = WiringNode(d, x, y, label,
        routeIndex: routeIndexOf[d.id] ?? -1);
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

  final width = sorted.isEmpty ? 0.0 : (sorted.length - 1) * nodeGap;
  return WiringLayout(nodes, edges, width, dropLen + 20);
}
