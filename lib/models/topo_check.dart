import 'fiber_link.dart';
import 'map_label.dart';

/// 拓扑校验问题。
class TopoIssue {
  final String kind;
  final String message;
  final String? deviceId;

  const TopoIssue(this.kind, this.message, [this.deviceId]);

  @override
  String toString() => '[$kind] $message';
}

/// ID 显示短名（避免 substring 越界）。
String _shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// 拓扑一键校验：检测孤立节点、重复连线、芯数冲突、未命名点位。
///
/// 输入：设备列表（MapLabel，独立节点）+ 人工拓扑连线（FiberLink）。
/// 输出：问题列表，空表示通过。
List<TopoIssue> validateTopology(
    List<MapLabel> devices, List<FiberLink> links) {
  final issues = <TopoIssue>[];
  final deviceIds = {for (final d in devices) d.id};

  // 1. 未命名点位
  for (final d in devices) {
    if (d.name.trim().isEmpty && d.note.trim().isEmpty) {
      issues.add(TopoIssue('未命名', '设备 ${_shortId(d.id)} 未填写名称', d.id));
    }
  }

  // 2. 连线端点有效性 + 重复连线
  final seenPairs = <String>{};
  for (final l in links) {
    if (!deviceIds.contains(l.fromDeviceId)) {
      issues.add(TopoIssue('无效端点', '连线起点设备不存在: ${_shortId(l.fromDeviceId)}'));
    }
    if (!deviceIds.contains(l.toDeviceId)) {
      issues.add(TopoIssue('无效端点', '连线终点设备不存在: ${_shortId(l.toDeviceId)}'));
    }
    if (l.fromDeviceId == l.toDeviceId && l.fromDeviceId.isNotEmpty) {
      issues.add(TopoIssue('自环', '设备连向自身'));
    }
    final a = l.fromDeviceId, b = l.toDeviceId;
    if (a.isNotEmpty && b.isNotEmpty) {
      final key = a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';
      if (seenPairs.contains(key)) {
        issues.add(TopoIssue('重复连线', '两设备之间存在多条连线'));
      } else {
        seenPairs.add(key);
      }
    }
  }

  // 3. 孤立节点（没有任何连线的设备）
  final linked = <String>{};
  for (final l in links) {
    linked.add(l.fromDeviceId);
    linked.add(l.toDeviceId);
  }
  for (final d in devices) {
    if (!linked.contains(d.id)) {
      final label = d.name.isNotEmpty ? d.name : _shortId(d.id);
      issues.add(TopoIssue('孤立节点', '设备 $label 没有任何拓扑连线', d.id));
    }
  }

  // 4. 芯数冲突：同一设备引出的多条连线芯数不一致时提示
  final coresByDevice = <String, Set<int>>{};
  for (final l in links) {
    if (l.cores <= 0) continue;
    coresByDevice.putIfAbsent(l.fromDeviceId, () => {}).add(l.cores);
    coresByDevice.putIfAbsent(l.toDeviceId, () => {}).add(l.cores);
  }
  for (final e in coresByDevice.entries) {
    if (e.value.length > 1) {
      issues.add(TopoIssue('芯数不一致',
          '设备 ${_shortId(e.key)} 连接的光缆芯数有多种: ${e.value.join('/')}',
          e.key));
    }
  }

  return issues;
}
