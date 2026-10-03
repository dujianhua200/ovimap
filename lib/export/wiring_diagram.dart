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

/// 配线图自动排布：根据人工拓扑连线生成。
///
/// 布局规则：
/// - 按连接关系分层：无入边的为第0层，BFS 向外展开
/// - 同层节点垂直排列，层间水平排列（从左到右）
/// - 孤立节点单独一列在最右侧
/// - 节点间距：水平 60m，垂直 30m（图纸米，可按比例缩放）
///
/// 返回的坐标系原点在左下角，调用方负责平移到 DXF 右侧位置。
WiringLayout layoutWiringDiagram(
  List<MapLabel> devices,
  List<FiberLink> links, {
  double colGap = 60,
  double rowGap = 30,
}) {
  if (devices.isEmpty) return WiringLayout([], [], 0, 0);

  final byId = {for (final d in devices) d.id: d};

  // 建邻接表（只保留两端都存在的连线）
  final validLinks = [
    for (final l in links)
      if (byId.containsKey(l.fromDeviceId) && byId.containsKey(l.toDeviceId)) l
  ];
  final outgoing = <String, List<String>>{};
  final incoming = <String, List<String>>{};
  for (final l in validLinks) {
    outgoing.putIfAbsent(l.fromDeviceId, () => []).add(l.toDeviceId);
    incoming.putIfAbsent(l.toDeviceId, () => []).add(l.fromDeviceId);
  }

  // 分层：BFS 从无入边节点开始
  final layerOf = <String, int>{};
  final queue = <String>[];
  for (final d in devices) {
    if (!(incoming[d.id]?.isNotEmpty ?? false)) {
      layerOf[d.id] = 0;
      queue.add(d.id);
    }
  }
  // 有环或全连通时，剩余节点按1层处理
  var qi = 0;
  while (qi < queue.length) {
    final id = queue[qi++];
    final layer = layerOf[id]!;
    for (final next in outgoing[id] ?? []) {
      if (!layerOf.containsKey(next)) {
        layerOf[next] = layer + 1;
        queue.add(next);
      }
    }
  }
  var maxLayer = 0;
  for (final d in devices) {
    layerOf.putIfAbsent(d.id, () {
      maxLayer++;
      return maxLayer;
    });
  }
  maxLayer = layerOf.values.fold(0, (a, b) => a > b ? a : b);

  // 同层内按名称排序，分配行号
  final byLayer = <int, List<MapLabel>>{};
  for (final d in devices) {
    byLayer.putIfAbsent(layerOf[d.id]!, () => []).add(d);
  }
  for (final list in byLayer.values) {
    list.sort((a, b) => a.name.compareTo(b.name));
  }

  // 排布坐标
  final nodeMap = <String, WiringNode>{};
  double maxX = 0, maxY = 0;
  for (var layer = 0; layer <= maxLayer; layer++) {
    final list = byLayer[layer] ?? [];
    for (var i = 0; i < list.length; i++) {
      final d = list[i];
      final x = layer * colGap;
      final y = i * rowGap;
      final label = d.name.isNotEmpty ? d.name : d.id.substring(0, 8);
      nodeMap[d.id] = WiringNode(d, x, y, label);
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }

  final edges = [
    for (final l in validLinks)
      if (nodeMap.containsKey(l.fromDeviceId) &&
          nodeMap.containsKey(l.toDeviceId))
        WiringEdge(
            nodeMap[l.fromDeviceId]!, nodeMap[l.toDeviceId]!, l),
  ];

  return WiringLayout(
    nodeMap.values.toList(),
    edges,
    maxX + colGap,
    maxY + rowGap,
  );
}
