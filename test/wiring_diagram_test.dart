import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/wiring_diagram.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  MapLabel dev(String id, String name, int seq, double lat, double lon) =>
      MapLabel(id: id, name: name, seq: seq, lat: lat, lon: lon);

  // 完整路由链：a(杆) -> b(纤) -> c(杆) -> d(纤) -> e(杆)
  // 地理：a(114.0,32.0) b(114.001,32.0) c(114.002,32.0) d(114.002,31.999) e(114.003,31.999)
  // 走向：东、东、南、东
  List<MapLabel> fullRoute() => [
        dev('a', '杆1', 1, 32.0, 114.0),
        dev('b', '纤1', 2, 32.0, 114.001),
        dev('c', '杆2', 3, 32.0, 114.002),
        dev('d', '纤2', 4, 31.999, 114.002),
        dev('e', '杆3', 5, 31.999, 114.003),
      ];

  double pathLen(List<math.Point<double>> ps) {
    var sum = 0.0;
    for (var i = 1; i < ps.length; i++) {
      final dx = ps[i].x - ps[i - 1].x;
      final dy = ps[i].y - ps[i - 1].y;
      sum += math.sqrt(dx * dx + dy * dy);
    }
    return sum;
  }

  double geoLen(double lon1, double lat1, double lon2, double lat2) {
    final avgLat = (lat1 + lat2) / 2;
    final cosLat = math.cos(avgLat * math.pi / 180);
    final dxM = (lon2 - lon1) * 111320.0 * cosLat;
    final dyM = (lat2 - lat1) * 110540.0;
    return math.sqrt(dxM * dxM + dyM * dyM);
  }

  group('layoutWiringDiagram（纯拓扑 + 统一压缩，2026-10-29）', () {
    test('空输入', () {
      final l = layoutWiringDiagram([], [], []);
      expect(l.nodes, isEmpty);
      expect(l.edges, isEmpty);
      expect(l.path, isEmpty);
      expect(l.width, 0);
    });

    test('只排设备与光缆，不复制整条杆路', () {
      final route = fullRoute();
      final ds = [
        dev('a', '杆1', 1, 32.0, 114.0),
        dev('e', '杆3', 5, 31.999, 114.003),
      ];
      final ls = [FiberLink(fromDeviceId: 'a', toDeviceId: 'e')];
      final l = layoutWiringDiagram(ds, ls, route, targetSpanM: 100, padM: 0);
      // 节点只有连线两端的设备（中间杆 c 不出现）
      expect(l.nodes.length, 2);
      expect(l.nodes.map((n) => n.device.id).toSet(), {'a', 'e'});
      // 连线沿路由剪取，保留 5 个折点（代表转弯走向）
      expect(l.edges.single.path.length, 5);
    });

    test('连线走向与路由一致（东、东、南、东）', () {
      final route = fullRoute();
      final ds = [
        dev('a', '杆1', 1, 32.0, 114.0),
        dev('e', '杆3', 5, 31.999, 114.003),
      ];
      final l = layoutWiringDiagram(ds,
          [FiberLink(fromDeviceId: 'a', toDeviceId: 'e')], route,
          targetSpanM: 100, padM: 0);
      final p = l.edges.single.path;
      expect(p[1].x, greaterThan(p[0].x)); // 东
      expect((p[1].y - p[0].y).abs(), lessThan(1e-6));
      expect(p[2].x, greaterThan(p[1].x)); // 东
      expect(p[3].y, lessThan(p[2].y)); // 南
      expect(p[4].x, greaterThan(p[3].x)); // 东
    });

    test('统一压缩：最长边等于目标跨度，线长明显缩短', () {
      final route = fullRoute();
      final ds = [
        dev('a', '杆1', 1, 32.0, 114.0),
        dev('e', '杆3', 5, 31.999, 114.003),
      ];
      final l = layoutWiringDiagram(ds,
          [FiberLink(fromDeviceId: 'a', toDeviceId: 'e')], route,
          targetSpanM: 100, padM: 0);
      expect(math.max(l.width, l.height), closeTo(100, 1e-6));
      expect(l.scale, lessThan(1));
      // 压缩后的折线长度 = 真实路由长度 × 统一比例
      final real = geoLen(114.0, 32.0, 114.001, 32.0) +
          geoLen(114.001, 32.0, 114.002, 32.0) +
          geoLen(114.002, 32.0, 114.002, 31.999) +
          geoLen(114.002, 31.999, 114.003, 31.999);
      expect(pathLen(l.edges.single.path), closeTo(real * l.scale, real * 1e-6));
    });

    test('不在路由链上的设备旁挂，连线仍输出', () {
      final route = fullRoute();
      final ds = [
        dev('a', '杆1', 1, 32.0, 114.0),
        dev('x', '分纤箱X', 9, 31.9995, 114.0005),
      ];
      final l = layoutWiringDiagram(ds,
          [FiberLink(fromDeviceId: 'a', toDeviceId: 'x')], route,
          targetSpanM: 100, padM: 0);
      final nx = l.nodes.firstWhere((n) => n.device.id == 'x');
      final na = l.nodes.firstWhere((n) => n.device.id == 'a');
      expect(nx.onRoute, isFalse);
      expect(l.edges.length, 1);
      // 旁挂设备离锚点有距离，且整体仍落在配线图包围盒内
      expect((nx.x - na.x).abs() + (nx.y - na.y).abs(), greaterThan(0));
      expect(nx.x, inInclusiveRange(0, l.width));
      expect(nx.y, inInclusiveRange(0, l.height));
    });

    test('留白：几何整体从 padM 起', () {
      final route = fullRoute();
      final ds = [
        dev('a', '杆1', 1, 32.0, 114.0),
        dev('e', '杆3', 5, 31.999, 114.003),
      ];
      const pad = 5.0;
      final l = layoutWiringDiagram(ds,
          [FiberLink(fromDeviceId: 'a', toDeviceId: 'e')], route,
          targetSpanM: 100, padM: pad);
      var minX = double.infinity, minY = double.infinity;
      for (final p in l.edges.single.path) {
        minX = math.min(minX, p.x);
        minY = math.min(minY, p.y);
      }
      expect(minX, closeTo(pad, 1e-6));
      expect(minY, closeTo(pad, 1e-6));
      expect(l.width, closeTo(100 + 2 * pad, 1e-6));
    });
  });
}
